import SwiftUI

/// One Session. In full screen on the inner display it becomes an arrangement of
/// the conversation and a live activity inspector; elsewhere it is the conversation.
struct SessionView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let sessionId: String
    @State private var model: SessionModel?
    @State private var renaming: SessionInfo?

    var body: some View {
        let session = store.sessions[sessionId]
        Group {
            if let model {
                if store.isFocused && sizeClass == .regular {
                    // Navigation stays outside; the arrangement only lays out content and
                    // keeps each side clear of the fold as the device bends.
                    ArrangementView {
                        ConversationView(model: model, sessionId: sessionId)
                    } secondary: {
                        InspectorView(model: model, sessionId: sessionId)
                    }
                    .arrangementViewStyle(.split.axes(.horizontal))
                } else {
                    ConversationView(model: model, sessionId: sessionId)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(session) }
        // Full screen is a reading mode: the conversation spans the whole display, as
        // the iPhone Duo guidelines suggest for content that doesn't need bars.
        .toolbarVisibility(store.isFocused ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(store.isFocused)
        .overlay(alignment: .topTrailing) {
            if store.isFocused {
                FoldAware {
                    HStack {
                        Spacer()
                        Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: { store.toggleFocus() })
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .transition(.opacity)
            }
        }
        // Task-oriented screen: keep its actions over the tab bar when space is tight.
        .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        .sheet(item: $renaming) { RenameSheet(session: $0) }
        .task(id: sessionId) {
            let model = store.model(for: sessionId)
            self.model = model
            if store.connection == .online { await store.open(model) }
        }
        .onChange(of: store.connection) { _, connection in
            if connection == .online, let model, model.loading { Task { await store.open(model) } }
        }
        .onDisappear { if let model { store.close(model) } }
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: SessionInfo?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session?.running == true {
                Button("Stop", systemImage: "stop.fill", action: tap {
                    Task { await store.cancel(sessionId) }
                })
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            }
            Button(store.isFocused ? "Exit Full Screen" : "Full Screen",
                   systemImage: store.isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   action: { store.toggleFocus() })
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .visibilityPriority(.high)

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
