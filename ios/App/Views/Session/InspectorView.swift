import SwiftUI

/// Secondary pane in full screen: what DeepSeek is doing right now, the latest
/// turn's tool calls and reasoning, and the Session's setup.
struct InspectorView: View {
    @Environment(HostStore.self) private var store
    let model: SessionModel
    let sessionId: String

    private var latestTurn: [TranscriptItem] {
        guard let start = model.items.lastIndex(where: { $0.kind == .user }) else { return model.items }
        return Array(model.items[start...])
    }

    var body: some View {
        let session = store.sessions[sessionId]
        let tools = latestTurn.filter { $0.kind == .tool }
        let thinking = latestTurn.filter { $0.kind == .thinking }.compactMap(\.text).joined(separator: "\n\n")
        List {
            Section("Now") {
                if let live = model.live, !live.thinking.isEmpty, live.text.isEmpty {
                    Label("Thinking", systemImage: "brain").symbolEffect(.pulse, options: .repeating)
                    Text(live.thinking.suffix(1200))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if session?.running == true {
                    WorkingIndicator()
                } else if !store.questions(for: sessionId).isEmpty {
                    Label("Waiting for your answer", systemImage: "questionmark.bubble.fill").foregroundStyle(.orange)
                } else {
                    Label("Idle", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }

            Section("This Turn · \(tools.count) Tool Call\(tools.count == 1 ? "" : "s")") {
                if tools.isEmpty {
                    Text("No tool calls yet").foregroundStyle(.secondary)
                }
                ForEach(tools.reversed()) { tool in
                    ToolCallView(item: tool)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowBackground(Color.clear)
                }
            }

            if !thinking.isEmpty {
                Section("Reasoning") {
                    Text(thinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Session") {
                LabeledContent("Mode") {
                    Label(store.mode(of: session).name, systemImage: store.mode(of: session).symbol)
                }
                LabeledContent("Model", value: store.catalog.displayName(session?.model ?? store.catalog.defaultModel))
                if let effort = store.catalog.effortName(session?.model ?? store.catalog.defaultModel) {
                    LabeledContent("Thinking", value: effort)
                }
                if let cwd = session?.cwd {
                    LabeledContent("Folder") {
                        Text(cwd).font(.caption.monospaced()).lineLimit(2).truncationMode(.head)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy, value: tools.map(\.id))
    }
}
