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
    /// dsh holds history older than `items`, read a page at a time as the user scrolls up.
    var hasMore = false
    var loadingOlder = false
    /// Unsent composer text, kept while the user browses other Sessions.
    var draft = ""
    var commands: [SlashCommand] = []
    var sending = false
    /// Messages sent during a turn. dsh only records them when it takes them in: at its next step
    /// when steering, after the turn when queued. Until then they show here so a send never looks lost.
    private(set) var pending: [PendingMessage] = []
    /// A row picked from search, for the transcript to scroll to and mark.
    var reveal: Reveal?
    /// A tap on the toolbar's jump to the top or the end, for the transcript to glide to.
    var jump: Jump?
    let search = TranscriptSearch()

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

    /// Put a page of older history in front of what is shown.
    func prepend(_ older: [TranscriptItem], hasMore: Bool) {
        self.hasMore = hasMore
        let fresh = older.filter { index[$0.id] == nil }
        for item in older where index[item.id] != nil { items[index[item.id]!] = item }
        guard !fresh.isEmpty else { return }
        items.insert(contentsOf: fresh, at: 0)
        rebuildIndex()
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

struct Reveal: Equatable {
    let itemId: String
    /// Picking the same row twice scrolls to it again.
    let token = UUID()
}

struct Jump: Equatable {
    let toEnd: Bool
    /// Every tap is its own request, so rapid taps each redirect the glide.
    let token = UUID()
}

struct PendingMessage: Identifiable {
    let id = UUID()
    let text: String
    /// Joins the running turn rather than waiting for it to end.
    let steer: Bool
}
