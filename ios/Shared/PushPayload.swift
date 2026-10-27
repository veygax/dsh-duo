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
    /// The reply a finished-turn notification opens to.
    var itemId: String?
    /// The tool a permission ask is for; its body is then the reason.
    var tool: String?
}

nonisolated enum NotificationIDs {
    static let turnCategory = "TURN"
    static let questionCategory = "QUESTION"
    static let approvalCategory = "APPROVAL"
    static let allowAction = "ALLOW"
    static let denyAction = "DENY"
    /// The choices the plugin offers on a permission ask.
    static let allowLabel = "Allow Once"
    static let denyLabel = "Deny"
    static let replyAction = "REPLY"
    static let openAction = "OPEN"
    static let sessionKey = "sessionId"
    static let callKey = "callId"
    static let questionKey = "questionId"
    static let itemKey = "itemId"
    static let kindKey = "kind"
}

extension PushPayload {
    /// Rewrite a notification's content from the decrypted payload.
    nonisolated func apply(to content: UNMutableNotificationContent) {
        let waiting = kind == "question" || kind == "approval"
        switch kind {
        case "approval":
            content.title = "Permission · \(title)"
            let ask = "Allow \(tool ?? "a tool") to run?"
            content.body = body.isEmpty ? ask : "\(ask)\n\(body)"
            content.categoryIdentifier = NotificationIDs.approvalCategory
        case "question":
            content.title = "Question · \(title)"
            content.body = body
            if let options, !options.isEmpty, multi != true {
                content.subtitle = options.joined(separator: " · ")
            }
            content.categoryIdentifier = NotificationIDs.questionCategory
        default:
            content.title = title
            content.body = body
            content.categoryIdentifier = NotificationIDs.turnCategory
        }
        content.threadIdentifier = sessionId
        content.interruptionLevel = waiting ? .timeSensitive : .active
        content.relevanceScore = waiting ? 1 : 0.5
        var info: [String: Any] = [NotificationIDs.sessionKey: sessionId, NotificationIDs.kindKey: kind]
        if let callId { info[NotificationIDs.callKey] = callId }
        if let questionId { info[NotificationIDs.questionKey] = questionId }
        if let itemId { info[NotificationIDs.itemKey] = itemId }
        content.userInfo = info
    }
}
