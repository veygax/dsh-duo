import SwiftUI

/// Sessions on the paired Host, grouped by Workspace.
struct SidebarView: View {
    @Environment(HostStore.self) private var store
    @State private var query = ""
    @State private var newSessionWorkspace: NewSessionRequest?
    @State private var addingWorkspace = false
    @State private var showingSettings = false
    @State private var renaming: SessionInfo?

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
                    ForEach(section.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu { rowMenu(session) }
                            .swipeActions(edge: .trailing) {
                                Button("Rename", systemImage: "pencil", action: tap { renaming = session })
                                    .tint(.indigo)
                            }
                    }
                    if section.sessions.isEmpty, let workspace = section.workspace {
                        Button(action: tap { newSessionWorkspace = .init(workspaceId: workspace.id) }) {
                            Label("Start a session", systemImage: "plus.bubble")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    WorkspaceHeader(workspace: section.workspace) {
                        newSessionWorkspace = .init(workspaceId: section.workspace?.id)
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
                    newSessionWorkspace = .init(workspaceId: store.sessions[store.selectedSessionId ?? ""]?.workspaceId)
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
    }

    @ViewBuilder
    private func rowMenu(_ session: SessionInfo) -> some View {
        Button("Open", systemImage: "arrow.up.forward", action: tap { store.selectedSessionId = session.id })
        Button("Rename", systemImage: "pencil", action: tap { renaming = session })
        Button("New Session Here", systemImage: "plus.bubble", action: tap {
            newSessionWorkspace = .init(workspaceId: session.workspaceId)
        })
        if let cwd = session.cwd {
            Button("Copy Folder Path", systemImage: "doc.on.doc", action: tap { UIPasteboard.general.string = cwd })
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

    var body: some View {
        let mode = store.mode(of: session)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(session.running ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Label(mode.name, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
                    Text("·")
                    Text(session.updated, format: .relative(presentation: .named))
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
