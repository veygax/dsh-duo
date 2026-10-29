import Foundation

nonisolated struct ModelRef: Codable, Hashable, Sendable {
    var provider: String
    var model: String
    var effort: String?
}

nonisolated struct SessionInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var updatedAt: Double
    var running: Bool
    var blank: Bool
    var cwd: String?
    var workspaceId: String?
    var preset: String?
    var model: ModelRef?
    /// The permission preset in effect, when the Mac has presets.
    var permission: String?
    var questions: Int
    var parentId: String?
    /// Present on conversations delegated to a subagent.
    var subagent: SubagentInfo?
    /// The durable completion objective, while one is set.
    var goal: Goal?

    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    var isSubagent: Bool { subagent != nil }

    /// Last path component of the working directory, for compact rows.
    var folderName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// One subagent conversation's role: continuable children accept follow-up messages.
nonisolated struct SubagentInfo: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        case oneShot = "one-shot"
        case continuable
        case external
        case unknown

        /// One-shot and external children have finished their task; only continuable ones take messages.
        var acceptsMessages: Bool { self == .continuable }

        var title: String {
            switch self {
            case .oneShot: "One-shot subagent"
            case .continuable: "Continuable subagent"
            case .external: "External subagent"
            case .unknown: "Subagent"
            }
        }
    }

    var mode: Mode
    var label: String?
}

/// A session's durable completion objective and its process-local activation.
nonisolated struct Goal: Codable, Hashable, Sendable, Identifiable {
    enum Phase: String, Codable, Sendable {
        case active, paused, blocked, complete

        /// A completed goal stays in the Session log but no longer needs a strip above the composer.
        var isVisible: Bool { self != .complete }
    }

    enum Activation: String, Codable, Sendable {
        case armed, disarmed
    }

    struct Blocker: Codable, Hashable, Sendable {
        var code: String
        var message: String
    }

    var id: String
    var revision: Int
    var objective: String
    var phase: Phase
    var blockedReason: Blocker?
    var roundsStarted: Int
    var maxGoalRounds: Int
    var activation: Activation?

    /// An active goal after a reconnect is durable but disarmed; show it as inactive.
    var isDisarmed: Bool { phase == .active && activation == .disarmed }
    var isVisible: Bool { phase.isVisible }
}

/// How much DeepSeek may do on its own: a sandbox and an approval policy, switched together.
nonisolated struct PermissionPreset: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?

    static let fullAccess = "danger-full-access"
    static let auto = "auto"

    var title: String {
        switch id {
        case "workspace-write": "Workspace Write"
        case Self.fullAccess: "Full Access"
        case Self.auto: "Auto Review"
        case "custom": "Custom"
        default: name.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
    }

    var symbol: String {
        switch id {
        case "workspace-write": "lock.shield"
        case Self.fullAccess: "exclamationmark.shield"
        case Self.auto: "checkmark.shield"
        case "custom": "slider.horizontal.3"
        default: "shield"
        }
    }

    /// Wider than the workspace: asked for with a confirmation, and marked in color while on.
    var widens: Bool { id == Self.fullAccess || id == Self.auto }
}

nonisolated struct Workspace: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var path: String
    var sessionIds: [String]
}

nonisolated struct Preset: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var isDefault: Bool?
}

/// One transcript row (docs/PROTOCOL.md `Item`).
nonisolated struct TranscriptItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, thinking, text, tool, notice, turn
        case unknown

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var id: String
    var kind: Kind
    var time: Double
    var text: String?
    var turn: Int?
    /// Images and files the row carries, in the order they were attached.
    var attachments: [TranscriptAttachment]?
    var callId: String?
    var name: String?
    var args: String?
    var status: String?
    var result: String?
    var level: String?
    var reason: String?

    var isRunningTool: Bool { kind == .tool && status == "running" }
    var isFailedTool: Bool { kind == .tool && status == "error" }
}

nonisolated struct LiveTool: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var args: String
}

/// The assistant output currently streaming, before it commits to the transcript.
nonisolated struct LiveAttempt: Codable, Hashable, Sendable {
    var attemptId: String
    var thinking: String
    var text: String
    var tools: [LiveTool]
}

nonisolated struct QuestionOption: Codable, Hashable, Sendable {
    var label: String
    var description: String?
}

nonisolated struct Question: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var question: String
    var header: String?
    var detail: String?
    var options: [QuestionOption]
    var multiSelect: Bool
    var intent: String?
}

nonisolated struct PendingQuestion: Hashable, Sendable, Identifiable {
    var callId: String
    var sessionId: String
    var title: String
    var questions: [Question]
    var id: String { callId }
}

nonisolated struct QuestionAnswer: Hashable, Sendable {
    var id: String
    var selected: [String]
    var custom: String?

    var json: [String: Any] {
        var value: [String: Any] = ["id": id, "selected": selected]
        if let custom, !custom.isEmpty { value["custom"] = custom }
        return value
    }
}

nonisolated struct ReasoningEffort: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
}

nonisolated struct CatalogModel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var efforts: [ReasoningEffort]
    var defaultEffort: String?
}

nonisolated struct ProviderGroup: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var models: [CatalogModel]
}

nonisolated struct ModelCatalog: Hashable, Sendable {
    var groups: [ProviderGroup]
    var defaultModel: ModelRef?

    func model(_ ref: ModelRef?) -> CatalogModel? {
        guard let ref else { return nil }
        return groups.first { $0.id == ref.provider }?.models.first { $0.id == ref.model }
    }

    func displayName(_ ref: ModelRef?) -> String {
        guard let ref else { return "Default model" }
        return model(ref)?.name ?? ref.model
    }

    /// Model name without its provider prefix ("V4 Flash" for "DeepSeek V4 Flash") for compact chips.
    func shortName(_ ref: ModelRef?) -> String {
        let name = displayName(ref)
        guard let ref, let provider = groups.first(where: { $0.id == ref.provider })?.name,
              name.hasPrefix(provider + " ") else { return name }
        return String(name.dropFirst(provider.count + 1))
    }

    func effortName(_ ref: ModelRef?) -> String? {
        guard let ref, let effort = ref.effort ?? model(ref)?.defaultEffort else { return nil }
        return model(ref)?.efforts.first { $0.id == effort }?.name ?? effort.capitalized
    }
}

nonisolated struct SlashCommand: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var description: String
    var hint: String?
    var kind: String
    /// Whether the command takes images or files from the composer.
    var attachments: Bool?
    var id: String { name }
    var acceptsAttachments: Bool { attachments == true }
}

nonisolated struct DirectoryListing: Codable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Sendable, Identifiable {
        var name: String
        var path: String
        var hidden: Bool
        var id: String { path }
    }
    var path: String
    var home: String?
    var parent: String?
    var entries: [Entry]
}

/// A folder on the Mac that DeepSeek linked to (docs/PROTOCOL.md `fs.read`).
nonisolated struct HostFolder: Codable, Hashable, Identifiable, Sendable {
    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var name: String
        var path: String
        var folder: Bool
        var hidden: Bool
        var id: String { path }
    }
    var path: String
    var name: String
    var entries: [Entry]
    var truncated: Bool?
    var id: String { path }
}

nonisolated struct RemoteError: LocalizedError, Sendable {
    var code: String
    var message: String
    var errorDescription: String? { message }
}
