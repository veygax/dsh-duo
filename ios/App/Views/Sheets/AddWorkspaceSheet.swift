import SwiftUI

/// Browse folders on the paired Mac and register one as a Workspace.
struct AddWorkspaceSheet: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onAdded: ((Workspace) -> Void)?

    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var loading = false
    @State private var showHidden = false
    @State private var typedPath = ""
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Path on \(store.hostName)", text: $typedPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .submitLabel(.go)
                            .onSubmit { load(typedPath) }
                        Button("Go", systemImage: "arrow.right.circle.fill", action: tap { load(typedPath) })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(typedPath.isEmpty)
                    }
                }

                if let listing {
                    Section {
                        if let parent = listing.parent {
                            Button(action: tap { load(parent) }) {
                                Label("Up to \(URL(fileURLWithPath: parent).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: parent).lastPathComponent)",
                                      systemImage: "arrow.turn.left.up")
                            }
                        }
                        if let home = listing.home, home != listing.path {
                            Button("Home", systemImage: "house", action: tap { load(home) })
                        }
                        let entries = listing.entries.filter { showHidden || !$0.hidden }
                        if entries.isEmpty {
                            Text("No folders here").foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            Button(action: tap { load(entry.path) }) {
                                HStack {
                                    Label(entry.name, systemImage: entry.hidden ? "folder.badge.questionmark" : "folder")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Text(listing.path).textCase(nil).font(.caption.monospaced()).lineLimit(2).truncationMode(.head)
                    }
                } else if let error {
                    ContentUnavailableView("Can't Browse Folders", systemImage: "folder.badge.minus", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: tap { dismiss() })
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: add)
                        .accessibilityLabel("Add Workspace")
                        .disabled(listing == nil || adding)
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle("Show Hidden", systemImage: "eye", isOn: $showHidden)
                        .toggleStyle(.button)
                        .sensoryFeedback(.selection, trigger: showHidden)
                }
            }
            .overlay { if loading && listing != nil { ProgressView() } }
            .task { load(nil) }
        }
    }

    private func load(_ path: String?) {
        loading = true
        Task {
            defer { loading = false }
            do {
                let next = try await store.listDirectory(path?.isEmpty == true ? nil : path)
                withAnimation(.snappy) { listing = next }
                typedPath = next.path
                error = nil
            } catch {
                self.error = error.localizedDescription
                if listing != nil { store.show(error) }
            }
        }
    }

    private func add() {
        guard let path = listing?.path else { return }
        Haptics.press()
        adding = true
        Task {
            if let workspace = await store.addWorkspace(path: path) {
                onAdded?(workspace)
                dismiss()
            }
            adding = false
        }
    }
}
