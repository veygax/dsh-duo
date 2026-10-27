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

/// What DeepSeek may do without asking. Open, a labelled chip beside Mode and Model; folded there is no
/// room, so the same menu sits behind its shield. Widening access asks first, as the desktop does.
struct PermissionMenu: View {
    @Environment(HostStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let sessionId: String
    @State private var confirming: PermissionPreset?

    var body: some View {
        if let id = store.sessions[sessionId]?.permission {
            let current = store.permissionPresets.first { $0.id == id } ?? PermissionPreset(id: id, name: id)
            let tint: Color = id == PermissionPreset.fullAccess ? .orange : id == PermissionPreset.auto ? .purple : .accentColor
            Group {
                if sizeClass == .compact {
                    menu(current)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                } else {
                    menu(current)
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
            .tint(tint)
            .menuStyle(.button)
            .menuOrder(.fixed)
            .accessibilityLabel("Permission: \(current.title)")
            .onAppear { if store.permissionPresets.isEmpty { Task { await store.loadPermissions() } } }
            .confirmationDialog(confirming.map(confirmTitle) ?? "", isPresented: .init(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }
            ), titleVisibility: .visible, presenting: confirming) { preset in
                Button(preset.id == PermissionPreset.auto ? "Turn On Auto Review" : "Allow Full Access") {
                    Haptics.press()
                    Task { await store.setPermission(preset, for: sessionId) }
                }
                Button("Cancel", role: .cancel) { Haptics.tap() }
            } message: { preset in
                Text(confirmMessage(preset))
            }
        }
    }

    private func menu(_ current: PermissionPreset) -> some View {
        Menu {
            Section("Permission") {
                ForEach(store.permissionPresets) { preset in
                    Button {
                        Haptics.selection()
                        guard preset.id != current.id else { return }
                        if preset.widens {
                            confirming = preset
                        } else {
                            Task { await store.setPermission(preset, for: sessionId) }
                        }
                    } label: {
                        Label(preset.title, systemImage: preset.id == current.id ? "checkmark" : preset.symbol)
                    }
                }
            }
            if store.permissionPresets.isEmpty {
                Button("Load Permissions", systemImage: "arrow.clockwise") {
                    Haptics.tap()
                    Task { await store.loadPermissions() }
                }
            }
        } label: {
            Label(current.title, systemImage: current.symbol)
                .lineLimit(1)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func confirmTitle(_ preset: PermissionPreset) -> String {
        preset.id == PermissionPreset.auto ? "Turn on Auto Review?" : "Give DeepSeek full access?"
    }

    private func confirmMessage(_ preset: PermissionPreset) -> String {
        if preset.id == PermissionPreset.auto {
            return "DeepSeek runs outside the sandbox, and the model reviews every step before it runs. You're asked about the steps it turns down. Experimental, and it uses extra tokens."
        }
        return "DeepSeek can change any file and run commands on \(store.hostName) without asking first, including sensitive ones. Use it only for work you trust."
    }
}

/// Model for the Session's next turn; its thinking level is set beside Send.
struct ModelMenu: View {
    @Environment(HostStore.self) private var store
    let sessionId: String

    var body: some View {
        let session = store.sessions[sessionId]
        let current = session?.model ?? store.catalog.defaultModel
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
        .accessibilityLabel("Model: \(store.catalog.displayName(current))")
    }
}

/// How hard the model thinks on the Session's next turn, beside Send. Open, a slider whose stops are
/// the model's levels; folded there is no room for one, so the same levels are a menu behind a gauge.
struct ThinkingControl: View {
    @Environment(HostStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let sessionId: String
    /// The stop under the thumb while dragging, and after release until dsh confirms the choice.
    @State private var dragged: Double?
    @State private var editing = false

    var body: some View {
        let current = store.sessions[sessionId]?.model ?? store.catalog.defaultModel
        if let current, let model = store.catalog.model(current), model.efforts.count > 1 {
            let efforts = model.efforts
            let selected = efforts.firstIndex { $0.id == (current.effort ?? model.defaultEffort) } ?? 0
            let shown = min(efforts.count - 1, max(0, dragged.map { Int($0.rounded()) } ?? selected))
            Group {
                if sizeClass == .compact {
                    menu(efforts, shown: shown, current: current)
                } else {
                    slider(efforts, shown: shown, selected: selected, current: current)
                }
            }
            .accessibilityLabel("Thinking")
            .accessibilityValue(efforts[shown].name)
        }
    }

    private func menu(_ efforts: [ReasoningEffort], shown: Int, current: ModelRef) -> some View {
        Menu {
            Picker("Thinking", selection: Binding(
                get: { efforts[shown].id },
                set: { id in if let index = efforts.firstIndex(where: { $0.id == id }) { choose(index, of: efforts, current: current) } }
            )) {
                ForEach(efforts) { effort in
                    Label(effort.name, systemImage: Self.symbol(for: effort.id)).tag(effort.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Thinking: \(efforts[shown].name)", systemImage: Self.symbol(for: efforts[shown].id))
                .contentTransition(.symbolEffect(.replace))
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuOrder(.fixed)
        .menuIndicator(.hidden)
    }

    private func slider(_ efforts: [ReasoningEffort], shown: Int, selected: Int, current: ModelRef) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(for: efforts[shown].id))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.secondary)
                // While held, the level's name sits over the gauge, in line with the dots: away from the
                // finger and the thumb's glass, which grows while it is held.
                .overlay {
                    if editing {
                        Text(efforts[shown].name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .id(shown)
                            .transition(.blurReplace)
                            .offset(y: -Self.stopRise)
                    }
                }
                .animation(.snappy(duration: 0.2), value: editing ? shown : -1)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { dragged ?? Double(selected) },
                    set: { value in
                        if Int(value.rounded()) != shown { Haptics.selection() }
                        dragged = value
                    }),
                // Continuous, so the thumb follows the finger and the system draws no ticks of its own
                // under ours; it settles on the nearest level when let go.
                in: 0...Double(efforts.count - 1)
            ) {
                Text("Thinking")
            } onEditingChanged: { editing in
                self.editing = editing
                if !editing {
                    withAnimation(.snappy) { dragged = Double(shown) }
                    choose(shown, of: efforts, current: current)
                }
            }
            .overlay { stops(efforts) }
        }
        .frame(minWidth: 96, maxWidth: 150)
    }

    /// A dot above the track for each level, where a finger on the thumb doesn't cover it.
    private func stops(_ efforts: [ReasoningEffort]) -> some View {
        GeometryReader { geometry in
            let inset = Self.stopInset
            let span = geometry.size.width - inset * 2
            ForEach(efforts.indices, id: \.self) { index in
                Circle()
                    .fill(.tertiary)
                    .frame(width: 4, height: 4)
                    .position(x: inset + span * CGFloat(index) / CGFloat(max(1, efforts.count - 1)),
                              y: geometry.size.height / 2 - Self.stopRise)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the system slider's first and last stops sit inside its frame (matched to the tick marks it
    /// draws for a stepped slider), and how far above the track's centre the dots and name go.
    private static let stopInset: CGFloat = 18
    private static let stopRise: CGFloat = 19

    private func choose(_ index: Int, of efforts: [ReasoningEffort], current: ModelRef) {
        let effort = efforts[index].id
        guard effort != current.effort else { dragged = nil; return }
        if sizeClass == .compact { Haptics.selection() }
        dragged = Double(index)
        var next = current
        next.effort = effort
        Task {
            await store.selectModel(next, for: sessionId)
            dragged = nil
        }
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
