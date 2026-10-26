import Intents
import UIKit
import UserNotifications

/// Shows a notification as a message from DeepSeek in a conversation named after its Session, the
/// way Messages does: DeepSeek's avatar, the Session as the conversation, and Reply on a long press.
nonisolated enum MessageNotification {
    static func present(_ payload: PushPayload, in content: UNMutableNotificationContent) async -> UNNotificationContent {
        let avatar = INImage(imageData: avatarData)
        let deepseek = INPerson(personHandle: INPersonHandle(value: "deepseek", type: .unknown), nameComponents: nil,
                                displayName: "DeepSeek", image: avatar, contactIdentifier: nil, customIdentifier: "deepseek")
        let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil,
                          displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: "me", isMe: true)
        // Two people and a group name make it a named conversation, so the Session's title stays the heading.
        let intent = INSendMessageIntent(recipients: [me, deepseek], outgoingMessageType: .outgoingMessageText,
                                         content: content.body, speakableGroupName: INSpeakableString(spokenPhrase: payload.title),
                                         conversationIdentifier: payload.sessionId, serviceName: nil, sender: deepseek, attachments: nil)
        intent.setImage(avatar, forParameterNamed: \.speakableGroupName)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: intent)) ?? content
    }

    /// The icon's sparkle on the accent colour, drawn once.
    private static let avatarData: Data = {
        let size = CGSize(width: 120, height: 120)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor(red: 0.30, green: 0.42, blue: 0.99, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }()
}

/// The app icon's count: notifications still in Notification Center, which go as their Session is read.
nonisolated enum Badge {
    /// The count once a notification with `identifier` is shown; it replaces any older one of that identifier.
    static func adding(_ identifier: String) async -> NSNumber {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return NSNumber(value: delivered.filter { $0.request.identifier != identifier }.count + 1)
    }

    /// Clear a Session's notifications, read in the app, and count what is left.
    static func read(_ sessionId: String?) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let read = delivered.filter { $0.request.content.threadIdentifier == sessionId }
        center.removeDeliveredNotifications(withIdentifiers: read.map(\.request.identifier))
        try? await center.setBadgeCount(delivered.count - read.count)
    }
}
