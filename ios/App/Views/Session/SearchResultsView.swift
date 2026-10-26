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
        // The search field floats over the last rows.
        .contentMargins(.bottom, 72, for: .scrollContent)
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

/// The search field for the open Session: a glass capsule with a close button beside it. It is one
/// field throughout, so where it sits can change without the keyboard going away.
struct SearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let close: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Messages", text: $query)
                        .focused(focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                    if !query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill", action: tap { query = "" })
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(.capsule)
                .onTapGesture { focused.wrappedValue = true }
                .glassEffect(.regular.interactive(), in: .capsule)

                Button("Close Search", systemImage: "xmark", action: tap { close() })
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .frame(width: 48, height: 48)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .frame(maxWidth: 560)
        .animation(.snappy, value: query.isEmpty)
        .onAppear { focused.wrappedValue = true }
    }
}
