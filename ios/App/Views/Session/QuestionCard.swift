import SwiftUI

/// A question DeepSeek is waiting on. A single choice answers in one tap.
struct QuestionCard: View {
    @Environment(HostStore.self) private var store
    let pending: PendingQuestion
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitting = false

    /// One single-select question answers as soon as an option is tapped.
    private var instant: Bool {
        pending.questions.count == 1 && pending.questions[0].multiSelect == false && !pending.questions[0].options.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("DeepSeek needs your input", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(pending.questions) { question in
                VStack(alignment: .leading, spacing: 10) {
                    if let header = question.header {
                        Text(header).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(question.question)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = question.detail, !detail.isEmpty {
                        ScrollView { MarkdownText(detail) }
                            .frame(maxHeight: 220)
                            .fixedSize(horizontal: false, vertical: detail.count < 400)
                    }
                    options(question)
                    TextField(question.options.isEmpty ? "Your answer" : "Something else…", text: binding(question.id), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { submit() }
                }
            }

            if !instant || pending.questions.contains(where: { !(custom[$0.id] ?? "").isEmpty }) {
                Button(action: submit) {
                    Label("Send Answer", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!complete || submitting)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 24))
        .frame(maxWidth: 780)
        .onAppear {
            Haptics.attention()
            // Put the keyboard away so the whole question and its choices are visible.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from DeepSeek")
    }

    @ViewBuilder
    private func options(_ question: Question) -> some View {
        if !question.options.isEmpty {
            // An even number of columns divides cleanly across the fold.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(question.options, id: \.label) { option in
                    let selected = selections[question.id, default: []].contains(option.label)
                    Button {
                        toggle(option.label, in: question)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if question.multiSelect {
                                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                                }
                                Text(option.label).font(.subheadline.weight(.semibold))
                            }
                            if let description = option.description {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.fill.tertiary),
                                    in: .rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                        }
                    }
                    .buttonStyle(HapticPressStyle())
                    .disabled(submitting)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 })
    }

    private func toggle(_ label: String, in question: Question) {
        var set = selections[question.id, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.id] = set
        if instant { submit() }
    }

    private var complete: Bool {
        pending.questions.allSatisfy { question in
            !(selections[question.id] ?? []).isEmpty || !(custom[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        guard complete, !submitting else { return }
        submitting = true
        let answers = pending.questions.map { question in
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A single-select custom answer replaces the choice; a multi-select one adds to it.
            let selected = question.multiSelect || text.isEmpty ? Array(selections[question.id] ?? []) : []
            return QuestionAnswer(id: question.id, selected: selected, custom: text.isEmpty ? nil : text)
        }
        Task {
            if await !store.answer(pending, answers) { submitting = false }
        }
    }
}
