import SwiftUI

/// Inspector beside the chat once the sidebar is hidden, showing one thought or tool call in full.
/// Swipe right (or tap ✕) to close it.
struct DetailPane: View {
    static let liveThinkingId = "live-thinking"

    let model: SessionModel
    let item: TranscriptItem
    let onClose: () -> Void

    /// The newest version of the item: thoughts keep streaming and tool calls finish while the pane is open.
    private var current: TranscriptItem {
        if item.id == Self.liveThinkingId {
            if let live = model.live, !live.thinking.isEmpty {
                return TranscriptItem(id: item.id, kind: .thinking, time: 0, text: live.thinking)
            }
            return item
        }
        if let match = model.items.first(where: { $0.id == item.id }) { return match }
        if item.kind == .tool, let callId = item.callId,
           let committed = model.items.first(where: { $0.kind == .tool && $0.callId == callId }) {
            return committed
        }
        return item
    }

    var body: some View {
        let shown = current
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: shown.kind == .thinking ? "brain" : ToolPresentation.symbol(shown.name ?? ""))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.kind == .thinking ? "Thought process" : shown.name ?? "Tool")
                        .font(.headline)
                    if shown.kind == .tool, let subtitle = ToolPresentation.subtitle(shown.args) {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    if shown.kind == .thinking {
                        Text(shown.text ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .messageMenu(shown.text ?? "")
                    } else {
                        ToolDetail(item: shown)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(item.id == Self.liveThinkingId ? .bottom : .top)
        }
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
    }

    /// A rightward flick closes the inspector; vertical drags keep scrolling.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if dx > abs(dy) * 2 && (dx > 120 || value.predictedEndTranslation.width > 260) { onClose() }
            }
    }
}
