import Foundation
import Observation
import QuickLook
import SwiftUI
import UserNotifications
import UIKit

/// App-wide state for the paired dsh Host: connection, Sessions, Workspaces,
/// modes, models, questions, and every operation the UI performs.
@MainActor
@Observable
final class HostStore {
    enum Connection: Equatable {
        case unpaired
        case connecting
        case hostOffline
        case online
        case failed(String)
    }

    private(set) var pairing: Pairing?
    private(set) var connection: Connection = .unpaired
    private(set) var hostVersion: String?
    /// Whether the paired Mac has an Apple push key for this app (set up by `ios/scripts/install.sh`).
    private(set) var pushEnabledOnHost: Bool?
    private(set) var sessions: [String: SessionInfo] = [:]
    private(set) var workspaces: [Workspace] = []
    private(set) var presets: [Preset] = []
    private(set) var catalog = ModelCatalog(groups: [], defaultModel: nil)
    private(set) var permissionPresets: [PermissionPreset] = []
    private(set) var questions: [String: PendingQuestion] = [:]
    private(set) var loadedOnce = false
    private var models: [String: SessionModel] = [:]

    /// Split view selection; also drives which Session counts as "visible" for notifications.
    var selectedSessionId: String? {
        didSet { if isActive { Notifier.shared.read(selectedSessionId) } }
    }
    /// Transient message shown at the top of the window.
    var banner: Banner?
    var isActive = true

    private var client: RelayClient?
    private var pushToken: String?

    struct Banner: Identifiable, Equatable {
        var id = UUID()
        var title: String
        var message: String?
        var sessionId: String?
        var isError = false
    }

    init() {
        if let stored = PairingStore.load() { attach(stored) }
    }

    var hostName: String { pairing?.hostName ?? "dsh" }

    // MARK: Pairing and connection

    @discardableResult
    func pair(link: String) -> Bool {
        guard let pairing = Pairing.parse(link, deviceId: PairingStore.deviceId) else { return false }
        PairingStore.save(pairing)
        attach(pairing)
        Haptics.success()
        return true
    }

    func unpair() {
        client?.disconnect()
        client = nil
        PairingStore.clear()
        pairing = nil
        sessions = [:]
        workspaces = []
        questions = [:]
        models = [:]
        selectedSessionId = nil
        loadedOnce = false
        connection = .unpaired
    }

    private func attach(_ pairing: Pairing) {
        client?.disconnect()
        self.pairing = pairing
        guard let client = RelayClient(pairing: pairing) else {
            connection = .failed("The pairing link is invalid")
            return
        }
        self.client = client
        client.onState = { [weak self] state in self?.connectionChanged(state) }
        client.onEvent = { [weak self] event in self?.handle(event: event) }
        connection = .connecting
        if isActive { client.connect() }
    }

    /// Called from scene phase changes. Backgrounded apps hang up so the relay sends pushes instead.
    func setActive(_ active: Bool) {
        isActive = active
        if active { Notifier.shared.read(selectedSessionId) }
        if active { client?.connect() } else { client?.disconnect() }
    }

    func reconnect() {
        client?.disconnect()
        client?.connect()
    }

    private func connectionChanged(_ state: RelayClient.State) {
        switch state {
        case .idle: if pairing != nil { connection = .connecting }
        case .connecting: connection = .connecting
        case .online(host: false): connection = .hostOffline
        case .online(host: true):
            connection = .online
            Task {
                await hello()
                await registerPush()
                await loadPermissions()
            }
        case .failed(let message): connection = .failed(message)
        }
    }

    func setPushToken(_ token: String) {
        pushToken = token
        Task { await registerPush() }
    }

    /// Hand the APNs token to the paired Mac (sealed, through the relay). The Mac sends pushes
    /// itself with the key of the team that signed this build; the relay never holds Apple keys.
    private func registerPush() async {
        guard let client, client.hostOnline, let pushToken else { return }
        let value = try? await client.request("push.register", [
            "token": pushToken,
            "env": PushEnvironment.current,
            "topic": Bundle.main.bundleIdentifier ?? "",
        ])
        if let enabled = value?["enabled"]?.bool { pushEnabledOnHost = enabled }
    }

    private func hello() async {
        guard let client else { return }
        do {
            let value = try await client.request("hello", [
                "device": ["name": UIDevice.current.name, "model": UIDevice.current.model],
            ])
            hostVersion = value["version"]?.string
            pushEnabledOnHost = value["push"]?["enabled"]?.bool
            presets = (try? value["presets"]?.decode([Preset].self)) ?? []
            workspaces = (try? value["workspaces"]?.decode([Workspace].self)) ?? []
            let list = (try? value["sessions"]?.decode([SessionInfo].self)) ?? []
            sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            loadedOnce = true
            // Re-open any Session already on screen so its stream resumes after a reconnect.
            for model in models.values { Task { await open(model) } }
            Task { await loadCatalog() }
        } catch {
            show(error)
        }
    }

