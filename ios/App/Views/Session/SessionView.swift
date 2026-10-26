import QuickLook
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
    @State private var query = ""
    @State private var searching = false
    /// A linked file on the Mac, once fetched, and the name of one still on its way.
    @State private var previewed: URL?
    @State private var fetching: String?

    var body: some View {
        let session = store.sessions[sessionId]
        Group {
            if let model {
                ConversationView(model: model, sessionId: sessionId)
                    // Over the composer too: while results are up there is nothing to send.
                    .overlay {
                        if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            SearchResultsView(model: model, query: query) { hit in
                                Haptics.selection()
                                searching = false
                                model.reveal = Reveal(itemId: hit.itemId)
                            }
                            .background(.background)
                        }
                    }
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
        // Links to files on the Mac open in QuickLook; web links go to the system as usual.
        .environment(\.openURL, OpenURLAction { url in
            guard let path = HostFile.path(of: url) else { return .systemAction }
            preview(path)
            return .handled
        })
        .quickLookPreview($previewed)
        .overlay(alignment: .top) {
            if let fetching {
                Label {
                    Text("Opening \(fetching)…").lineLimit(1)
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: fetching)
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(session) }
        // A search button in the toolbar that expands into the field, as the system's own apps do.
        .searchable(text: $query, isPresented: $searching, placement: .toolbar, prompt: "Search Messages")
        .searchToolbarBehavior(.minimize)
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

    private func preview(_ path: String) {
        guard fetching == nil else { return }
        Haptics.tap()
        fetching = (path as NSString).lastPathComponent
        Task {
            let url = await store.download(path, in: sessionId)
            fetching = nil
            previewed = url
        }
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

/// Markdown links DeepSeek writes to files on the Mac: `[a.swift](src/a.swift)`, `[x](/Users/me/x.md:42)`,
/// `file:///…`. Anything with a web or app scheme is not one.
enum HostFile {
    static func path(of url: URL) -> String? {
        // `a.swift:42` parses as the scheme "a.swift"; a real scheme has no dot before a bare line number.
        if let scheme = url.scheme, scheme.contains("."),
           let line = url.absoluteString.wholeMatch(of: /([^\/:]+):\d+(:\d+)?/) {
            return String(line.1).removingPercentEncoding
        }
        guard url.scheme == nil || url.scheme == "file" else { return nil }
        var path = url.path(percentEncoded: false)
        if url.scheme == nil, url.host() == nil, path.isEmpty { path = url.absoluteString.removingPercentEncoding ?? "" }
        // Editors' line and column suffixes, `a.swift:42` or `a.swift:42:7`.
        path = path.replacing(/:\d+(:\d+)?$/, with: "")
        return path.isEmpty ? nil : path
    }
}
