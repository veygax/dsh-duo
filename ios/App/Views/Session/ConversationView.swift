import SwiftUI

extension EnvironmentValues {
    /// The inspector column beside the chat is open.
    @Entry var paneOpen = false
}

/// Transcript with the composer and any open questions pinned beneath it.
struct ConversationView: View {
    @Environment(HostStore.self) private var store
    let model: SessionModel
    let sessionId: String
    /// Owned here, not by the composer, so a tap anywhere in the transcript can put the keyboard away.
    @FocusState private var composerFocused: Bool

    var body: some View {
        TranscriptView(model: model, session: store.sessions[sessionId])
            // Simultaneous, so taps still reach the row underneath (a thought, a tool call, a link).
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            // A bar, not a plain inset: content scrolling beneath it gets the system scroll edge effect.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // One container renders the question cards, command list and composer together
                // so their glass blends and morphs instead of stacking.
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(store.questions(for: sessionId)) { question in
                            if question.questions.first?.intent == "approval" {
                                ApprovalCard(pending: question)
                            } else {
                                QuestionCard(pending: question)
                            }
                        }
                        ComposerView(model: model, sessionId: sessionId, focused: $composerFocused)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .animation(.snappy, value: store.questions(for: sessionId).map(\.id))
            }
    }
}

/// A native List, not a lazy stack: it keeps its scroll position and momentum through folding,
/// the sidebar and the inspector, and never shows unmeasured (blank) rows after a resize.
struct TranscriptView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.paneOpen) private var paneOpen
    let model: SessionModel
    let session: SessionInfo?
    /// The end of the conversation is on screen. New output, and width changes that rewrap it,
    /// keep it there; once the user scrolls up, nothing moves them.
    @State private var following = true
    @State private var placeKeeper = PlaceKeeper()
    /// The row just picked from search, marked for a moment so the eye finds it.
    @State private var marked: String?
    /// The rows have been put at the end and stopped resizing. Until then the List draws its first
    /// rows and then the end, and rows settling from estimated heights drag what is shown with them,
    /// so it stays hidden for those few frames.
    @State private var placed = false
    @State private var contentHeight: CGFloat = 0

    private static let end = "transcript-end"

    /// The loading or error row ahead of the items.
    private var leadRows: Int { model.loading || model.loadError != nil ? 1 : 0 }
    /// The live or working row, the pending messages and the end marker after them.
    private var trailRows: Int { (model.live != nil || session?.running == true ? 1 : 0) + model.pending.count + 1 }

    /// The rows and their List styling; behaviour is added in `body`.
    private var list: some View {
        placeKeeper.expect(lead: leadRows, rows: leadRows + model.items.count + trailRows)
        return List {
            Group {
                if model.loading {
                    ProgressView("Loading conversation…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = model.loadError {
                    ContentUnavailableView {
                        Label("Couldn't Open Session", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again", systemImage: "arrow.clockwise", action: tap {
                            model.loading = true
                            Task { await store.open(model) }
                        })
                    }
                }

                ForEach(model.items) { item in
                    ItemView(item: item)
                        .background {
                            if marked == item.id {
                                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.16)).padding(-6)
                            }
                        }
                        .id(item.id)
                }

                if let live = model.live {
                    LiveAttemptView(live: live)
                        .id("live")
                } else if session?.running == true {
                    WorkingIndicator()
                        .id("working")
                }

                ForEach(model.pending) { message in
                    PendingBubble(message: message, running: session?.running == true)
                        .id(message.id)
                }

                Color.clear.frame(height: 1)
                    .background(ScrollViewFinder { placeKeeper.attach($0, model: model) })
                    .id(Self.end)
            }
            // A reading column of at most 780 points, centred on wide screens.
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        // Rows size to their content; the default 44-point minimum pads out dividers and the end marker.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        // Buttons inside a row act on their own rather than making the whole row one button.
        .buttonStyle(.borderless)
        .contentMargins(.vertical, 5, for: .scrollContent)
        // Rows take their new width in one step when the inspector opens or closes; animated, each box
        // would morph between widths while its text has already rewrapped.
        .transaction(value: paneOpen) { $0.animation = nil }
        .scrollDismissesKeyboard(.interactively)
    }

    var body: some View {
        ScrollViewReader { proxy in
        list
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
        } action: { _, atEnd in
            following = atEnd
        }
        .opacity(placed || model.loading || model.loadError != nil ? 1 : 0)
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, height in
            contentHeight = height
        }
        .task(id: model.loading) {
            guard !model.loading, !placed else { return }
            await place(proxy)
        }
        .onChange(of: model.loading) { if !model.loading { stickToEnd(proxy, force: true) } }
        .onChange(of: model.items.count) { stickToEnd(proxy) }
        .onChange(of: model.pending.count) { stickToEnd(proxy) }
        .onChange(of: model.live?.text.count ?? 0) { stickToEnd(proxy) }
        .onChange(of: model.live?.thinking.count ?? 0) { stickToEnd(proxy) }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { _, _ in stickToEnd(proxy) }
        .task(id: model.reveal?.token) {
            guard let reveal = model.reveal else { return }
            following = false
            proxy.scrollTo(reveal.itemId, anchor: .center)
            withAnimation(.smooth) { marked = reveal.itemId }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.smooth(duration: 0.8)) { marked = nil }
        }
        .onChange(of: model.jump?.token) {
            guard placed, let jump = model.jump else { return }
            placeKeeper.jump(toEnd: jump.toEnd)
        }
        }
    }

    /// Scroll to the end until the rows stop resizing, then show them.
    private func place(_ proxy: ScrollViewProxy) async {
        var last: CGFloat = -1
        for step in 0..<15 {
            proxy.scrollTo(Self.end, anchor: .bottom)
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            if step >= 2 && contentHeight == last { break }
            last = contentHeight
        }
        proxy.scrollTo(Self.end, anchor: .bottom)
        withAnimation(.easeOut(duration: 0.15)) { placed = true }
    }

    private func stickToEnd(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || following else { return }
        Task { proxy.scrollTo(Self.end, anchor: .bottom) }
    }
}

