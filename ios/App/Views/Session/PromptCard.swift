import SwiftUI

/// Anything DeepSeek is waiting on, one native card for all of it: a tool permission, a plan to review,
/// or questions. An icon and title say what is asked, the detail follows, then the choices as a grouped
/// list. Several questions take a page each, with Back and Next; Next becomes Send on the last one. A lone
/// single choice answers in one tap.
struct PromptCard: View {
    @Environment(HostStore.self) private var store
    let pending: PendingQuestion
    /// The tallest the questions may be before they scroll inside the card.
    var bodyLimit: CGFloat = .infinity
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitting = false
    @State private var page = 0
    /// Which way the last page turn went, so the new page slides in from that side.
    @State private var forward = true

    /// The labels the plugin offers for a tool permission.
    static let allow = "Allow Once"
    static let deny = "Deny"

    private enum Kind { case approval, review, question }

    private var kind: Kind {
        switch pending.questions.first?.intent {
        case "approval": .approval
        case "plan-review": .review
        default: .question
        }
    }

    private var only: Question? { pending.questions.count == 1 ? pending.questions[0] : nil }
    private var current: Question? { pending.questions.indices.contains(page) ? pending.questions[page] : pending.questions.last }
    private var last: Bool { page >= pending.questions.count - 1 }

