import SwiftUI

/// Opens an attachment's full bytes (QuickLook); the session screen owns the presentation.
struct AttachmentOpener {
    var open: (TranscriptAttachment) -> Void
}

extension EnvironmentValues {
    /// The Session a transcript row belongs to, for reading attachments and linked images.
    @Entry var sessionId: String?
    @Entry var attachmentOpener: AttachmentOpener?
}

/// Attachments on one message: a lone image stands alone, several wrap as thumbnails and file cards.
struct AttachmentGallery: View {
    let attachments: [TranscriptAttachment]
    var loneImageMax: CGFloat = 240
    var thumbSide: CGFloat = 72
    var alignment: HorizontalAlignment = .trailing

    private var loneImage: TranscriptAttachment? {
        attachments.count == 1 && attachments[0].isImage ? attachments[0] : nil
    }

    var body: some View {
        if let loneImage {
            AttachmentThumbnail(attachment: loneImage, maxSide: loneImageMax, cornerRadius: 18)
        } else {
            FlowLayout(spacing: 6, lineSpacing: 6, alignment: alignment) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    if attachment.isImage {
                        AttachmentThumbnail(attachment: attachment, maxSide: thumbSide, square: true, cornerRadius: 12)
                    } else {
                        AttachmentFileCard(attachment: attachment)
                    }
                }
            }
        }
    }
}

/// One durable image, fetched from its Mac and decoded at the size it is shown.
struct AttachmentThumbnail: View {
    @Environment(HostStore.self) private var store
    @Environment(\.sessionId) private var sessionId
    @Environment(\.attachmentOpener) private var opener
    let attachment: TranscriptAttachment
    var maxSide: CGFloat = 240
    var square = false
    var cornerRadius: CGFloat = 16
    @State private var image: UIImage?
    @State private var failed = false

    private var size: CGSize {
        if square { return CGSize(width: maxSide, height: maxSide) }
        let ratio = attachment.aspectRatio ?? 4.0 / 3.0
        if ratio >= 1 { return CGSize(width: maxSide, height: max(72, maxSide / ratio)) }
        return CGSize(width: max(72, maxSide * ratio), height: maxSide)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title3)
                    Text("Tap to retry").font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.fill.quaternary)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .contentShape(.rect)
        .onTapGesture {
            if image != nil {
                Haptics.tap()
                opener?.open(attachment)
            } else if failed {
                failed = false
                Task { await load() }
            }
        }
        .task(id: attachment.id) { await load() }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full image")
    }

    private var accessibilityText: String {
        var text = "Photo, \(attachment.displayName)"
        if let width = attachment.width, let height = attachment.height {
            text += ", \(width) by \(height)"
        }
        return text
    }

    private func load() async {
        guard image == nil, let sessionId else { return }
        let target = max(320, max(size.width, size.height) * 2)
        if let loaded = await store.attachmentThumbnail(attachment, in: sessionId, maxPixel: target) {
            image = loaded
        } else {
            failed = true
        }
    }
}

/// A file on the Mac: its name, type and size, opening in QuickLook.
struct AttachmentFileCard: View {
    @Environment(\.attachmentOpener) private var opener
    let attachment: TranscriptAttachment
    var width: CGFloat = 200
    var height: CGFloat = 56

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: FileGlyph.symbol(for: attachment))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.fileExtension?.uppercased() ?? "FILE") · \(attachment.sizeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onTapGesture {
            Haptics.tap()
            opener?.open(attachment)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File, \(attachment.displayName), \(attachment.sizeText)")
        .accessibilityHint("Opens the file")
    }
}

/// A picked file's glyph, from its extension.
enum FileGlyph {
    static func symbol(for attachment: TranscriptAttachment) -> String {
        symbol(forExtension: attachment.fileExtension)
    }

    static func symbol(for draft: AttachmentDraft) -> String {
        let named = (draft.name as NSString).pathExtension
        return symbol(forExtension: named.isEmpty ? draft.mediaType.map(extensionName(for:)) : named)
    }

