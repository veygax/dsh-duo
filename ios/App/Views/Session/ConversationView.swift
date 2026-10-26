import SwiftUI

/// Transcript with the composer and any open questions pinned beneath it.
struct ConversationView: View {
    @Environment(HostStore.self) private var store
    let model: SessionModel
    let sessionId: String

    var body: some View {
        TranscriptView(model: model, session: store.sessions[sessionId])
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    ForEach(store.questions(for: sessionId)) { question in
                        QuestionCard(pending: question)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ComposerView(model: model, sessionId: sessionId)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .animation(.snappy, value: store.questions(for: sessionId).map(\.id))
            }
    }
}

struct TranscriptView: View {
    @Environment(HostStore.self) private var store
    let model: SessionModel
    let session: SessionInfo?

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
            .frame(maxWidth: 780)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
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
                ThinkingView(text: live.thinking, live: live.text.isEmpty && live.tools.isEmpty)
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
