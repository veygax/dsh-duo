import SwiftUI

/// The current goal, docked just above the composer. It carries the objective, its phase and
/// round budget, and the same pause/resume/edit/clear verbs the desktop's goal strip offers.
struct GoalBar: View {
    @Environment(HostStore.self) private var store
    let sessionId: String
    @State private var editing = false
    @State private var confirmingClear = false

    private var goal: Goal? {
        guard let goal = store.sessions[sessionId]?.goal, goal.isVisible else { return nil }
        return goal
    }

    var body: some View {
        if let goal {
            bar(goal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sheet(isPresented: $editing) {
                    GoalEditorSheet(goal: goal) { objective in
                        await store.editGoal(goal, objective: objective, in: sessionId)
                    }
                }
                .confirmationDialog("Clear this goal?", isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Clear Goal", role: .destructive) {
                        Haptics.press()
                        Task { await store.clearGoal(goal, in: sessionId) }
                    }
                    Button("Cancel", role: .cancel) { Haptics.tap() }
                } message: {
                    Text("The objective is removed from this session. Its history stays in the conversation.")
                }
        }
    }

    private func bar(_ goal: Goal) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(for: goal))
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: goal))
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label(for: goal))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Round \(goal.roundsStarted) of \(goal.maxGoalRounds)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(goal.objective)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let blocker = goal.blockedReason {
                    Text(blocker.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Menu {
                goalActions(goal)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Goal actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 22), isUniform: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label(for: goal)): \(goal.objective)")
    }

    @ViewBuilder
    private func goalActions(_ goal: Goal) -> some View {
        if goal.phase == .active && goal.activation != .disarmed {
            Button("Pause Goal", systemImage: "pause.circle") {
                Haptics.selection()
                Task { await store.pauseGoal(goal, in: sessionId) }
            }
        } else if goal.phase == .paused || goal.isDisarmed {
            Button("Resume Goal", systemImage: "play.circle") {
                Haptics.selection()
                Task { await store.resumeGoal(goal, in: sessionId) }
            }
        }
        Button("Edit Goal…", systemImage: "pencil") {
            Haptics.tap()
            editing = true
        }
        Button("Copy Objective", systemImage: "doc.on.doc") {
            Haptics.tap()
            UIPasteboard.general.string = goal.objective
        }
        Divider()
        Button("Clear Goal", systemImage: "trash", role: .destructive) {
            Haptics.tap()
            confirmingClear = true
        }
    }

    private func label(for goal: Goal) -> String {
        switch goal.phase {
        case .active: goal.activation == .disarmed ? "Inactive Goal" : "Ongoing Goal"
        case .paused: "Paused Goal"
        case .blocked: "Blocked Goal"
        case .complete: "Goal"
        }
    }

    private func symbol(for goal: Goal) -> String {
        switch goal.phase {
        case .active: goal.activation == .disarmed ? "pause.circle.fill" : "target"
        case .paused: "pause.circle"
        case .blocked: "exclamationmark.octagon.fill"
        case .complete: "checkmark.circle"
        }
    }

    private func tint(for goal: Goal) -> Color {
        switch goal.phase {
        case .active: .accentColor
        case .paused: .orange
        case .blocked: .red
        case .complete: .green
        }
    }
}

/// Multi-line objective editor; the Host still owns the round cap and phase.
private struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal
    let save: (String) async -> Bool
    @State private var draft: String
    @State private var saving = false
    @FocusState private var focused: Bool

    init(goal: Goal, save: @escaping (String) async -> Bool) {
        self.goal = goal
        self.save = save
        _draft = State(initialValue: goal.objective)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Objective") {
                    TextField("What should DeepSeek finish?", text: $draft, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                }
                Section {
                    LabeledContent("Rounds", value: "\(goal.roundsStarted) of \(goal.maxGoalRounds)")
                    LabeledContent("Phase", value: goal.phase.rawValue.capitalized)
                }
            }
            .navigationTitle("Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: commit)
                        .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func commit() {
        let objective = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, !saving else { return }
        saving = true
        Task {
            let saved = await save(objective)
            saving = false
            if saved { dismiss() }
        }
    }
}