    static func symbol(forExtension ext: String?) -> String {
        switch ext?.lowercased() {
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "rar", "7z": "doc.zipper"
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "c", "h", "cpp", "rb", "sh",
             "json", "yml", "yaml", "toml", "xml", "md", "txt", "log", "csv": "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff": "photo"
        case "xls", "xlsx", "numbers": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "mp3", "wav", "m4a", "aac": "waveform"
        case "mp4", "mov", "m4v": "film"
        default: "doc"
        }
    }

    private static func extensionName(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}

/// The composer's staged attachments, before they are sent.
struct DraftRail: View {
    let drafts: [AttachmentDraft]
    var canRemove = true
    let remove: (AttachmentDraft) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(drafts) { draft in
                    DraftCard(draft: draft, canRemove: canRemove) { remove(draft) }
                }
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Attachments")
    }
}

struct DraftCard: View {
    let draft: AttachmentDraft
    var canRemove = true
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = draft.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: FileGlyph.symbol(for: draft))
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(draft.sizeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 190, height: 64)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            }

            if let progress = draft.progress, progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .padding(6)
                    .background(.black.opacity(0.35), in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel("Remove \(draft.name)")
            }
        }
        .opacity(draft.progress == nil || draft.progress == 1 ? 1 : 0.85)
        .accessibilityElement(children: .contain)
    }
}

/// Thumbnails for a message dsh has not taken in yet: the bytes are still here on the phone.
struct PendingAttachmentGallery: View {
    let attachments: [PendingAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityLabel("Photo, \(attachment.name)")
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: FileGlyph.symbol(forExtension: (attachment.name as NSString).pathExtension))
                            .foregroundStyle(.tint)
                        Text(attachment.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 150, height: 56)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("File, \(attachment.name)")
                }
            }
        }
    }
}

/// A Markdown image: a picture on the Mac (`![alt](screenshot.png)`) or one on the Web.
struct MarkdownImageView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.sessionId) private var sessionId
    @Environment(\.openURL) private var openURL
    let alt: String
    let source: String
    @State private var image: UIImage?
    @State private var failed = false

    private var remote: URL? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let image {
                picture(Image(uiImage: image))
            } else if let remote {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image): picture(image)
                    case .failure: placeholder
                    case .empty:
                        ProgressView().frame(width: 160, height: 120)
                    @unknown default: placeholder
                    }
                }
            } else if failed {
                placeholder
            } else {
                ProgressView()
                    .frame(width: 160, height: 120)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            }
        }
        .contentShape(.rect)
        .onTapGesture { open() }
        .task(id: source) { await load() }
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityAddTraits(.isButton)
    }

    private func picture(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 360, maxHeight: 360)
            .clipShape(.rect(cornerRadius: 12))
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark").font(.title2)
            Text(alt.isEmpty ? source : alt)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(width: 190)
        .padding(10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }

    private func load() async {
        guard remote == nil, image == nil, let sessionId else { return }
        image = await store.image(at: source, in: sessionId)
        if image == nil { failed = true }
    }

    private func open() {
        Haptics.tap()
        if let remote { return openURL(remote) }
        // A host path, relative to the Session's folder: the session screen intercepts it.
        let encoded = source.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source
        if let url = URL(string: encoded) { openURL(url) }
    }
}

/// A small badge for a tool row that returned pictures.
struct AttachmentCountBadge: View {
    let count: Int

    var body: some View {
        Label("\(count)", systemImage: "photo")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(count) attachment\(count == 1 ? "" : "s")")
    }
}

/// Wrapping rows with the given horizontal alignment, for mixed thumbnails and file cards.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews, maxWidth: maxWidth)
        let width = rows.map { row in row.width }.max() ?? 0
        let height = rows.reduce(0) { total, row in total + row.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            if row.indices.isEmpty { row.width = size.width } else { row.width += spacing + size.width }
            row.indices.append(index)
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
