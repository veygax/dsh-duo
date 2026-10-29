import SwiftUI

/// Sessions on the paired Host, grouped by Workspace.
struct SidebarView: View {
    @Environment(HostStore.self) private var store
    @State private var query = ""
    @State private var newSessionWorkspace: NewSessionRequest?
    @State private var addingWorkspace = false
    @State private var showingSettings = false
    @State private var renaming: SessionInfo?
    /// Subagent groups start open; a user can tuck one away without losing the parent row.
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedSessionId) {
            ConnectionRow()

            if store.loadedOnce && store.sessions.isEmpty && store.workspaces.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions Yet", systemImage: "sparkles")
                } description: {
                    Text("Add a project folder from \(store.hostName), then start a session in it.")
                } actions: {
                    Button("Add Workspace", systemImage: "folder.badge.plus", action: tap { addingWorkspace = true })
                        .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            }

            ForEach(store.sections(matching: query), id: \.workspace?.id) { section in
                Section {
                    ForEach(flatten(section.nodes)) { item in
                        SessionFlatRow(item: item) {
                            withAnimation(.snappy) {
                                if collapsed.contains(item.id) { collapsed.remove(item.id) }
                                else { collapsed.insert(item.id) }
                            }
                        } onRename: { session in
                            renaming = session
                        } onQuickStart: { session in
                            quickStart(in: session.workspaceId, cwd: session.cwd)
                        }
                    }
                    if section.nodes.isEmpty, let workspace = section.workspace {
                        Button(action: tap { quickStart(in: workspace.id) }) {
                            Label("Start a session", systemImage: "plus.bubble")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    WorkspaceHeader(workspace: section.workspace) {
                        quickStart(in: section.workspace?.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.snappy, value: store.sortedSessions.map(\.id))
        .searchable(text: $query, placement: .sidebar, prompt: "Search sessions")
        .refreshable { await store.refresh() }
        .navigationTitle(store.hostName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil", action: tap {
                    newSessionWorkspace = .init(workspaceId: selectedWorkspaceId)
                })
                .disabled(store.connection != .online)
                .keyboardShortcut("n", modifiers: .command)
            }
            .visibilityPriority(.high)

            ToolbarOverflowMenu {
                Button("Add Workspace", systemImage: "folder.badge.plus", action: tap { addingWorkspace = true })
                    .disabled(store.connection != .online)
                Button("Reconnect", systemImage: "arrow.clockwise", action: tap { store.reconnect() })
                Button("Connection & Pairing", systemImage: "iphone.gen3.radiowaves.left.and.right", action: tap { showingSettings = true })
            }
        }
        .sheet(item: $newSessionWorkspace) { request in
            NewSessionSheet(workspaceId: request.workspaceId)
        }
        .sheet(isPresented: $addingWorkspace) { AddWorkspaceSheet() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: $renaming) { session in RenameSheet(session: session) }
        .onChange(of: store.selectedSessionId) { _, id in revealAncestors(of: id) }
    }

    /// Start a session in this folder right away, in the last mode used; the full chooser
    /// stays behind the toolbar's New Session button.
    private func quickStart(in workspaceId: String?, cwd: String? = nil) {
        Task {
            let mode = UserDefaults.standard.string(forKey: "lastMode")
            if let id = await store.createSession(workspaceId: workspaceId, cwd: cwd, mode: mode) {
                store.selectedSessionId = id
            }
        }
    }

    /// A subagent inherits its parent's workspace; New Session from one opens there.
    private var selectedWorkspaceId: String? {
        guard let session = store.sessions[store.selectedSessionId ?? ""] else { return nil }
        return session.workspaceId ?? session.parentId.flatMap { store.sessions[$0]?.workspaceId }
    }

    /// Opening a subagent from a notification or a link should not land in a folded branch.
    private func revealAncestors(of sessionId: String?) {
        guard let sessionId, var session = store.sessions[sessionId] else { return }
        while let parentId = session.parentId {
            collapsed.remove(parentId)
            guard let parent = store.sessions[parentId] else { return }
            session = parent
        }
    }

    /// The visible rows of one workspace section, with subagent branches expanded or folded.
    private func flatten(_ nodes: [SessionNode], depth: Int = 0) -> [SessionRowItem] {
        nodes.flatMap { node in
            // A search should reveal the matching branch even if the user folded it earlier.
            let open = !collapsed.contains(node.id) || !query.isEmpty
            var rows = [SessionRowItem(node: node, depth: depth, expanded: open && !node.children.isEmpty)]
            if open {
                rows.append(contentsOf: flatten(node.children, depth: depth + 1))
            }
            return rows
        }
    }
}

struct NewSessionRequest: Identifiable {
    var workspaceId: String?
    var id: String { workspaceId ?? "-" }
}