    func refresh() async {
        guard let client else { return }
        if let list = try? await client.decode("sessions.list", as: [SessionInfo].self) {
            sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
        if let list = try? await client.decode("workspaces.list", as: [Workspace].self) { workspaces = list }
    }

    func loadCatalog() async {
        guard let client, let value = try? await client.request("models.catalog") else { return }
        let groups = (try? value["groups"]?.decode([ProviderGroup].self)) ?? []
        var fallback: ModelRef?
        if let provider = value["default"]?["provider"]?.string, let model = value["default"]?["model"]?.string {
            fallback = ModelRef(provider: provider, model: model, effort: value["default"]?["reasoningEffort"]?.string)
        }
        catalog = ModelCatalog(groups: groups, defaultModel: fallback)
    }

    // MARK: Events

    private func handle(event: JSONValue) {
        switch event["ev"]?.string {
        case "sessions.upsert":
            if let session = try? event["session"]?.decode(SessionInfo.self) { sessions[session.id] = session }
        case "permissions.changed":
            Task { await loadPermissions() }
        case "sessions.remove":
            if let id = event["sessionId"]?.string { sessions[id] = nil }
        case "workspaces.changed":
            if let list = try? event["workspaces"]?.decode([Workspace].self) { workspaces = list }
        case "session.items":
            guard let id = event["sessionId"]?.string, let model = models[id],
                  let items = try? event["items"]?.decode([TranscriptItem].self) else { return }
            model.merge(items, replace: event["replace"]?.bool == true)
            if let hasMore = event["hasMore"]?.bool {
                model.hasMore = hasMore
                if hasMore { Task { await loadHistory(model) } }
            }
        case "session.live":
            guard let id = event["sessionId"]?.string, let model = models[id] else { return }
            model.applyLive(event)
        case "question":
            guard let sessionId = event["sessionId"]?.string, let callId = event["callId"]?.string,
                  let items = try? event["questions"]?.decode([Question].self) else { return }
            let isNew = questions[callId] == nil
            questions[callId] = PendingQuestion(callId: callId, sessionId: sessionId,
                                                title: event["title"]?.string ?? "Session", questions: items)
            if isNew && !isVisible(sessionId) {
                Haptics.attention()
                let first = items.first
                let approval = first?.intent == "approval"
                Notifier.shared.local(title: event["title"]?.string ?? "dsh",
                                      body: approval ? first?.detail ?? "" : first?.question ?? "DeepSeek has a question",
                                      sessionId: sessionId, kind: approval ? "approval" : "question", callId: callId,
                                      questionId: first?.id, tool: approval ? first?.header : nil)
            }
        case "question.resolved":
            if let callId = event["callId"]?.string {
                questions[callId] = nil
                // Answered here or on the Mac: its notification would only offer a choice that is gone.
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [callId, "question-\(callId)", "approval-\(callId)"])
            }
        case "turn.finished":
            guard let sessionId = event["sessionId"]?.string else { return }
            let title = event["title"]?.string ?? "Session"
            let summary = event["summary"]?.string ?? "Finished"
            if isVisible(sessionId) {
                Haptics.success()
            } else {
                Notifier.shared.local(title: title, body: summary, sessionId: sessionId, kind: "turn",
                                      itemId: event["itemId"]?.string)
            }
        default:
            break
        }
    }

    private func isVisible(_ sessionId: String) -> Bool {
        isActive && selectedSessionId == sessionId
    }

    // MARK: Derived lists

    var sortedSessions: [SessionInfo] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Sessions grouped for the sidebar: each Workspace in Host order, then unassigned Sessions.
    func sections(matching query: String) -> [(workspace: Workspace?, sessions: [SessionInfo])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = sortedSessions.filter { session in
            needle.isEmpty || session.title.lowercased().contains(needle) || (session.cwd?.lowercased().contains(needle) ?? false)
        }
        var result: [(Workspace?, [SessionInfo])] = []
        var placed = Set<String>()
        for workspace in workspaces {
            let members = visible.filter { $0.workspaceId == workspace.id }
            placed.formUnion(members.map(\.id))
            if !members.isEmpty || needle.isEmpty { result.append((workspace, members)) }
        }
        let rest = visible.filter { !placed.contains($0.id) }
        if !rest.isEmpty { result.append((nil, rest)) }
        return result
    }

    func questions(for sessionId: String) -> [PendingQuestion] {
        questions.values.filter { $0.sessionId == sessionId }.sorted { $0.callId < $1.callId }
    }

