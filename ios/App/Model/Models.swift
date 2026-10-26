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
    var questions: Int
    var parentId: String?

    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// Last path component of the working directory, for compact rows.
    var folderName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
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
    var images: Int?
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
    var id: String { name }
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

nonisolated struct RemoteError: LocalizedError, Sendable {
    var code: String
    var message: String
    var errorDescription: String? { message }
}