private struct WorkspaceHeader: View {
    let workspace: Workspace?
    let onNew: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace == nil ? "tray" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace?.title ?? "Other Sessions")
                if let path = workspace?.path {
                    Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        .textCase(nil)
                }
            }
            Spacer()
            if workspace != nil {
                Button("New Session in \(workspace?.title ?? "")", systemImage: "plus", action: tap(onNew))
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.body.weight(.semibold))
            }
        }
    }
}

/// Connection state, shown only when something needs the user's attention.
private struct ConnectionRow: View {
    @Environment(HostStore.self) private var store

    var body: some View {
        switch store.connection {
        case .online, .unpaired:
            EmptyView()
        case .connecting:
            Label {
                Text("Connecting to \(store.hostName)…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case .hostOffline:
            Label {
                VStack(alignment: .leading) {
                    Text("\(store.hostName) is offline")
                    Text("Start dsh on your Mac; this reconnects by itself.").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.orange)
            }
        case .failed(let message):
            Label {
                VStack(alignment: .leading) {
                    Text("Can't reach \(store.hostName)")
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

struct SessionRow: View {
    @Environment(HostStore.self) private var store
    let session: SessionInfo
    var subagentCount = 0

    var body: some View {
        let mode = store.mode(of: session)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(session.running ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if session.isSubagent {
                        Label(session.subagent?.mode.title ?? "Subagent", systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                    } else {
                        Label(mode.name, systemImage: mode.symbol)
                            .labelStyle(.titleAndIcon)
                    }
                    Text("·")
                    Text(session.updated, format: .relative(presentation: .named))
                    if let goal = session.goal, goal.isVisible {
                        Image(systemName: "target")
                            .foregroundStyle(goal.phase == .blocked ? .orange : .secondary)
                            .accessibilityLabel(goal.phase == .blocked ? "Goal blocked" : "Has a goal")
                    }
                    if subagentCount > 0 {
                        Label("\(subagentCount)", systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                            .accessibilityLabel(subagentCount == 1 ? "1 subagent conversation" : "\(subagentCount) subagent conversations")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.questions > 0 {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Waiting for your answer")
            } else if session.running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
        .padding(.vertical, 2)
    }
}

/// One visible row in the sidebar tree, carrying its depth and whether its branch is open.
private struct SessionRowItem: Identifiable {
    let node: SessionNode
    let depth: Int
    let expanded: Bool
    var id: String { node.id }
}

/// A normal, selectable Session row with a disclosure control for its subagent branch.
/// Keeping the chevron a separate button means tapping the label opens the parent Session.
private struct SessionFlatRow: View {
    @Environment(HostStore.self) private var store
    let item: SessionRowItem
    let toggle: () -> Void
    let onRename: (SessionInfo) -> Void
    let onQuickStart: (SessionInfo) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.depth > 0 {
                Color.clear.frame(width: CGFloat(item.depth) * 16, height: 1)
            }
            if item.node.children.isEmpty {
                Color.clear.frame(width: 18, height: 1)
            } else {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(item.expanded ? 90 : 0))
                        .frame(width: 18, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.expanded ? "Hide subagents" : "Show subagents")
            }
            SessionRow(session: item.node.session, subagentCount: item.node.descendantCount)
        }
        .animation(.snappy, value: item.expanded)
        .contentShape(.rect)
        .tag(item.id)
        .contextMenu { contextMenu }
        .swipeActions(edge: .trailing) {
            Button("Rename", systemImage: "pencil") { onRename(item.node.session) }
                .tint(.indigo)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open", systemImage: "arrow.up.forward") { store.selectedSessionId = item.id }
        if item.node.session.isSubagent, let parentId = item.node.session.parentId, store.sessions[parentId] != nil {
            Button("Open Parent Session", systemImage: "arrow.up.left") { store.selectedSessionId = parentId }
        }
        Button("Rename", systemImage: "pencil") { onRename(item.node.session) }
        if !item.node.session.isSubagent {
            Button("New Session Here", systemImage: "plus.bubble") { onQuickStart(item.node.session) }
        }
        if let cwd = item.node.session.cwd {
            Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = cwd }
        }
        if let goal = item.node.session.goal, goal.isVisible {
            Button("Copy Goal", systemImage: "target") { UIPasteboard.general.string = goal.objective }
        }
        Button("Copy Session ID", systemImage: "number") { UIPasteboard.general.string = item.id }
    }
}

struct RenameSheet: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: SessionInfo
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel, action: tap { dismiss() }) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { title = session.title }
    }

    private func save() {
        Haptics.tap()
        Task { await store.rename(session.id, to: title) }
        dismiss()
    }
}
