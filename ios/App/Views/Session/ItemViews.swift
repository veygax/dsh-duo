import SwiftUI

struct ItemView: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user: UserBubble(item: item)
        case .text:
            MarkdownText(item.text ?? "")
                .messageMenu(item.text ?? "", markdown: true)
        case .thinking: ThinkingView(id: item.id, text: item.text ?? "", live: false)
        case .tool: ToolCallView(item: item)
        case .notice: NoticeView(item: item)
        case .turn: TurnDivider(reason: item.reason ?? "completed")
        case .unknown: EmptyView()
        }
    }
}

struct CopyButton: View {
    let text: String
    var body: some View {
        Button("Copy", systemImage: "doc.on.doc", action: tap { UIPasteboard.general.string = text })
    }
}

struct UserBubble: View {
    let item: TranscriptItem

    private var attachments: [TranscriptAttachment] { item.attachments ?? [] }

    var body: some View {
        HStack {
            Spacer(minLength: 32)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    AttachmentGallery(attachments: attachments)
                }
                if let text = item.text, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 20))
                        .messageMenu(text)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var messageSummary: String {
        let images = attachments.filter(\.isImage).count
        let files = attachments.count - images
        switch (images, files) {
        case let (images, 0): return "\(images) image\(images == 1 ? "" : "s")"
        case let (0, files): return "\(files) file\(files == 1 ? "" : "s")"
        default: return "\(images) image\(images == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
        }
    }

    private var accessibilityLabel: String {
        if let text = item.text, !text.isEmpty { return "You: \(text)" }
        return "You sent \(messageSummary)"
    }
}

/// A message sent during a turn that dsh has not taken in yet.
/// Stopping a turn leaves these in dsh's inbox without starting another, so once nothing runs
/// they wait for the next message, which carries them in ahead of it.
struct PendingBubble: View {
    let message: PendingMessage
    let running: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !message.attachments.isEmpty {
                HStack {
                    Spacer(minLength: 32)
                    PendingAttachmentGallery(attachments: message.attachments)
                }
            }
            if !message.text.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(message.text)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.gradient.opacity(0.55), in: .rect(cornerRadius: 20))
                }
            }
            Label(status, systemImage: running ? (message.steer ? "arrow.turn.down.right" : "clock") : "pause.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if !running { return "Sends with your next message" }
        return message.steer ? "Steering this turn" : "Queued for after this turn"
    }
}

/// On the open inner display with the sidebar hidden, thoughts and tool calls open in the side pane
/// instead of expanding inline. The pane's owner supplies this; elsewhere it is nil.
struct Inspector {
    var selectedId: String?
    var open: (TranscriptItem) -> Void
}

extension EnvironmentValues {
    @Entry var inspector: Inspector?
}

struct ThinkingView: View {
    @Environment(\.inspector) private var inspector
    let id: String
    let text: String
    let live: Bool
    @State private var expanded: Bool?

    var body: some View {
        let isExpanded = inspector == nil && (expanded ?? live)
        let selected = inspector?.selectedId == id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let inspector {
                    inspector.open(TranscriptItem(id: id, kind: .thinking, time: 0, text: text))
                    return
                }
                Haptics.tap()
                withAnimation(.snappy) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, options: .repeating, isActive: live)
                    Text(live ? "Thinking…" : "Thought process")
                        .font(.subheadline.weight(.medium))
                    if !isExpanded {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.vertical, inspector == nil ? 0 : 8)
                .padding(.horizontal, inspector == nil ? 0 : 10)
                .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? "Thinking" : "Thought process")
            .accessibilityHint(inspector != nil ? "Shows the reasoning beside the chat" : isExpanded ? "Collapses the reasoning" : "Shows the reasoning")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if isExpanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                    .transition(.opacity)
                    .messageMenu(text)
            }
        }
    }

    private var preview: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// Presentation hints for common dsh tool names.
enum ToolPresentation {
    static func symbol(_ name: String) -> String {
        let name = name.lowercased()
        if name.contains("bash") || name.contains("shell") || name.contains("pwsh") || name.contains("terminal") { return "terminal" }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return "pencil.line" }
        if name.contains("read") || name.contains("view") { return "doc.text" }
        if name.contains("grep") || name.contains("glob") || name.contains("search") || name.contains("find") { return "magnifyingglass" }
        if name.contains("web") || name.contains("fetch") || name.contains("browser") { return "globe" }
        if name.contains("ask") || name.contains("question") { return "questionmark.bubble" }
        if name.contains("todo") || name.contains("plan") { return "checklist" }
        if name.contains("code") || name.contains("ptc") { return "curlybraces" }
        if name.contains("agent") || name.contains("task") { return "person.2" }
        if name.contains("image") { return "photo" }
        return "wrench.and.screwdriver"
    }

    /// The single most telling argument: a command, a path, a query…
    static func subtitle(_ args: String?) -> String? {
        guard let args, !args.isEmpty else { return nil }
        if let data = args.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "cmd", "path", "file_path", "filePath", "pattern", "query", "url", "description", "prompt", "code"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            if let first = object.values.first(where: { $0 is String }) as? String { return first }
        }
        return args
    }

    static func prettyJSON(_ text: String?) -> String {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return text ?? ""
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}

struct ToolCallView: View {
    @Environment(\.inspector) private var inspector
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        let selected = inspector?.selectedId == item.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let inspector {
                    inspector.open(item)
                    return
                }
                Haptics.tap()
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ToolPresentation.symbol(item.name ?? ""))
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Tool")
                            .font(.subheadline.weight(.medium))
                        if let subtitle = ToolPresentation.subtitle(item.args) {
                            Text(subtitle)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    if let count = item.attachments?.count, count > 0 {
                        AttachmentCountBadge(count: count)
                    }
                    status
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded && inspector == nil {
                Divider()
                ToolDetail(item: item)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : item.isFailedTool ? Color.red.opacity(0.4) : .clear)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case "running":
            ProgressView().controlSize(.mini).accessibilityLabel("Running")
        case "error":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        default:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        }
    }
}

/// A tool call's input and output.
struct ToolDetail: View {
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let args = item.args, !args.isEmpty {
                CodeBlock(code: ToolPresentation.prettyJSON(args), language: "input")
            }
            if let result = item.result, !result.isEmpty {
                CodeBlock(code: result, language: item.isFailedTool ? "error" : "output")
            } else if item.isRunningTool {
                Label("Running…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
            if let attachments = item.attachments, !attachments.isEmpty {
                AttachmentGallery(attachments: attachments, loneImageMax: 200, thumbSide: 64, alignment: .leading)
            }
        }
    }
}

struct NoticeView: View {
    let item: TranscriptItem

    var body: some View {
        let isError = item.level == "error"
        Label {
            Text(item.text ?? "").textSelection(.enabled)
        } icon: {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary.opacity(isError ? 0 : 1), in: .rect(cornerRadius: 12))
        .messageMenu(item.text ?? "")
    }
}

struct TurnDivider: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            if reason != "completed" && reason != "stop" {
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityHidden(reason == "completed")
    }

    private var label: String {
        switch reason {
        case "cancelled", "aborted": "Stopped"
        case "error": "Ended with an error"
        case "max-tokens": "Reached the output limit"
        default: reason.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}
