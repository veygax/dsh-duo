import SwiftUI

/// Transcript with the composer and any open questions pinned beneath it.
struct ConversationView: View {
    @Environment(HostStore.self) private var store
    let model: SessionModel
    let sessionId: String

    var body: some View {
        TranscriptView(model: model, session: store.sessions[sessionId])
            // A bar, not a plain inset: content scrolling beneath it gets the system scroll edge effect.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // One container renders the question cards, command list and composer together
                // so their glass blends and morphs instead of stacking.
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(store.questions(for: sessionId)) { question in
                            QuestionCard(pending: question)
                        }
                        ComposerView(model: model, sessionId: sessionId)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .animation(.snappy, value: store.questions(for: sessionId).map(\.id))
            }
    }
}

struct TranscriptView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.layoutEpoch) private var layoutEpoch
    let model: SessionModel
    let session: SessionInfo?
    /// The lazy stack can keep a scroll offset into rows it has not measured at the new width,
    /// showing an empty transcript. After the window resizes, rebuild it, anchored at the end.
    @State private var generation = 0
    /// The row at the top of the screen, tracked live by the scroll view.
    @State private var topId: String?
    /// Where the user left off. Only their own scrolling updates it, so a resize, a rebuild or a
    /// reconnect can't move it; a rebuild puts them back here. Not observed, so it never re-renders.
    @State private var reading = Reading()

    private final class Reading {
        var atBottom = true
        var topId: String?
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
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
                } else if model.items.isEmpty && model.live == nil {
                    EmptySessionHint(session: session, model: model)
                }

                ForEach(model.items) { item in
                    ItemView(item: item)
                        .id(item.id)
                }

                if let live = model.live {
                    LiveAttemptView(live: live)
                        .id("live")
                } else if session?.running == true {
                    WorkingIndicator()
                        .id("working")
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 780)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .id(generation)
        .scrollPosition(id: $topId, anchor: .top)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollPhaseChange { old, new, context in
            guard new == .idle, old != .idle else { return }
            let geometry = context.geometry
            reading.atBottom = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            reading.topId = topId
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: layoutEpoch) {
            generation += 1
            topId = reading.atBottom ? nil : reading.topId
        }
    }
}

/// First-run guidance inside a blank Session.
private struct EmptySessionHint: View {
    @Environment(HostStore.self) private var store
    let session: SessionInfo?
    let model: SessionModel

    private let suggestions = [
        "Explain how this project is structured",
        "Find and fix failing tests",
        "Review my uncommitted changes",
    ]

    var body: some View {
        let mode = store.mode(of: session)
        VStack(alignment: .leading, spacing: 16) {
            Label(mode.name, systemImage: mode.symbol)
                .font(.title2.bold())
            Text(mode.summary)
                .foregroundStyle(.secondary)
            if let cwd = session?.cwd {
                Label(cwd, systemImage: "folder")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(action: tap { model.draft = suggestion }) {
                        Text(suggestion)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle)
                    .controlSize(.large)
                    .tint(.secondary)
                    .foregroundStyle(.primary)
                }
            }
            Text("Type / to see commands and skills.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 40)
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
