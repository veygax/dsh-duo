import SwiftUI

/// Rows of the open Session that match the toolbar search, newest first. Picking one closes search
/// and scrolls the transcript to it. Results from the last query stay up while the next is found,
/// so typing never flashes an empty list.
struct SearchResultsView: View {
    let model: SessionModel
    let query: String
    let pick: (SearchHit) -> Void
    @State private var hits: [SearchHit] = []
    /// The query `hits` were found for.
    @State private var found: String?

    var body: some View {
        List(hits) { hit in
            Button { pick(hit) } label: { SearchHitRow(hit: hit) }
                .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay {
            if hits.isEmpty && found == query {
                ContentUnavailableView.search(text: query)
            }
        }
        // Rows still arriving from older history, or a turn adding more, search again.
        .task(id: Key(query: query, count: model.items.count, last: model.items.last)) {
            let result = await model.search.hits(for: query, in: model.items)
            guard !Task.isCancelled else { return }
            hits = result
            found = query
        }
    }

    private struct Key: Equatable {
        let query: String
        let count: Int
        let last: TranscriptItem?
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hit.kind == .user ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Spacer(minLength: 8)
                if hit.time > 0 {
                    Text(Date(timeIntervalSince1970: hit.time / 1000), format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(hit.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this message in the conversation")
    }

    private var title: String {
        switch hit.kind {
        case .user: "You"
        case .thinking: "Thought process"
        case .tool: hit.name ?? "Tool"
        case .notice: "Notice"
        default: "DeepSeek"
        }
    }

    private var symbol: String {
        switch hit.kind {
        case .user: "person.fill"
        case .thinking: "brain"
        case .tool: ToolPresentation.symbol(hit.name ?? "")
        case .notice: "info.circle"
        default: "sparkle"
        }
    }
}
