import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One durable image or file a message carries (docs/PROTOCOL.md `Attachment`).
nonisolated struct TranscriptAttachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image, file

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .file
        }
    }

    var kind: Kind
    /// Content-addressed storage id (`sha256:…`); the phone reads bytes by it.
    var attachmentId: String
    var name: String?
    /// Image media type; absent on files.
    var mediaType: String?
    var bytes: Int
    var width: Int?
    var height: Int?

    var id: String { "\(kind.rawValue):\(attachmentId):\(name ?? "")" }
    var isImage: Bool { kind == .image }

    /// A name for labels: the stored one, or the image's type.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        guard isImage else { return "Attachment" }
        switch mediaType {
        case "image/png": return "Image.png"
        case "image/gif": return "Image.gif"
        case "image/webp": return "Image.webp"
        default: return "Image.jpg"
        }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Width over height, for sizing a thumbnail before its bytes arrive.
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return min(max(Double(width) / Double(height), 0.25), 4)
    }

    /// The extension to cache and preview this attachment with.
    var fileExtension: String? {
        if let mediaType {
            switch mediaType {
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/jpeg": return "jpg"
            default: break
            }
        }
        guard let name else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : String(ext.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(8))
    }

}

/// An attachment being composed, before it is uploaded: local bytes, a thumbnail, and progress.
@Observable
final class AttachmentDraft: Identifiable {
    let id = UUID()
    let kind: TranscriptAttachment.Kind
    let name: String
    let mediaType: String?
    let data: Data
    let thumbnail: UIImage?
    /// Zero to one while the attachment uploads, nil before and after.
    var progress: Double?

    init(_ prepared: PreparedAttachment) {
        kind = prepared.kind
        name = prepared.name
        mediaType = prepared.mediaType
        data = prepared.data
        thumbnail = prepared.thumbnailData.flatMap { UIImage(data: $0) }
    }

    var bytes: Int { data.count }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var pending: PendingAttachment {
        PendingAttachment(kind: kind, name: name, bytes: bytes, thumbnail: thumbnail)
    }
}

/// A message already sent whose attachments are still uploading or waiting for dsh to take it in.
struct PendingAttachment: Identifiable {
    let id = UUID()
    let kind: TranscriptAttachment.Kind
    let name: String
    let bytes: Int
    let thumbnail: UIImage?
}

/// The bytes and metadata one attached file or photo becomes on the wire.
nonisolated struct PreparedAttachment: Sendable {
    let kind: TranscriptAttachment.Kind
    let name: String
    let mediaType: String?
    let data: Data
    /// A small PNG of the image, for the composer rail and pending bubbles.
    let thumbnailData: Data?
    let width: Int?
    let height: Int?
}

/// Turns picked photos and files into attachments dsh accepts: PNG, JPEG, WebP or GIF,
/// with large images downsampled and unsupported ones (HEIC, say) transcoded.
nonisolated enum AttachmentPayload {
    /// Largest file the phone attaches; dsh stores files verbatim, but the phone must read it whole.
    static let maxFileBytes = 64 * 1024 * 1024
    /// Above this, an image is downsampled and re-encoded rather than sent as picked.
    private static let maxKeptImageBytes = 3_000_000
    private static let maxKeptImagePixels = 4_000_000
    private static let maxImageEdge = 2048

    static func image(data: Data, name: String) -> PreparedAttachment? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let detected = CGImageSourceGetType(source) as String?
        let type = detected.flatMap { UTType($0) }
        let supported = mediaType(for: type)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        var bytes = data
        var mediaType = supported ?? "image/jpeg"

        let tooLarge = data.count > maxKeptImageBytes || width * height > maxKeptImagePixels
        if supported == nil || tooLarge {
            guard let image = downsampled(source, maxPixel: maxImageEdge) else { return nil }
            width = image.width
            height = image.height
            let uiImage = UIImage(cgImage: image)
            // Keep transparency when the source had it; a photo becomes a compact JPEG.
            if (supported == "image/png" || supported == "image/gif"),
               let png = uiImage.pngData(), png.count <= 4_000_000 {
                bytes = png
                mediaType = "image/png"
            } else if let jpeg = uiImage.jpegData(compressionQuality: 0.85) {
                bytes = jpeg
                mediaType = "image/jpeg"
            } else {
                return nil
            }
        }

        let thumbnail = downsampled(source, maxPixel: 192).flatMap { UIImage(cgImage: $0).pngData() }
        return PreparedAttachment(
            kind: .image,
            name: named(name, mediaType: mediaType),
            mediaType: mediaType,
            data: bytes,
            thumbnailData: thumbnail,
            width: width > 0 ? width : nil,
            height: height > 0 ? height : nil,
        )
    }

    static func file(data: Data, name: String) -> PreparedAttachment? {
        guard data.count <= maxFileBytes else { return nil }
        return PreparedAttachment(kind: .file, name: name.isEmpty ? "Attachment" : name,
                                  mediaType: nil, data: data, thumbnailData: nil, width: nil, height: nil)
    }

    /// Read a picked file. An image is prepared as a photo; anything else stays verbatim.
    static func pickedFile(_ url: URL) -> PreparedAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values?.fileSize, size > maxFileBytes { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let name = url.lastPathComponent.isEmpty ? "Attachment" : url.lastPathComponent
        if values?.contentType?.conforms(to: .image) == true, let image = image(data: data, name: name) {
            return image
        }
        return file(data: data, name: name)
    }

    private static func mediaType(for type: UTType?) -> String? {
        guard let type else { return nil }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        return nil
    }

    private static func named(_ name: String, mediaType: String) -> String {
        let ext: String
        switch mediaType {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        let base = (name as NSString).deletingPathExtension
        let current = (name as NSString).pathExtension.lowercased()
        let matching = mediaType == "image/jpeg" ? ["jpg", "jpeg"] : [ext]
        if !current.isEmpty, matching.contains(current) { return name }
        let trimmed = base.isEmpty ? "Photo" : base
        return "\(trimmed).\(ext)"
    }

    /// One image, decoded at its display size rather than full resolution.
    static func downsampled(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Image decoding away from the main thread: thumbnails for the chat and full files for QuickLook.
nonisolated enum AttachmentMedia {
    static func thumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = AttachmentPayload.downsampled(source, maxPixel: Int(maxPixel)) else { return nil }
        return UIImage(cgImage: image)
    }
}