    /// One single-select question answers as soon as a choice is tapped, unless something was typed.
    private var instant: Bool {
        guard let only else { return false }
        return !only.multiSelect && !only.options.isEmpty && trimmed(only.id).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PromptHeader(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
            // Natural height while it fits; past the limit the questions scroll and the header and
            // buttons stay put.
            if let current {
                ViewThatFits(in: .vertical) {
                    section(current)
                    ScrollView { section(current) }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollEdgeEffectStyle(.soft, for: .vertical)
                        .scrollDismissesKeyboard(.interactively)
                }
                .frame(maxHeight: bodyLimit)
                .id(page)
                .transition(.push(from: forward ? .trailing : .leading))
            }
            footer
        }
        .padding(16)
        // Pages slide within the card, not over its edge.
        .clipShape(.rect(corners: .concentric(minimum: 24), isUniform: true))
        .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 24), isUniform: true))
        .frame(maxWidth: 780)
        .disabled(submitting)
        .animation(.snappy, value: page)
        .onAppear {
            Haptics.attention()
            // Put the keyboard away so the whole prompt and its choices are visible.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .approval ? "Permission request" : "Question from DeepSeek")
    }

    // MARK: Header

    private var symbol: String {
        switch kind {
        case .approval: "hand.raised.fill"
        case .review: "checklist"
        case .question: "questionmark"
        }
    }

    private var tint: Color {
        switch kind {
        case .approval: .orange
        case .review: .green
        case .question: .accentColor
        }
    }

    private var title: String {
        if kind == .approval { return "Allow \(only?.header ?? "this tool") to run?" }
        return current?.question ?? "DeepSeek has a question"
    }

    private var subtitle: String {
        if kind == .approval { return "DeepSeek needs your permission to continue." }
        let fallback = kind == .review ? "Review the plan before DeepSeek starts." : "DeepSeek needs your input."
        guard pending.questions.count > 1 else { return current?.header ?? fallback }
        let position = "\(page + 1) of \(pending.questions.count)"
        return current?.header.map { "\($0) · \(position)" } ?? position
    }

    // MARK: Body

    @ViewBuilder
    private func section(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detail = question.detail, !detail.isEmpty {
                PromptDetail(text: detail, markdown: kind != .approval)
            }
            if kind != .approval {
                if !question.options.isEmpty {
                    PromptChoices(options: question.options, multi: question.multiSelect,
                                  showsSelection: !instant,
                                  selected: selections[question.id, default: []]) { label in
                        Haptics.selection()
                        toggle(label, in: question)
                    }
                }
                PromptField(placeholder: question.options.isEmpty ? "Your answer" : "Something else…",
                            text: binding(question.id)) {
                    if last { submit() } else if answered(question) { turn(by: 1) }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if kind == .approval {
            HStack(spacing: 10) {
                Button(role: .cancel, action: { answerApproval(Self.deny) }) {
                    Text(Self.deny).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(action: { answerApproval(Self.allow) }) {
                    Text(Self.allow).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        } else if !instant {
            HStack(spacing: 10) {
                if page > 0 {
                    Button(action: { turn(by: -1) }) {
                        Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                Button(action: { last ? submit() : turn(by: 1) }) {
                    Text(last ? "Send" : "Next").frame(maxWidth: .infinity)
                        .contentTransition(.interpolate)
                }
                .buttonStyle(.glassProminent)
                .disabled(last ? !complete : !answered(current))
            }
            .controlSize(.large)
        }
    }

    private func turn(by step: Int) {
        Haptics.tap()
        forward = step > 0
        page = min(max(page + step, 0), pending.questions.count - 1)
    }

    // MARK: Answering

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 })
    }

    private func trimmed(_ id: String) -> String {
        (custom[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggle(_ label: String, in question: Question) {
        var set = selections[question.id, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.id] = set
        if instant {
            submit()
        } else if !question.multiSelect && !last {
            // A single choice settles its page: move on once the checkmark has shown.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if current?.id == question.id { turn(by: 1) }
            }
        }
    }

    private func answered(_ question: Question?) -> Bool {
        guard let question else { return false }
        return !(selections[question.id] ?? []).isEmpty || !trimmed(question.id).isEmpty
    }

    private var complete: Bool {
        pending.questions.allSatisfy(answered)
    }

    private func submit() {
        guard complete, !submitting else { return }
        let answers = pending.questions.map { question in
            let text = trimmed(question.id)
            // A single-select typed answer replaces the choice; a multi-select one adds to it.
            let selected = question.multiSelect || text.isEmpty ? Array(selections[question.id] ?? []) : []
            return QuestionAnswer(id: question.id, selected: selected, custom: text.isEmpty ? nil : text)
        }
        send(answers)
    }

    private func answerApproval(_ label: String) {
        guard let only else { return }
        label == Self.allow ? Haptics.success() : Haptics.press()
        send([QuestionAnswer(id: only.id, selected: [label])])
    }

    private func send(_ answers: [QuestionAnswer]) {
        guard !submitting else { return }
        submitting = true
        Task {
            if await !store.answer(pending, answers) { submitting = false }
        }
    }
}

// MARK: - Parts

/// A Settings-style icon tile beside a title and a line of context.
private struct PromptHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the choice is about: a reason, or a whole plan that scrolls once it is long.
private struct PromptDetail: View {
    let text: String
    let markdown: Bool

    var body: some View {
        ScrollView {
            Group {
                if markdown { MarkdownText(text) } else { Text(text).font(.callout).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: text.count < 300)
    }
}

/// Choices as a grouped list: a row per option, its description beneath, a checkmark when picked.
private struct PromptChoices: View {
    let options: [QuestionOption]
    let multi: Bool
    /// Rows that answer on tap show a chevron instead of a selection.
    let showsSelection: Bool
    let selected: Set<String>
    let choose: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.label) { index, option in
                if index > 0 { Divider().padding(.leading, 14) }
                let isSelected = selected.contains(option.label)
                Button(action: { choose(option.label) }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).foregroundStyle(.primary)
                            if let description = option.description {
                                Text(description).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        indicator(isSelected)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func indicator(_ isSelected: Bool) -> some View {
        if multi {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        } else if !showsSelection {
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        } else if isSelected {
            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
        }
    }
}

/// A list row's press highlight.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
    }
}

/// A typed answer, in a filled field like the system's search fields.
private struct PromptField: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...4)
            .submitLabel(.send)
            .onSubmit(submit)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}
