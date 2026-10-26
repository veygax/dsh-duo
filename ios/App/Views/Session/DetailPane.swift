import SwiftUI

/// Right-hand pane, beside the chat once the sidebar is hidden, showing one thought or tool call in full.
/// Swipe it to the right (or tap ✕) to close it.
struct DetailPane: View {
    static let liveThinkingId = "live-thinking"

    let model: SessionModel
    let item: TranscriptItem
    let onClose: () -> Void
    @State private var drag: CGFloat = 0
    /// Decided once per gesture, so a swipe that drifts vertically never freezes the pane mid-way.
    @State private var axis: Axis?
    /// True while a finger is down; the system resets it even when it cancels the gesture.
    @GestureState private var dragging = false
    @State private var closing = false

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
                    } else {
                        ToolDetail(item: shown)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(item.id == Self.liveThinkingId ? .bottom : .top)
        }
        // Under the bars, but not into the side inset, so sliding it by its width hides all of it.
        .background(.background, ignoresSafeAreaEdges: .vertical)
        .offset(x: drag)
        .simultaneousGesture(swipe)
        .onChange(of: dragging) { _, dragging in
            // A cancelled drag never reaches onEnded; settle back instead of staying offset.
            guard !dragging, !closing else { return }
            axis = nil
            if drag != 0 { withAnimation(.snappy) { drag = 0 } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                // Only horizontal swipes move the pane; vertical drags keep scrolling.
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard axis == .horizontal else { return }
                drag = max(0, value.translation.width)
            }
            .onEnded { value in
                let horizontal = axis == .horizontal
                axis = nil
                if horizontal && (drag > 120 || value.predictedEndTranslation.width > 260) {
                    // Leave the offset where the finger let go; the removal slides on from there.
                    closing = true
                    onClose()
                } else if drag != 0 {
                    withAnimation(.snappy) { drag = 0 }
                }
            }
    }
}
