import SwiftUI

/// Message field with mode, model, thinking, and slash-command controls beside it.
struct ComposerView: View {
    @Environment(HostStore.self) private var store
    @Bindable var model: SessionModel
    let sessionId: String
    var focused: FocusState<Bool>.Binding
    @State private var showCommands = false
    @Namespace private var glass

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
                        focused.wrappedValue = true
                    }
                    .glassEffectID("commands", in: glass)
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField(running ? "Steer this turn…" : "Message DeepSeek", text: $model.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .focused(focused)
                        .textInputAutocapitalization(.sentences)
                        // While a turn runs the send control is a menu, which has no shortcut of its own.
                        .onKeyPress(.return, phases: .down) { press in
                            guard running, press.modifiers.contains(.command) else { return .ignored }
                            send(steer: true)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            focused.wrappedValue = false
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
                            focused.wrappedValue = true
                            if model.commands.isEmpty { Task { await store.loadCommands(for: model) } }
                        })
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Commands and skills")
                        Spacer(minLength: 0)
                        ThinkingControl(sessionId: sessionId)
                        sendButton
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // The whole card is the field's target, not just its first line; the menus and buttons keep their taps.
                .contentShape(.rect)
                .onTapGesture { focused.wrappedValue = true }
                // Concentric with the display corners it sits beside.
                .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 24), isUniform: true))
                .glassEffectID("composer", in: glass)
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
            Button("Stop", systemImage: "stop.fill") {
                Haptics.press()
                Task { await store.cancel(sessionId) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityHint("Stops the current turn")
        } else if running {
            // Tap steers; press and hold for the choice. Menu's primary action is the system's
            // tap-or-hold control, so the hold gets its haptic and menu presentation for free.
            Menu {
                Button("Steer This Turn", systemImage: "arrow.turn.down.right") { send(steer: true) }
                Button("Send After This Turn", systemImage: "clock") { send(steer: false) }
            } label: {
                sendLabel
            } primaryAction: {
                send(steer: true)
            }
            .menuOrder(.fixed)
            .sendButtonStyle(disabled: !canSend, sending: model.sending)
            .accessibilityHint("Steers the current turn; press and hold to send after it instead")
        } else {
            Button(action: { send(steer: false) }) { sendLabel }
                .sendButtonStyle(disabled: !canSend, sending: model.sending)
                // A real shortcut, so it appears in the hardware keyboard's ⌘ overlay.
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Sends the message")
        }
    }

    private var sendLabel: some View {
        Label("Send", systemImage: "arrow.up")
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

private extension View {
    func sendButtonStyle(disabled: Bool, sending: Bool) -> some View {
        labelStyle(.iconOnly)
            .fontWeight(.semibold)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(disabled)
            .overlay { if sending { ProgressView().controlSize(.small) } }
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
        .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 20), isUniform: true))
        .accessibilityLabel("Commands and skills")
    }
}
