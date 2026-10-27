import SwiftUI

/// A tool call waiting for permission, laid out like a system permission prompt: what wants to run,
/// why, and Deny beside Allow Once.
struct ApprovalCard: View {
    @Environment(HostStore.self) private var store
    let pending: PendingQuestion
    @State private var submitting = false

    static let allow = "Allow Once"
    static let deny = "Deny"

    private var question: Question? { pending.questions.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.orange.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow \(question?.header ?? "this tool") to run?")
                        .font(.headline)
                    Text("DeepSeek needs your permission to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = question?.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: detail.count < 300)
            }

            HStack(spacing: 10) {
                Button(role: .cancel, action: { answer(Self.deny) }) {
                    Text(Self.deny).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(action: { answer(Self.allow) }) {
                    Text(Self.allow).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            .disabled(submitting)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 24), isUniform: true))
        .frame(maxWidth: 780)
        .onAppear {
            Haptics.attention()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request")
    }

    private func answer(_ label: String) {
        guard !submitting, let question else { return }
        label == Self.allow ? Haptics.success() : Haptics.press()
        submitting = true
        Task {
            if await !store.answer(pending, [QuestionAnswer(id: question.id, selected: [label])]) { submitting = false }
        }
    }
}
