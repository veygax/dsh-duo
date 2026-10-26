import SwiftUI

/// Message field with mode, model, thinking, and slash-command controls beside it.
struct ComposerView: View {
    @Environment(HostStore.self) private var store
    @Bindable var model: SessionModel
    let sessionId: String
    @FocusState private var focused: Bool
    @State private var showCommands = false

    private var session: SessionInfo? { store.sessions[sessionId] }
    private var running: Bool { session?.running == true }
    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending && store.connection == .online
    }

    /// Text after a leading slash while the user is still typing the command name.
    private var slashQuery: String? {
        guard model.draft.hasPrefix("/"), !model.draft.contains(where: \.isWhitespace) else { return nil }
        return String(model.draft.dropFirst()).lowercased()
    }

    private var matches: [SlashCommand] {
        let query = showCommands ? (slashQuery ?? "") : slashQuery
        guard let query else { return [] }
        let all = model.commands
        if query.isEmpty { return all }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(query) }
        let rest = all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return prefix + rest
    }

    var body: some View {
        FoldAware {
            VStack(spacing: 8) {
                if !matches.isEmpty {
                    SlashCommandList(commands: matches) { command in
                        Haptics.selection()
                        model.draft = "/\(command.name) "
                        showCommands = false
                        focused = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField(running ? "Add to the queue or steer…" : "Message DeepSeek", text: $model.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($focused)
                        .textInputAutocapitalization(.sentences)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            send(steer: false)
                            return .handled
                        }
                        .accessibilityLabel("Message")

                    HStack(spacing: 8) {
                        ModeMenu(sessionId: sessionId)
                        ModelMenu(sessionId: sessionId)
                        Button("Commands", systemImage: "slash.circle", action: tap {
                            withAnimation(.snappy) {
                                showCommands.toggle()
                                if showCommands && model.draft.isEmpty { model.draft = "/" }
                                if !showCommands && model.draft == "/" { model.draft = "" }
                            }
                            focused = true
                            if model.commands.isEmpty { Task { await store.loadCommands(for: model) } }
                        })
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                        sendButton
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            }
            .frame(maxWidth: 780)
            .animation(.snappy, value: matches.map(\.id))
        }
        .onChange(of: model.draft) { _, draft in
            if !draft.hasPrefix("/") { showCommands = false }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if running && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Stop", systemImage: "stop.circle.fill") {
                Haptics.press()
                Task { await store.cancel(sessionId) }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 30))
            .foregroundStyle(.red)
            .buttonStyle(.borderless)
            .accessibilityHint("Stops the current turn")
        } else {
            Button("Send", systemImage: "arrow.up.circle.fill") { send(steer: false) }
                .labelStyle(.iconOnly)
                .font(.system(size: 30))
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .overlay { if model.sending { ProgressView().controlSize(.small) } }
                .contextMenu {
                    if running {
                        Button("Send Now (Steer)", systemImage: "arrow.turn.down.right") { send(steer: true) }
                        Button("Queue After This Turn", systemImage: "text.line.last.and.arrowtriangle.forward") { send(steer: false) }
                    }
                }
                .accessibilityHint(running ? "Queues the message; press and hold to steer now" : "Sends the message")
        }
    }

    private func send(steer: Bool) {
        guard canSend else { return }
        Haptics.press()
        let text = model.draft
        model.draft = ""
        showCommands = false
        Task {
            if await !store.send(text, in: model, steer: steer) { model.draft = text }
        }
    }
}

struct SlashCommandList: View {
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { command in
                    Button { pick(command) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: command.kind == "skill" ? "book.closed" : "command")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("/\(command.name)").font(.body.monospaced().weight(.medium))
                                    if let hint = command.hint {
                                        Text(hint).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    }
                                }
                                if !command.description.isEmpty {
                                    Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if command.kind == "skill" {
                                Text("Skill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.fill.tertiary, in: .capsule)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(.rect)
                    }
                    .buttonStyle(HapticPressStyle())
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: commands.count < 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityLabel("Commands and skills")
    }
}
