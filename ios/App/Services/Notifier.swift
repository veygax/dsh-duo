import UIKit
import UserNotifications

/// Local and remote notification handling: categories with inline replies,
/// foreground presentation, and routing taps back to the right Session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var store: HostStore?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: NotificationIDs.replyAction, title: "Reply",
            options: [], icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: "Send", textInputPlaceholder: "Message DeepSeek")
        let answer = UNTextInputNotificationAction(
            identifier: NotificationIDs.replyAction, title: "Answer",
            options: [], icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
            textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let open = UNNotificationAction(identifier: NotificationIDs.openAction, title: "Open",
                                        options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationIDs.turnCategory, actions: [reply, open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "A turn finished", options: []),
            UNNotificationCategory(identifier: NotificationIDs.questionCategory, actions: [answer, open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "DeepSeek has a question", options: []),
        ])
    }

    func requestAuthorization() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Notify about a Session the user is not looking at while the app is open.
    func local(title: String, body: String, sessionId: String, kind: String, callId: String? = nil, questionId: String? = nil) {
        let content = UNMutableNotificationContent()
        PushPayload(kind: kind, sessionId: sessionId, title: title, body: body, callId: callId, questionId: questionId)
            .apply(to: content)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(kind)-\(callId ?? sessionId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let sessionId = notification.request.content.userInfo[NotificationIDs.sessionKey] as? String
        let visible = await MainActor.run { store?.isActive == true && store?.selectedSessionId == sessionId }
        return visible ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let sessionId = info[NotificationIDs.sessionKey] as? String else { return }
        let kind = info[NotificationIDs.kindKey] as? String
        if response.actionIdentifier == NotificationIDs.replyAction,
           let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, let pairing = PairingStore.load() {
            if kind == "question", let callId = info[NotificationIDs.callKey] as? String,
               let questionId = info[NotificationIDs.questionKey] as? String {
                try? await RelayClient.post(pairing, op: "question.answer", params: [
                    "sessionId": sessionId, "callId": callId,
                    "answers": [["id": questionId, "selected": [], "custom": text]],
                ])
            } else {
                try? await RelayClient.post(pairing, op: "session.prompt", params: [
                    "sessionId": sessionId, "text": text, "mode": "queue", "timeZone": TimeZone.current.identifier,
                ])
            }
            return
        }
        await MainActor.run {
            store?.selectedSessionId = sessionId
        }
    }
}

/// Bridges APNs registration callbacks into SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifier.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Notifier.shared.store?.setPushToken(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator and unsigned builds land here; local notifications still work.
    }
}
