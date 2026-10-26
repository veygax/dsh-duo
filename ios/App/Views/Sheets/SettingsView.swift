import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmUnpair = false
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent("Name", value: store.hostName)
                    LabeledContent("Status") { StatusLabel(connection: store.connection) }
                    if let version = store.hostVersion {
                        LabeledContent("Companion plugin", value: version)
                    }
                    if let relay = store.pairing?.relay.host() {
                        LabeledContent("Relay", value: relay)
                    }
                    Button("Reconnect", systemImage: "arrow.clockwise", action: tap { store.reconnect() })
                }

                Section {
                    LabeledContent("Notifications", value: notificationText)
                    if let enabled = store.pushEnabledOnHost {
                        LabeledContent("When the app is closed", value: enabled ? "Sent by \(store.hostName)" : "Not set up")
                    }
                    if notifications == .denied {
                        Button("Open Settings", systemImage: "gear", action: tap {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        })
                    } else if notifications == .notDetermined {
                        Button("Allow Notifications", systemImage: "bell.badge", action: tap {
                            Notifier.shared.requestAuthorization()
                        })
                    }
                } footer: {
                    Text(store.pushEnabledOnHost == false
                         ? "While the app is open you're notified about other sessions. To also get notifications when it's closed, install this app with ios/scripts/install.sh and an APNs key from your team."
                         : "You're notified when a turn finishes or DeepSeek asks a question, and can reply right from the notification.")
                }

                Section {
                    Label("Messages are end-to-end encrypted between this iPhone and your Mac. The relay only forwards ciphertext.",
                          systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Unpair This iPhone", systemImage: "link.badge.minus", role: .destructive, action: tap { confirmUnpair = true })
                        // Anchored to the button so the action sheet originates from it.
                        .confirmationDialog("Unpair from \(store.hostName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                            Button("Unpair", role: .destructive) {
                                Haptics.warning()
                                dismiss()
                                store.unpair()
                            }
                        } message: {
                            Text("You'll need to scan the pairing QR code again to reconnect.")
                        }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close, action: tap { dismiss() })
                }
            }
            .task {
                notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            }
        }
    }

    private var notificationText: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set up"
        }
    }
}

struct StatusLabel: View {
    let connection: HostStore.Connection

    var body: some View {
        switch connection {
        case .online: Label("Connected", systemImage: "circle.fill").foregroundStyle(.green)
        case .connecting: Label("Connecting", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .hostOffline: Label("Mac offline", systemImage: "moon.zzz.fill").foregroundStyle(.orange)
        case .failed: Label("Unreachable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unpaired: Label("Not paired", systemImage: "circle").foregroundStyle(.secondary)
        }
    }
}
