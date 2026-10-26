import Foundation
import SwiftUI

/// One transcript row that matches a search, with the words around the first match.
nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    var id: String { itemId }
    let itemId: String
    let kind: TranscriptItem.Kind
    /// The tool's name, for tool rows.
    let name: String?
    let time: Double
    let snippet: AttributedString
}

/// Finds rows by their text away from the main thread, so typing never waits on a long transcript.
/// Each row's text is folded (case and accents dropped) once and kept, so a keystroke is one plain
/// substring scan over strings already folded.
actor TranscriptSearch {
    private var folded: [String: (source: String, folded: String)] = [:]
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    static let limit = 300

    func hits(for query: String, in items: [TranscriptItem]) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: Self.options, locale: nil)
        guard !needle.isEmpty else { return [] }
        var hits: [SearchHit] = []
        // Newest first: what was just said is what is most often looked for.
        for item in items.reversed() {
            if Task.isCancelled { return [] }
            guard let source = Self.text(of: item) else { continue }
            let entry: (source: String, folded: String)
            if let cached = folded[item.id], cached.source == source {
                entry = cached
            } else {
                entry = (source, source.folding(options: Self.options, locale: nil))
                folded[item.id] = entry
            }
            guard entry.folded.contains(needle) else { continue }
            hits.append(SearchHit(itemId: item.id, kind: item.kind, name: item.name, time: item.time,
                                  snippet: Self.snippet(source, query: query)))
            if hits.count == Self.limit { break }
        }
        return hits
    }

    /// What a row says, as the reader sees it; dividers and empty rows have nothing to find.
    private static func text(of item: TranscriptItem) -> String? {
        switch item.kind {
        case .user, .text, .thinking, .notice: item.text.flatMap { $0.isEmpty ? nil : $0 }
        case .tool: [item.name, item.args, item.result].compactMap(\.self).joined(separator: "\n")
        case .turn, .unknown: nil
        }
    }

    /// One line around the first match, with the match in bold.
    private static func snippet(_ source: String, query: String) -> AttributedString {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = source.range(of: trimmed, options: options) else {
            return AttributedString(String(source.prefix(140)).flattened)
        }
        let start = source.index(range.lowerBound, offsetBy: -48, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: 120, limitedBy: source.endIndex) ?? source.endIndex
        var before = AttributedString((start == source.startIndex ? "" : "…") + String(source[start..<range.lowerBound]).flattened)
        var match = AttributedString(String(source[range]).flattened)
        match.inlinePresentationIntent = .stronglyEmphasized
        match.swiftUI.foregroundColor = .primary
        let after = AttributedString(String(source[range.upperBound..<end]).flattened + (end == source.endIndex ? "" : "…"))
        before.append(match)
        before.append(after)
        return before
    }
}

private extension String {
    /// Line breaks and runs of spaces collapsed, for a one-line snippet.
    nonisolated var flattened: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .appending(last?.isWhitespace == true && !isEmpty ? " " : "")
            .prepending(first?.isWhitespace == true && count > 1 ? " " : "")
    }

    nonisolated func prepending(_ prefix: String) -> String { prefix + self }
}
