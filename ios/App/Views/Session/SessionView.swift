import SwiftUI

/// One Session. With the sidebar hidden on the open inner display, tapping a thought or
/// tool call opens it in a pane on the right instead of expanding it inline.
struct SessionView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.sidebarHidden) private var inspecting
    let sessionId: String
    @State private var model: SessionModel?
    @State private var renaming: SessionInfo?
    @State private var inspected: TranscriptItem?
    /// Room kept for the pane beside the chat. It changes in one step, never per frame,
    /// so the transcript reflows once instead of jiggling while the pane slides.
    @State private var reserved = false
    /// Width of the inner display's side status bar. The pane sits inside it, so it has to
    /// slide this much further than its own width to leave the screen.
    @State private var trailingInset: CGFloat = 0

    private static let paneWidth: CGFloat = 400
    private static let slide = Animation.smooth(duration: 0.28)

    var body: some View {
        let session = store.sessions[sessionId]
        Group {
            if let model {
                ZStack(alignment: .trailing) {
                    ConversationView(model: model, sessionId: sessionId)
                        .padding(.trailing, reserved ? Self.paneWidth : 0)
                        // Rows restyle for the selection in place; they don't animate their frames
                        // across the reflow when the pane opens.
                        .transaction(value: inspected?.id) { $0.animation = nil }
                    if let item = inspected {
                        DetailPane(model: model, item: item) { close() }
                            .frame(width: Self.paneWidth)
                            .overlay(alignment: .leading) { Divider() }
                            .transition(.offset(x: Self.paneWidth + trailingInset))
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.trailing) { trailingInset = $0 }
                .environment(\.inspector, inspecting ? Inspector(selectedId: inspected?.id, open: open) : nil)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(session) }
        // Task-oriented screen: keep its actions over the tab bar when space is tight.
        .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        .onChange(of: inspecting) { _, inspecting in
            if !inspecting {
                inspected = nil
                reserved = false
            }
        }
        .sheet(item: $renaming) { RenameSheet(session: $0) }
        .task(id: sessionId) {
            let model = store.model(for: sessionId)
            self.model = model
            store.attach(model)
            if store.connection == .online { await store.open(model) }
        }
        .onChange(of: store.connection) { _, connection in
            if connection == .online, let model, model.loading { Task { await store.open(model) } }
        }
        .onDisappear { if let model { store.detach(model) } }
    }

    private func open(_ item: TranscriptItem) {
        if inspected?.id == item.id { return close() }
        Haptics.selection()
        if inspected == nil {
            reserved = true
            withAnimation(Self.slide) { inspected = item }
        } else {
            inspected = item
        }
    }

    private func close() {
        guard inspected != nil else { return }
        Haptics.tap()
        withAnimation(Self.slide) {
            inspected = nil
        } completion: {
            // The chat widens only once the pane is gone, behind nothing.
            if inspected == nil { reserved = false }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: SessionInfo?) -> some ToolbarContent {
        // Stop affects the turn, the overflow menu the session: separate items, not one shared group.
        // Present the whole item only while a turn runs, rather than hiding the view inside it.
        if session?.running == true {
            ToolbarItem(placement: .primaryAction) {
                Button("Stop", systemImage: "stop.fill", action: tap {
                    Task { await store.cancel(sessionId) }
                })
                .keyboardShortcut(".", modifiers: .command)
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarOverflowMenu {
            if let session {
                Button("Rename", systemImage: "pencil", action: tap { renaming = session })
                if let cwd = session.cwd {
                    Button("Copy Folder Path", systemImage: "doc.on.doc", action: tap { UIPasteboard.general.string = cwd })
                }
            }
            Button("Reload", systemImage: "arrow.clockwise", action: tap {
                if let model { Task { await store.open(model) } }
            })
        }
    }
}
