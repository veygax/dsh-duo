import SwiftUI
import UniformTypeIdentifiers

/// A folder DeepSeek linked to: its files to pick one to preview, and its subfolders to step into.
struct FolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let folder: HostFolder
    let sessionId: String
    let pick: (String) -> Void

    var body: some View {
        NavigationStack {
            FolderList(folder: folder, pick: pick)
                .navigationDestination(for: HostFolder.Entry.self) { entry in
                    FolderLoader(entry: entry, sessionId: sessionId, pick: pick)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel, action: tap { dismiss() })
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One subfolder, read from the Mac when it is stepped into.
private struct FolderLoader: View {
    @Environment(HostStore.self) private var store
    let entry: HostFolder.Entry
    let sessionId: String
    let pick: (String) -> Void
    @State private var folder: HostFolder?
    @State private var failed = false

    var body: some View {
        Group {
            if let folder {
                FolderList(folder: folder, pick: pick)
            } else if failed {
                ContentUnavailableView("Can't Open Folder", systemImage: "folder.badge.minus")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.name)
        .task {
            if case .folder(let folder) = await store.download(entry.path, in: sessionId) {
                self.folder = folder
            } else {
                failed = true
            }
        }
    }
}

private struct FolderList: View {
    let folder: HostFolder
    let pick: (String) -> Void
    @State private var showHidden = false

    var body: some View {
        let entries = folder.entries.filter { showHidden || !$0.hidden }
        List {
            Section {
                ForEach(entries) { entry in
                    if entry.folder {
                        NavigationLink(value: entry) {
                            Label(entry.name, systemImage: "folder")
                        }
                    } else {
                        Button(action: tap { pick(entry.path) }) {
                            Label(entry.name, systemImage: Self.symbol(for: entry.name))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            } footer: {
                if folder.truncated == true { Text("Only the first \(folder.entries.count) items are shown.") }
            }
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("Empty Folder", systemImage: "folder") }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folder.entries.contains(where: \.hidden) {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Show Hidden", systemImage: "eye", isOn: $showHidden)
                        .toggleStyle(.button)
                        .sensoryFeedback(.selection, trigger: showHidden)
                }
            }
        }
    }

    static func symbol(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}
