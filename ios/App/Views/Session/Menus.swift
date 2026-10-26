import SwiftUI

/// Regular / PTC / Minimal / Creator. dsh fixes the mode at a Session's first
/// turn, so choosing a different one on a started Session offers a new Session.
struct ModeMenu: View {
    @Environment(HostStore.self) private var store
    let sessionId: String
    @State private var pending: Mode?

    var body: some View {
        let session = store.sessions[sessionId]
        let current = store.mode(of: session)
        Menu {
            Section {
                ForEach(store.modes) { mode in
                    Button {
                        Haptics.selection()
                        guard mode.id != current.id, let session else { return }
                        if session.blank {
                            Task { _ = await store.selectMode(mode, for: session) }
                        } else {
                            pending = mode
                        }
                    } label: {
                        Label {
                            Text(mode.name)
                            Text(mode.summary)
                        } icon: {
                            Image(systemName: mode.id == current.id ? "checkmark" : mode.symbol)
                        }
                    }
                }
            } header: {
                Text(session?.blank == false ? "Mode · a new mode starts a new session" : "Mode")
            }
        } label: {
            Label(current.name, systemImage: current.symbol)
                .font(.footnote.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .menuOrder(.fixed)
        .accessibilityLabel("Mode: \(current.name)")
        .confirmationDialog("Start a \(pending?.name ?? "") session?", isPresented: .init(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { mode in
            Button("New \(mode.name) Session") {
                Haptics.tap()
                if let session { Task { _ = await store.selectMode(mode, for: session) } }
            }
            Button("Cancel", role: .cancel) { Haptics.tap() }
        } message: { _ in
            Text("This conversation has already started, so its mode can't change. A new session in the same folder keeps this one intact.")
        }
    }
}

/// Model and thinking level for the Session's next turn.
struct ModelMenu: View {
    @Environment(HostStore.self) private var store
    let sessionId: String

    var body: some View {
        let session = store.sessions[sessionId]
        let current = session?.model ?? store.catalog.defaultModel
        let model = store.catalog.model(current)
        Menu {
            ForEach(store.catalog.groups) { group in
                Section(group.name) {
                    ForEach(group.models) { option in
                        Button {
                            Haptics.selection()
                            let effort = option.efforts.contains { $0.id == current?.effort } ? current?.effort : option.defaultEffort
                            Task { await store.selectModel(ModelRef(provider: group.id, model: option.id, effort: effort), for: sessionId) }
                        } label: {
                            Label {
                                Text(option.name)
                                if let description = option.description { Text(description) }
                            } icon: {
                                if option.id == current?.model && group.id == current?.provider { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            if let model, !model.efforts.isEmpty, let current {
                Section("Thinking") {
                    Picker("Thinking", selection: Binding(
                        get: { current.effort ?? model.defaultEffort ?? "" },
                        set: { effort in
                            Haptics.selection()
                            var next = current
                            next.effort = effort
                            Task { await store.selectModel(next, for: sessionId) }
                        }
                    )) {
                        ForEach(model.efforts) { effort in
                            Label(effort.name, systemImage: Self.symbol(for: effort.id)).tag(effort.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            if store.catalog.groups.isEmpty {
                Button("Load Models", systemImage: "arrow.clockwise") {
                    Haptics.tap()
                    Task { await store.loadCatalog() }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(store.catalog.shortName(current))
                if let effort = store.catalog.effortName(current) {
                    Text("· \(effort)").foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.medium))
            .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .menuOrder(.fixed)
        .onAppear { if store.catalog.groups.isEmpty { Task { await store.loadCatalog() } } }
        .accessibilityLabel("Model: \(store.catalog.displayName(current)), thinking \(store.catalog.effortName(current) ?? "default")")
    }

    static func symbol(for effort: String) -> String {
        switch effort.lowercased() {
        case "none", "off", "minimal": "gauge.with.dots.needle.0percent"
        case "low": "gauge.with.dots.needle.33percent"
        case "medium": "gauge.with.dots.needle.50percent"
        case "high": "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}