/// Older history is read in the background and lands above the rows on screen, then those rows settle
/// from estimated to real heights. A List keeps its offset through both, which carries what the reader
/// is looking at up or down, and SwiftUI offers no say in it. So this notes the top row on screen as
/// the reader scrolls, and when rows go in above it moves the offset to put that row back, in the same
/// layout pass and before anything is drawn. Other size changes, such as rows sizing as they scroll
/// into view, are the List's own business.
@MainActor
final class PlaceKeeper: NSObject {
    private weak var collectionView: UICollectionView?
    private weak var model: SessionModel?
    private var observations: [NSKeyValueObservation] = []
    /// Rows ahead of the transcript items, and all rows, as the view last rendered them. The model
    /// changes a pass before the List applies it; until the List's row count matches, its rows and
    /// the model's items do not line up and nothing is noted or corrected.
    private var lead = 0
    private var rows = 0
    private var anchorId: String?
    /// The anchor row's top, relative to the top of the scrolled content.
    private var anchorTop: CGFloat = 0
    /// The offset the anchor was noted at; a jump far from it (scrolling to the end, say) is not drift.
    private var anchorOffset: CGFloat = 0
    /// The reader was at the end when last noted; then the end, not a row, is what stays put.
    private var atEnd = true
    /// The first item when last noted; another one means older rows went in above.
    private var firstId: String?
    /// Rows just inserted above are still settling from estimated to real heights. Corrections follow
    /// them until the reader touches the screen; anything else is left to the List and the reader.
    private var settling = false
    private var correcting = false
    /// A jump to the top or the end in flight: where it is headed and how fast the offset is moving.
    /// Another tap only changes the target, so the motion carries its speed into the new direction.
    private var jumpLink: CADisplayLink?
    private var jumpToEnd = false
    private var jumpVelocity: CGFloat = 0

    func expect(lead: Int, rows: Int) {
        self.lead = lead
        self.rows = rows
    }

