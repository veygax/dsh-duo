import SwiftUI

@main
struct DSHDuoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = HostStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { url in
                    if !store.pair(link: url.absoluteString) {
                        store.banner = .init(title: "That link is not a DSH Duo pairing link", isError: true)
                    }
                }
                .onAppear {
                    Notifier.shared.store = store
                    Notifier.shared.requestAuthorization()
                }
                .onChange(of: phase) { _, phase in
                    // Stay connected through brief interruptions; hang up only in the background.
                    switch phase {
                    case .active: store.setActive(true)
                    case .background: store.setActive(false)
                    default: break
                    }
                }
        }
    }
}
