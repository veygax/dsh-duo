import SwiftUI
import UIKit

/// Haptic vocabulary used across the app; every button press goes through `tap()`.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func tap() { light.impactOccurred(intensity: 0.8) }
    static func press() { rigid.impactOccurred() }
    static func selection() { selectionGenerator.selectionChanged() }
    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error() { notification.notificationOccurred(.error) }
    /// A question needs the user: two firm taps.
    static func attention() {
        rigid.impactOccurred(intensity: 1)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            rigid.impactOccurred(intensity: 0.7)
        }
    }
}

/// Wrap a button action so it plays the tap haptic first.
@MainActor
func tap(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    { Haptics.tap(); action() }
}

/// Button style that adds a press haptic to any custom-styled button.
struct HapticPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}