    func mode(of session: SessionInfo?) -> Mode {
        Mode.of(session?.preset, presets: presets)
    }

    var modes: [Mode] { Mode.all(presets) }

    // MARK: Session operations

    /// Open the Session a notification is about, landing on its row once the transcript shows.
    func open(_ target: NotificationTarget) {
        model(for: target.sessionId).landing = target
        selectedSessionId = target.sessionId
    }

    func model(for sessionId: String) -> SessionModel {
        if let model = models[sessionId] { return model }
        let model = SessionModel(id: sessionId)
        models[sessionId] = model
        return model
    }

    /// Read the rest of the history, newest page first, right after the recent window opens, so
    /// scrolling up never reaches an edge and waits.
    func loadHistory(_ model: SessionModel) async {
        guard let client, !model.loadingOlder else { return }
        model.loadingOlder = true
        defer { model.loadingOlder = false }
        while model.hasMore, !model.loading {
            guard let value = try? await client.request("session.older", ["sessionId": model.id]) else { return }
            let items = (try? value["items"]?.decode([TranscriptItem].self)) ?? []
            model.prepend(items, hasMore: value["hasMore"]?.bool == true)
            if items.isEmpty { return }
        }
    }

    func open(_ model: SessionModel) async {
        guard let client else { return }
        do {
            let value = try await client.request("session.open", ["sessionId": model.id])
            let items = (try? value["items"]?.decode([TranscriptItem].self)) ?? []
            let live = value["live"].flatMap { $0.isNull ? nil : try? $0.decode(LiveAttempt.self) }
            model.load(items: items, live: live, hasMore: value["hasMore"]?.bool == true)
            Task { await loadHistory(model) }
            if let session = try? value["session"]?.decode(SessionInfo.self) { sessions[session.id] = session }
            Task { await loadCommands(for: model) }
        } catch {
            model.loading = false
            model.loadError = error.localizedDescription
        }
    }

    /// Screens showing each Session. Folding or unfolding rebuilds the screen, and the new one
    /// can appear before the old one disappears, so the Host is told to stop only when none is left.
    private var viewers: [String: Int] = [:]

    func attach(_ model: SessionModel) {
        viewers[model.id, default: 0] += 1
    }

    func detach(_ model: SessionModel) {
        let count = (viewers[model.id] ?? 1) - 1
        viewers[model.id] = count > 0 ? count : nil
        guard count <= 0 else { return }
        Task {
            // Give a replacement screen a moment to attach before unsubscribing.
            try? await Task.sleep(for: .seconds(1))
            guard viewers[model.id] == nil, let client, client.hostOnline else { return }
            _ = try? await client.request("session.close", ["sessionId": model.id])
        }
    }

    func loadCommands(for model: SessionModel) async {
        guard let client else { return }
        if let commands = try? await client.decode("commands.list", ["sessionId": model.id], as: [SlashCommand].self) {
            model.commands = commands
        }
    }

    /// Send the composer text: a `/command` runs on the Host, anything else becomes a prompt.
    func send(_ text: String, in model: SessionModel, steer: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty else { return false }
        model.sending = true
        defer { model.sending = false }
        let echo = sessions[model.id]?.running == true && !trimmed.hasPrefix("/")
            ? model.addPending(trimmed, steer: steer) : nil
        do {
            let value = try await client.request("session.prompt", [
                "sessionId": model.id,
                "text": trimmed,
                "mode": steer ? "steer" : "queue",
                "timeZone": TimeZone.current.identifier,
            ])
            // Command output arrives in the transcript as a `command/done` notice.
            if value["kind"]?.string == "command" { Haptics.success() }
            if var session = sessions[model.id] {
                session.blank = false
                session.updatedAt = Date().timeIntervalSince1970 * 1000
                sessions[model.id] = session
            }
            return true
        } catch {
            if let echo { model.dropPending(echo) }
            Haptics.error()
            show(error)
            return false
        }
    }

    func cancel(_ sessionId: String) async {
        guard let client else { return }
        do {
            _ = try await client.request("session.cancel", ["sessionId": sessionId])
            Haptics.warning()
        } catch { show(error) }
    }

    func createSession(workspaceId: String?, cwd: String? = nil, mode: String?) async -> String? {
        guard let client else { return nil }
        var params: [String: Any] = [:]
        if let workspaceId { params["workspaceId"] = workspaceId } else if let cwd { params["cwd"] = cwd }
        if let mode { params["preset"] = mode }
        do {
            let session = try await client.decode("session.create", params, as: SessionInfo.self)
            sessions[session.id] = session
            Haptics.success()
            return session.id
        } catch {
            show(error)
            return nil
        }
    }

