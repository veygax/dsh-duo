import Foundation
import Observation

/// One open Session: its transcript, the streaming attempt, and composer state.
@MainActor
@Observable
final class SessionModel: Identifiable {
    let id: String
    private(set) var items: [TranscriptItem] = []
    private var index: [String: Int] = [:]
    private(set) var live: LiveAttempt?
    var loading = true
    var loadError: String?
    var hasMore = false
    /// Unsent composer text, kept while the user browses other Sessions.
    var draft = ""
    var commands: [SlashCommand] = []
    var sending = false
    /// Messages sent during a turn. dsh only records them when it takes them in: at its next step
    /// when steering, after the turn when queued. Until then they show here so a send never looks lost.
    private(set) var pending: [PendingMessage] = []

    init(id: String) {
        self.id = id
    }

    func load(items: [TranscriptItem], live: LiveAttempt?, hasMore: Bool) {
        self.items = items
        rebuildIndex()
        settlePending(items)
        self.live = live
        self.hasMore = hasMore
        loading = false
        loadError = nil
    }

    func merge(_ incoming: [TranscriptItem], replace: Bool) {
        defer { settlePending(incoming) }
        if replace {
            items = incoming
            rebuildIndex()
            return
        }
        for item in incoming {
            if let position = index[item.id] {
                items[position] = item
            } else {
                index[item.id] = items.count
                items.append(item)
            }
        }
        // A committed reply supersedes the live preview of the same text.
        if let live, incoming.contains(where: { $0.kind == .text && $0.text == live.text }) {
            self.live?.text = ""
            self.live?.thinking = ""
        }
    }

    func applyLive(_ value: JSONValue) {
        if let full = value["live"] {
            live = full.isNull ? nil : try? full.decode(LiveAttempt.self)
            return
        }
        guard let delta = value["delta"], let attemptId = delta["attemptId"]?.string else { return }
        if delta["reset"]?.bool == true || live?.attemptId != attemptId {
            live = LiveAttempt(attemptId: attemptId, thinking: "", text: "", tools: [])
        }
        if let thinking = delta["thinking"]?.string { live?.thinking += thinking }
        if let text = delta["text"]?.string { live?.text += text }
        if let tools = try? delta["tools"]?.decode([LiveTool].self) { live?.tools = tools }
    }

    func addPending(_ text: String, steer: Bool) -> PendingMessage.ID {
        let message = PendingMessage(text: text, steer: steer)
        pending.append(message)
        return message.id
    }

    func dropPending(_ id: PendingMessage.ID) {
        pending.removeAll { $0.id == id }
    }

    /// The transcript now holds these messages, so their stand-ins go.
    private func settlePending(_ incoming: [TranscriptItem]) {
        guard !pending.isEmpty else { return }
        for item in incoming where item.kind == .user {
            if let match = pending.firstIndex(where: { $0.text == item.text }) { pending.remove(at: match) }
        }
    }

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    /// Whether the newest user message has not been answered yet.
    var awaitingReply: Bool {
        guard let last = items.last(where: { $0.kind != .notice }) else { return false }
        return last.kind == .user
    }
}

struct PendingMessage: Identifiable {
    let id = UUID()
    let text: String
    /// Joins the running turn rather than waiting for it to end.
    let steer: Bool
}
