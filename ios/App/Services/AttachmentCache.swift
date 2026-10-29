import CryptoKit
import Foundation
import UIKit

/// Bytes for durable attachments, kept on disk between launches.
///
/// Attachments are content-addressed, so a file here is valid for any session: the same image
/// attached twice downloads once, and opening a session again shows its pictures immediately.
enum AttachmentDiskCache {
    private static var root: URL {
        URL.cachesDirectory.appending(path: "DuoAttachments", directoryHint: .isDirectory)
    }

    static func data(for key: String, ext: String?) -> Data? {
        try? Data(contentsOf: url(for: key, ext: ext), options: .mappedIfSafe)
    }

    @discardableResult
    static func store(_ data: Data, for key: String, ext: String?) -> URL? {
        let url = url(for: key, ext: ext)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func url(for key: String, ext: String?) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest + (ext.map { "." + $0 } ?? ""))
    }

    /// A file QuickLook can open by name: a private folder per preview, so two files never collide.
    static func temporaryFile(named name: String, data: Data) throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "Attachments/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: sanitized(name))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Strip path separators and control characters, keep an extension, and bound the length.
    static func sanitized(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = name.unicodeScalars.map { separators.contains($0) ? "-" : Character($0) }
        var result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = "Attachment" }
        if result.count > 160 {
            let ext = (result as NSString).pathExtension
            let base = (result as NSString).deletingPathExtension
            result = String(base.prefix(max(1, 150 - ext.count))) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return result
    }
}