    func selectModel(_ ref: ModelRef, for sessionId: String) async {
        guard let client else { return }
        var params: [String: Any] = ["sessionId": sessionId, "provider": ref.provider, "model": ref.model]
        if let effort = ref.effort { params["effort"] = effort }
        do {
            let selected = try await client.decode("session.model", params, as: ModelRef.self)
            sessions[sessionId]?.model = selected
        } catch { show(error) }
    }

    func loadPermissions() async {
        guard let client, let value = try? await client.request("permissions.catalog") else { return }
        permissionPresets = (try? value["presets"]?.decode([PermissionPreset].self)) ?? []
    }

    /// Switch what DeepSeek may do in a Session. Shown at once; put back if the Mac refuses.
    func setPermission(_ preset: PermissionPreset, for sessionId: String) async {
        guard let client else { return }
        let previous = sessions[sessionId]?.permission
        sessions[sessionId]?.permission = preset.id
        do {
            _ = try await client.request("permission.set", ["sessionId": sessionId, "preset": preset.id])
        } catch {
            sessions[sessionId]?.permission = previous
            show(error)
        }
    }

    /// Switch mode. dsh fixes a Session's mode at its first turn, so a started Session gets a fresh sibling instead.
    func selectMode(_ mode: Mode, for session: SessionInfo) async -> String? {
        guard let client else { return nil }
        if !session.blank {
            let created = await createSession(workspaceId: session.workspaceId, cwd: session.cwd, mode: mode.id)
            if let created { selectedSessionId = created }
            return created
        }
        do {
            let value = try await client.request("session.preset", ["sessionId": session.id, "preset": mode.id])
            sessions[session.id]?.preset = value["preset"]?.string ?? mode.id
            return session.id
        } catch {
            show(error)
            return nil
        }
    }

    func rename(_ sessionId: String, to title: String) async {
        guard let client, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try await client.request("session.rename", ["sessionId": sessionId, "title": title])
            sessions[sessionId]?.title = title
        } catch { show(error) }
    }

    func answer(_ question: PendingQuestion, _ answers: [QuestionAnswer]) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.request("question.answer", [
                "sessionId": question.sessionId,
                "callId": question.callId,
                "answers": answers.map(\.json),
            ])
            questions[question.callId] = nil
            Haptics.success()
            return true
        } catch {
            Haptics.error()
            show(error)
            return false
        }
    }

    // MARK: Workspaces

    func listDirectory(_ path: String?) async throws -> DirectoryListing {
        guard let client else { throw RemoteError(code: "duo/unpaired", message: "Not paired") }
        var params: [String: Any] = [:]
        if let path { params["path"] = path }
        return try await client.decode("fs.list", params, as: DirectoryListing.self)
    }

    func addWorkspace(path: String) async -> Workspace? {
        guard let client else { return nil }
        do {
            let workspace = try await client.decode("workspaces.add", ["path": path], as: Workspace.self)
            if !workspaces.contains(where: { $0.id == workspace.id }) { workspaces.append(workspace) }
            Haptics.success()
            return workspace
        } catch {
            show(error)
            return nil
        }
    }

    // MARK: Files

    enum Download {
        case file(URL)
        case folder(HostFolder)
    }

    /// Fetch what DeepSeek linked to: a file into a private temporary folder for QuickLook, or a
    /// folder's listing to pick a file from. A relative path is the Host's to resolve, against the
    /// Session's folder.
    func download(_ path: String, in sessionId: String) async -> Download? {
        guard let client else { return nil }
        do {
            let value = try await client.request("fs.read", ["path": path, "sessionId": sessionId], timeout: .seconds(60))
            if value["folder"]?.bool == true { return .folder(try value.decode(HostFolder.self)) }
            guard let name = value["name"]?.string, let encoded = value["data"]?.string,
                  let data = Data(base64Encoded: encoded) else {
                throw RemoteError(code: "duo/bad-response", message: "The Mac sent an unreadable file")
            }
            let folder = URL.temporaryDirectory.appending(path: "Previews/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appending(path: name)
            try data.write(to: url)
            // QuickLook shows text by its type: source files and extensionless ones read as plain text.
            if !QLPreviewController.canPreview(url as NSURL), String(data: data, encoding: .utf8) != nil {
                let text = folder.appending(path: name + ".txt")
                try FileManager.default.moveItem(at: url, to: text)
                url = text
            }
            return .file(url)
        } catch {
            show(error)
            return nil
        }
    }

    // MARK: Presentation

    func show(_ error: Error) {
        let message = (error as? RemoteError)?.message ?? error.localizedDescription
        banner = Banner(title: "Something went wrong", message: message, isError: true)
    }
}
