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
    @FocusState private var searchFocused: Bool
    /// A linked file on the Mac, once fetched, and the name of one still on its way.
    @State private var previewed: URL?
    @State private var fetching: String?
    /// A linked folder, to pick a file from.
    @State private var picking: HostFolder?

    var body: some View {
        let session = store.sessions[sessionId]
        Group {
            if let model {
                ConversationView(model: model, sessionId: sessionId)
                    // Over the composer too: while results are up there is nothing to send.
                    .overlay {
                        if typing {
                            SearchResultsView(model: model, query: query) { hit in
                                Haptics.selection()
                                closeSearch()
                                model.reveal = Reveal(itemId: hit.itemId)
                            }
                            .background(.background)
                        }
                    }
                    // Centred at the top while empty, clear of the composer; once there is a query the
                    // results cover the composer, and the field slides straight down over the keyboard.
                    .overlay {
                        if searching {
                            SearchBar(query: $query, focused: $searchFocused, close: closeSearch)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxHeight: .infinity, alignment: typing ? .bottom : .top)
                                .transition(.move(edge: .top).combined(with: .opacity))
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
        .sheet(item: $picking) { folder in
            FolderPicker(folder: folder, sessionId: sessionId) { path in
                picking = nil
                preview(path)
            }
        }
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
        .animation(.smooth, value: typing)
        .animation(.smooth, value: searching)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let session, session.isSubagent {
                SubagentBar(
                    session: session,
                    parent: session.parentId.flatMap { store.sessions[$0] }
                ) {
                    guard let parentId = session.parentId else { return }
                    Haptics.selection()
                    store.selectedSessionId = parentId
                }
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

    private func openSearch() {
        searching = true
    }

    private func closeSearch() {
        searchFocused = false
        searching = false
        query = ""
    }

    private func preview(_ path: String) {
        guard fetching == nil else { return }
        Haptics.tap()
        fetching = (path as NSString).lastPathComponent
        Task {
            let download = await store.download(path, in: sessionId)
            fetching = nil
            switch download {
            case .file(let url): previewed = url
            case .folder(let folder): picking = folder
            case nil: break
            }
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
        // A trailing menu rather than the system overflow menu, which the toolbar always puts last:
        // this way search sits under it.
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                if let session {
                    Button("Rename", systemImage: "pencil", action: tap { renaming = session })
                    if let cwd = session.cwd {
                        Button("Copy Folder Path", systemImage: "doc.on.doc", action: tap { UIPasteboard.general.string = cwd })
                    }
                }
                Button("Copy Session ID", systemImage: "number", action: tap { UIPasteboard.general.string = sessionId })
                Button("Reload", systemImage: "arrow.clockwise", action: tap {
                    if let model { Task { await store.open(model) } }
                })
            }
            // Plain like the system overflow menu, not tinted like an action.
            .tint(.primary)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Search", systemImage: "magnifyingglass", action: tap {
                searching ? closeSearch() : openSearch()
            })
            .keyboardShortcut("f", modifiers: .command)
            .tint(.primary)
        }

        // One glass group under search: top and end belong together.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Jump to Top", systemImage: "chevron.up", action: tap { model?.jump = Jump(toEnd: false) })
                .keyboardShortcut(.upArrow, modifiers: .command)
                .tint(.primary)
            Button("Jump to End", systemImage: "chevron.down", action: tap { model?.jump = Jump(toEnd: true) })
                .keyboardShortcut(.downArrow, modifiers: .command)
                .tint(.primary)
        }
    }

    private var typing: Bool { searching && !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The thin lineage bar above a subagent conversation, with a way back to its parent.
private struct SubagentBar: View {
    let session: SessionInfo
    let parent: SessionInfo?
    let openParent: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.secondary)
            Text("Subagent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let detail = parent?.title ?? session.subagent?.label, !detail.isEmpty {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if parent != nil {
                Button("Open Parent", systemImage: "arrow.up.left", action: openParent)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Shows the session that started this subagent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subagent conversation with \(parent?.title ?? session.subagent?.label ?? "its parent")")
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
