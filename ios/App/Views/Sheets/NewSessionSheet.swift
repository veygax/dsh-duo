import SwiftUI

/// Pick a folder and a mode, then start talking.
struct NewSessionSheet: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceId: String?
    @State private var modeId: String
    @State private var creating = false
    @State private var addingWorkspace = false

    init(workspaceId: String? = nil) {
        _workspaceId = State(initialValue: workspaceId)
        _modeId = State(initialValue: UserDefaults.standard.string(forKey: "lastMode") ?? "standard")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder") {
                    if store.workspaces.isEmpty {
                        Text("No workspaces yet. Add a project folder from \(store.hostName).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.workspaces) { workspace in
                        Button {
                            Haptics.selection()
                            workspaceId = workspace.id
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(workspace.title).foregroundStyle(.primary)
                                        Text(workspace.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                } icon: {
                                    Image(systemName: "folder")
                                }
                                Spacer()
                                if workspaceId == workspace.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                        }
                        .accessibilityAddTraits(workspaceId == workspace.id ? .isSelected : [])
                    }
                    Button("Add Workspace…", systemImage: "folder.badge.plus", action: tap { addingWorkspace = true })
                }

                Section {
                    // Two columns divide evenly across the fold on iPhone Duo.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(store.modes) { mode in
                            ModeCard(mode: mode, selected: mode.id == modeId) {
                                Haptics.selection()
                                modeId = mode.id
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Mode")
                } footer: {
                    Text("The mode is set for the whole session.")
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: tap { dismiss() })
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: create)
                        .accessibilityLabel("Start Session")
                        .disabled(creating || (workspaceId == nil && !store.workspaces.isEmpty))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .overlay { if creating { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $addingWorkspace) {
                AddWorkspaceSheet { workspace in workspaceId = workspace.id }
            }
            .onAppear {
                if workspaceId == nil { workspaceId = store.workspaces.first?.id }
                if !store.modes.contains(where: { $0.id == modeId }) { modeId = store.modes.first?.id ?? "standard" }
            }
        }
        .presentationDetents([.large])
    }

    private func create() {
        Haptics.press()
        creating = true
        UserDefaults.standard.set(modeId, forKey: "lastMode")
        Task {
            let id = await store.createSession(workspaceId: workspaceId, mode: modeId)
            creating = false
            if let id {
                store.selectedSessionId = id
                dismiss()
            }
        }
    }
}

private struct ModeCard: View {
    let mode: Mode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                Text(mode.name).font(.headline)
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary),
                        in: .rect(corners: .concentric(minimum: 16), isUniform: true))
        }
        .buttonStyle(HapticPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(mode.summary)
    }
}
