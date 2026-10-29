import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Message field with mode, model, thinking, slash-command and attachment controls beside it.
struct ComposerView: View {
    @Environment(HostStore.self) private var store
    @Bindable var model: SessionModel
    let sessionId: String
    var focused: FocusState<Bool>.Binding
    @State private var showCommands = false
    @State private var drafts: [AttachmentDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    /// Photos or files being read off the phone, before they join the rail.
    @State private var loadingAttachments = 0
    @Namespace private var glass

    private var session: SessionInfo? { store.sessions[sessionId] }
    private var running: Bool { session?.running == true }
    private var subagentMode: SubagentInfo.Mode? { session?.subagent?.mode }
    /// A finished one-shot or external subagent is a record, not a conversation to reply to.
    private var readOnly: Bool { subagentMode?.acceptsMessages == false }
    private var placeholder: String {
        if session?.isSubagent == true { return running ? "Steer this subagent…" : "Message this subagent" }
        return running ? "Steer this turn…" : "Message DeepSeek"
    }
    private var trimmedDraft: String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The command the draft names, once its name is complete.
    private var activeCommand: SlashCommand? {
        guard model.draft.hasPrefix("/") else { return nil }
        let name = model.draft.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let name else { return nil }
        return model.commands.first { $0.name == name }
    }
    /// A command decides whether it takes attachments; a plain prompt always does.
    private var attachmentsAllowed: Bool {
        guard let activeCommand else { return true }
        return activeCommand.acceptsAttachments
    }
    private var canAttach: Bool {
        !readOnly && !model.sending && loadingAttachments == 0 && store.connection == .online && attachmentsAllowed
    }
    private var canSend: Bool {
        !readOnly && !model.sending && store.connection == .online
            && (!trimmedDraft.isEmpty || !drafts.isEmpty)
            && (drafts.isEmpty || attachmentsAllowed)
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
            if readOnly {
                ReadOnlySubagentCard(mode: subagentMode ?? .unknown, running: running) {
                    Haptics.press()
                    Task { await store.cancel(sessionId) }
                }
                .frame(maxWidth: 780)
            } else {
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
                    if !drafts.isEmpty {
                        DraftRail(drafts: drafts, canRemove: !model.sending, remove: remove)
                    }
                    if let activeCommand, !activeCommand.acceptsAttachments, !drafts.isEmpty {
                        Label("\(activeCommand.name) doesn't take attachments.", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        attachButton
                        TextField(placeholder, text: $model.draft, axis: .vertical)
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
                    }

                    HStack(spacing: 8) {
                        if session?.isSubagent != true {
                            ModeMenu(sessionId: sessionId)
                        }
                        ModelMenu(sessionId: sessionId)
                        PermissionMenu(sessionId: sessionId)
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
        }
        .onChange(of: model.draft) { _, draft in
            if !draft.hasPrefix("/") { showCommands = false }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 8, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await addFiles(urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { store.show(error) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
    }

    /// The paperclip: a native photo picker, or the document browser for any file.
    private var attachButton: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
            if session?.isSubagent != true {
                Button("Choose File", systemImage: "folder") { showFiles = true }
            }
        } label: {
            Label("Attach", systemImage: "paperclip")
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .menuOrder(.fixed)
        .disabled(!canAttach)
        .overlay { if loadingAttachments > 0 { ProgressView().controlSize(.small) } }
        .accessibilityLabel("Attach a photo or file")
        .accessibilityHint(session?.isSubagent == true ? "Adds a photo to your message" : "Adds a photo or a file from Files to your message")
    }

    @ViewBuilder
    private var sendButton: some View {
        if running && trimmedDraft.isEmpty && drafts.isEmpty {
            Button("Stop", systemImage: "stop.fill") {
                Haptics.press()
                Task { await store.cancel(sessionId) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .keyboardShortcut(".", modifiers: .command)
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
        let sending = drafts
        model.draft = ""
        showCommands = false
        // The rail stays until the Mac has the bytes, showing each attachment's progress.
        Task {
            if await store.send(text, attachments: sending, in: model, steer: steer) {
                withAnimation(.snappy) { drafts.removeAll { draft in sending.contains { $0 === draft } } }
            } else {
                model.draft = text
            }
        }
    }

    private func remove(_ draft: AttachmentDraft) {
        Haptics.press()
        withAnimation(.snappy) { drafts.removeAll { $0.id == draft.id } }
    }

    /// Decode the picked photos off the main thread, then add them to the rail.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photoItems = []
        loadingAttachments += 1
        defer { loadingAttachments -= 1 }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let prepared = await Task.detached(priority: .userInitiated) {
                AttachmentPayload.image(data: data, name: "Photo")
            }.value
            guard let prepared else {
                store.show(RemoteError(code: "duo/unsupported", message: "That photo isn't in a format DeepSeek can read."))
                continue
            }
            withAnimation(.snappy) { drafts.append(AttachmentDraft(prepared)) }
            Haptics.tap()
        }
    }

    /// Read the picked files off the main thread; images become photos, everything else stays verbatim.
    private func addFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        loadingAttachments += 1
        defer { loadingAttachments -= 1 }
        for url in urls {
            let prepared = await Task.detached(priority: .userInitiated) {
                AttachmentPayload.pickedFile(url)
            }.value
            guard let prepared else {
                store.show(RemoteError(code: "duo/too-large", message: "\(url.lastPathComponent) is too large to attach (64 MB at most)."))
                continue
            }
            withAnimation(.snappy) { drafts.append(AttachmentDraft(prepared)) }
            Haptics.tap()
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

/// Finished subagent conversations keep their transcript but no composer: there is nobody left to ask.
private struct ReadOnlySubagentCard: View {
    let mode: SubagentInfo.Mode
    let running: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                Text("This subagent conversation is read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if running {
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                    .accessibilityHint("Stops this subagent")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(corners: .concentric(minimum: 24), isUniform: true))
        .accessibilityElement(children: .contain)
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
                            } else if command.acceptsAttachments {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Takes attachments")
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
