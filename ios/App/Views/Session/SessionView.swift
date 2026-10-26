import SwiftUI

/// One Session. With the sidebar hidden on the open inner display, tapping a thought or
/// tool call opens it in a native inspector column on the right instead of expanding it inline.
struct SessionView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.sidebarHidden) private var inspecting
    let sessionId: String
    @State private var model: SessionModel?
    @State private var renaming: SessionInfo?
    /// What the inspector shows. Kept after it closes so its content stays put while it slides away.
    @State private var inspected: TranscriptItem?
    @State private var inspectorShown = false

    var body: some View {
        let session = store.sessions[sessionId]
        Group {
            if let model {
                ConversationView(model: model, sessionId: sessionId)
                    .environment(\.paneOpen, inspecting && inspectorShown)
                    .environment(\.inspector, inspecting
                        ? Inspector(selectedId: inspectorShown ? inspected?.id : nil, open: open)
                        : nil)
                    // The system column pushes the chat aside the way the sidebar does.
                    .inspector(isPresented: Binding(
                        get: { inspecting && inspectorShown },
                        set: { if !$0 { inspectorShown = false } })) {
                        Group {
                            if let item = inspected {
                                DetailPane(model: model, item: item) { close() }
                            }
                        }
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 480)
                    }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(session) }
        // Task-oriented screen: keep its actions over the tab bar when space is tight.
        .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        .onChange(of: inspecting) { _, inspecting in if !inspecting { inspectorShown = false } }
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
        if inspectorShown && inspected?.id == item.id { return close() }
        Haptics.selection()
        inspected = item
        if !inspectorShown { withAnimation { inspectorShown = true } }
    }

    private func close() {
        guard inspectorShown else { return }
        Haptics.tap()
        withAnimation { inspectorShown = false }
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
