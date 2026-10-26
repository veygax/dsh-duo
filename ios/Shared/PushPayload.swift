import Foundation
import UserNotifications

/// Decrypted body of a relay push (docs/PROTOCOL.md §4, "Push payload").
nonisolated struct PushPayload: Codable, Sendable {
    var kind: String
    var sessionId: String
    var title: String
    var body: String
    var callId: String?
    var questionId: String?
    var options: [String]?
    var multi: Bool?
}

nonisolated enum NotificationIDs {
    static let turnCategory = "TURN"
    static let questionCategory = "QUESTION"
    static let replyAction = "REPLY"
    static let openAction = "OPEN"
    static let sessionKey = "sessionId"
    static let callKey = "callId"
    static let questionKey = "questionId"
    static let kindKey = "kind"
}

extension PushPayload {
    /// Rewrite a notification's content from the decrypted payload.
    nonisolated func apply(to content: UNMutableNotificationContent) {
        content.title = kind == "question" ? "Question · \(title)" : title
        content.body = body
        if kind == "question", let options, !options.isEmpty, multi != true {
            content.subtitle = options.joined(separator: " · ")
        }
        content.threadIdentifier = sessionId
        content.categoryIdentifier = kind == "question" ? NotificationIDs.questionCategory : NotificationIDs.turnCategory
        content.interruptionLevel = kind == "question" ? .timeSensitive : .active
        content.relevanceScore = kind == "question" ? 1 : 0.5
        var info: [String: Any] = [NotificationIDs.sessionKey: sessionId, NotificationIDs.kindKey: kind]
        if let callId { info[NotificationIDs.callKey] = callId }
        if let questionId { info[NotificationIDs.questionKey] = questionId }
        content.userInfo = info
    }
}
