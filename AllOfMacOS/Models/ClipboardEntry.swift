import AppKit
import CryptoKit
import Foundation

/// An item preserves each pasteboard representation so pasting an image, file,
/// or formatted document does not silently turn it into its text preview.
struct ClipboardEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case text, link, image, file, color
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .link: return "link"
            case .image: return "photo"
            case .file: return "doc"
            case .color: return "paintpalette"
            }
        }
    }

    var id: UUID
    var title: String
    var text: String?
    var kind: Kind
    var sourceName: String?
    var sourceBundleID: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var pinboardIDs: Set<UUID>
    var items: [[String: Data]]
    /// Optional fields keep older clipboard archives readable. OCR stays on device.
    var recognizedText: String?
    var recognizedImageDigest: String?
    /// Set on entries created by `ClipboardStore.duplicate(entryID:)`. It marks
    /// a user-made "Copy" so a later copy of the *original* content is credited
    /// to the original during de-duplication instead of to the copy.
    var duplicatedFrom: UUID? = nil

    init(id: UUID = UUID(), title: String, text: String? = nil, kind: Kind = .text,
         sourceName: String? = nil, sourceBundleID: String? = nil, createdAt: Date = Date(),
         lastCopiedAt: Date? = nil, pinboardIDs: Set<UUID> = [], items: [[String: Data]]) {
        self.id = id
        self.title = title
        self.text = text
        self.kind = kind
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.pinboardIDs = pinboardIDs
        self.items = items
        self.recognizedText = nil
        self.recognizedImageDigest = nil
    }

    var previewText: String {
        if let text, !text.isEmpty { return String(text.prefix(4_000)) }
        if !fileURLs.isEmpty { return fileURLs.map(\.lastPathComponent).joined(separator: "\n") }
        return title
    }

    var imageData: Data? {
        for item in items {
            for type in [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue,
                         "public.jpeg", "public.heic", "org.webmproject.webp", "com.compuserve.gif"] {
                if let data = item[type] { return data }
            }
        }
        return nil
    }

    /// File URLs are references. Capturing a copy operation must never read,
    /// upload, or duplicate the contents of the referenced files.
    var fileURLs: [URL] {
        items.compactMap { item in
            guard let data = item[NSPasteboard.PasteboardType.fileURL.rawValue],
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url
        }
    }

    var byteCount: Int { items.reduce(0) { total, item in total + item.values.reduce(0) { $0 + $1.count } } }

    /// Length prefixes and sorted type names make the digest independent of
    /// dictionary iteration order without conflating item boundaries.
    var payloadDigest: String {
        var hash = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for item in items {
            var count = UInt64(item.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            for key in item.keys.sorted() {
                append(Data(key.utf8))
                append(item[key]!)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func captured(items: [[String: Data]], sourceName: String?, sourceBundleID: String?, at date: Date) -> ClipboardEntry {
        let strings = items.compactMap { item -> String? in
            for type in [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue] {
                if let data = item[type], let value = String(data: data, encoding: .utf8) { return value }
            }
            if let data = item["public.utf16-external-plain-text"],
               let value = String(data: data, encoding: .utf16) { return value }
            // Some editors expose RTF/RTFD without a plain-text representation.
            // Keep the original payload while making it searchable/plain-pasteable.
            for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
                                   (.rtfd, .rtfd)] {
                if let data = item[type.rawValue],
                   let value = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil) {
                    return value.string
                }
            }
            return nil
        }
        let text = strings.isEmpty ? nil : strings.joined(separator: "\n")
        var entry = ClipboardEntry(title: "Clipboard Item", text: text, sourceName: sourceName,
                                   sourceBundleID: sourceBundleID, createdAt: date, items: items)
        if !entry.fileURLs.isEmpty {
            entry.kind = .file
            entry.title = entry.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        } else if entry.imageData != nil {
            entry.kind = .image
            entry.title = "Image"
        } else if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil {
                entry.kind = .color
            } else if let url = URL(string: trimmed), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                      !trimmed.contains(where: \.isWhitespace) {
                entry.kind = .link
            }
            entry.title = String(trimmed.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(100) ?? "Text".prefix(100))
        }
        return entry
    }
}

struct ClipboardPinboard: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var color: String = "blue"
}