    func attach(_ scrollView: UIScrollView, model: SessionModel) {
        guard let collectionView = scrollView as? UICollectionView, collectionView !== self.collectionView else { return }
        self.collectionView = collectionView
        self.model = model
        observations = [
            collectionView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.noteAnchor() }
            },
            collectionView.observe(\.contentSize) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.restoreAnchor() }
            },
        ]
        noteAnchor()
    }

    private var inSync: Bool {
        guard let collectionView, collectionView.numberOfSections == 1 else { return false }
        return collectionView.numberOfItems(inSection: 0) == rows
    }

    private func noteAnchor() {
        guard !correcting, inSync, let collectionView, let items = model?.items,
              let path = collectionView.indexPathsForVisibleItems.min(),
              items.indices.contains(path.item - lead),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        // Mid-update the rows already have their new places but the offset has not caught up; a row
        // that is not actually on screen then is not where the reader is, so keep the last anchor.
        let offset = collectionView.contentOffset.y
        guard frame.maxY > offset, frame.minY < offset + collectionView.bounds.height else { return }
        if collectionView.isTracking { settling = false }
        atEnd = offset >= endOffset(collectionView) - 40
        firstId = items.first?.id
        anchorId = items[path.item - lead].id
        anchorTop = frame.minY - offset
        anchorOffset = offset
    }

    /// Glide to the top or the end. The end is chased as it moves (rows settling, output streaming in).
    func jump(toEnd: Bool) {
        guard let collectionView else { return }
        jumpToEnd = toEnd
        settling = false
        guard jumpLink == nil else { return }
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        jumpVelocity = 0
        let link = CADisplayLink(target: self, selector: #selector(stepJump))
        link.add(to: .main, forMode: .common)
        jumpLink = link
    }

    @objc private func stepJump(_ link: CADisplayLink) {
        guard let collectionView, !collectionView.isTracking else { return endJump() }
        let target = jumpToEnd ? endOffset(collectionView) : -collectionView.adjustedContentInset.top
        let dt = min(link.targetTimestamp - link.timestamp, 1 / 30)
        // A critically damped spring: it arrives in about the same time from any distance, never overshoots,
        // and keeps its velocity when the target flips.
        let stiffness: CGFloat = 11
        let offset = collectionView.contentOffset.y
        jumpVelocity += (-2 * stiffness * jumpVelocity - stiffness * stiffness * (offset - target)) * dt
        let next = offset + jumpVelocity * dt
        if abs(next - target) < 0.5 && abs(jumpVelocity) < 20 {
            collectionView.contentOffset.y = target
            return endJump()
        }
        collectionView.contentOffset.y = next
    }

    private func endJump() {
        jumpLink?.invalidate()
        jumpLink = nil
        jumpVelocity = 0
    }

    private func restoreAnchor() {
        // A jump moves the offset itself every frame; correcting under it would fight it.
        if jumpLink != nil {
            firstId = model?.items.first?.id
            return
        }
        guard inSync, let collectionView, let items = model?.items, let anchorId else { return noteAnchor() }
        let prepended = items.first?.id != firstId
        guard prepended || (settling && !collectionView.isTracking && !collectionView.isDecelerating) else {
            return noteAnchor()
        }
        guard abs(collectionView.contentOffset.y - anchorOffset) < collectionView.bounds.height,
              let index = items.firstIndex(where: { $0.id == anchorId }),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: lead + index, section: 0))?.frame
        else { return noteAnchor() }
        let drift = atEnd
            ? endOffset(collectionView) - collectionView.contentOffset.y
            : frame.minY - collectionView.contentOffset.y - anchorTop
        if prepended {
            settling = true
            firstId = items.first?.id
        }
        guard abs(drift) > 0.5 else { return }
        correcting = true
        collectionView.contentOffset.y += drift
        anchorOffset = collectionView.contentOffset.y
        correcting = false
    }

    private func endOffset(_ collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
    }
}

/// Hands over the UIKit scroll view behind the List this sits in.
private struct ScrollViewFinder: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> FinderView { FinderView(found: found) }
    func updateUIView(_ view: FinderView, context: Context) {}

    final class FinderView: UIView {
        let found: (UIScrollView) -> Void

        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView { return found(scrollView) }
                view = current.superview
            }
        }
    }
}

struct WorkingIndicator: View {
    var body: some View {
        Label {
            Text("Working…")
        } icon: {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityLabel("DeepSeek is working")
    }
}

/// The reply currently streaming in, before dsh commits it.
struct LiveAttemptView: View {
    let live: LiveAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !live.thinking.isEmpty {
                ThinkingView(id: DetailPane.liveThinkingId, text: live.thinking, live: live.text.isEmpty && live.tools.isEmpty)
            }
            if !live.text.isEmpty {
                MarkdownText(live.text)
            }
            ForEach(live.tools) { tool in
                ToolCallView(item: TranscriptItem(id: tool.id, kind: .tool, time: 0, callId: tool.id,
                                                  name: tool.name, args: tool.args, status: "running"))
            }
            if live.thinking.isEmpty && live.text.isEmpty && live.tools.isEmpty {
                WorkingIndicator()
            }
        }
    }
}
