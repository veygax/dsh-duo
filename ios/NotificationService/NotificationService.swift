import UserNotifications

/// Decrypts the sealed relay payload so notifications show real content while
/// the relay itself only ever sees ciphertext.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        if let sealed = request.content.userInfo["e"] as? String,
           let crypto = PairingStore.load()?.crypto,
           let data = crypto.open(sealed),
           let payload = try? JSONDecoder().decode(PushPayload.self, from: data) {
            payload.apply(to: content)
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
