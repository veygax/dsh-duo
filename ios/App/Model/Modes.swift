import SwiftUI

/// The four dsh agent presets the app presents as modes, plus any custom ones the Host declares.
nonisolated struct Mode: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var summary: String

    static let known: [String: Mode] = [
        "standard": Mode(id: "standard", name: "Regular", symbol: "bubble.left.and.text.bubble.right",
                         summary: "Full coding agent with shell, files and tools."),
        "ptc": Mode(id: "ptc", name: "PTC", symbol: "curlybraces.square",
                    summary: "Programmatic tool calling: the agent writes code that calls tools."),
        "minimal": Mode(id: "minimal", name: "Minimal", symbol: "circle.dashed",
                        summary: "A lean assistant with a tiny prompt and almost no tools."),
        "cordis": Mode(id: "cordis", name: "Creator", symbol: "wand.and.sparkles",
                       summary: "Builds and installs new dsh plugins, modes and pages with you."),
    ]

    static let order = ["standard", "ptc", "minimal", "cordis"]

    static func of(_ id: String?, presets: [Preset] = []) -> Mode {
        let id = id ?? presets.first(where: { $0.isDefault == true })?.id ?? "standard"
        if let mode = known[id] { return mode }
        let preset = presets.first { $0.id == id }
        return Mode(id: id, name: preset?.name ?? id.capitalized, symbol: "puzzlepiece.extension",
                    summary: preset?.description ?? "A custom mode installed on this dsh.")
    }

    /// Known modes first in their canonical order, then custom presets.
    static func all(_ presets: [Preset]) -> [Mode] {
        let ids = presets.isEmpty ? order : presets.map(\.id)
        return ids.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map { of($0, presets: presets) }
    }
}
