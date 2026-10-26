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

    init(id: String) {
        self.id = id
    }

    func load(items: [TranscriptItem], live: LiveAttempt?, hasMore: Bool) {
        self.items = items
        rebuildIndex()
        self.live = live
        self.hasMore = hasMore
        loading = false
        loadError = nil
    }

    func merge(_ incoming: [TranscriptItem], replace: Bool) {
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

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    /// Whether the newest user message has not been answered yet.
    var awaitingReply: Bool {
        guard let last = items.last(where: { $0.kind != .notice }) else { return false }
        return last.kind == .user
    }
}
