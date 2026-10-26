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

    private static let end = "transcript-end"

    var body: some View {
        ScrollViewReader { proxy in
        List {
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

                Color.clear.frame(height: 1).id(Self.end)
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
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
        } action: { _, atEnd in
            following = atEnd
        }
        .onChange(of: model.loading, initial: true) { if !model.loading { stickToEnd(proxy, force: true) } }
        .onChange(of: model.items.count) { stickToEnd(proxy) }
        .onChange(of: model.live?.text.count ?? 0) { stickToEnd(proxy) }
        .onChange(of: model.live?.thinking.count ?? 0) { stickToEnd(proxy) }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { _, _ in stickToEnd(proxy) }
        }
    }

    private func stickToEnd(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || following else { return }
        Task { proxy.scrollTo(Self.end, anchor: .bottom) }
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
