import AppKit

/// Prepare data before touching the pasteboard; rich-text composition may take
/// time, but the UI and the previous clipboard remain available throughout.
enum ClipboardWritePayload {
    static func make(_ selected: [ClipboardEntry], plainText: Bool, separator: String) throws -> [[String: Data]] {
        guard !selected.isEmpty else { throw ClipboardStore.StoreError.emptySelection }
        let limit = ClipboardStore.maximumEntryBytes
        if plainText && selected.allSatisfy({ $0.text != nil || !$0.fileURLs.isEmpty }) {
            let parts = selected.compactMap { entry -> String? in
                if let text = entry.text { return text }
                return entry.fileURLs.map(\.path).joined(separator: separator)
            }
            let text = parts.joined(separator: separator)
            guard text.utf8.count <= limit else { throw ClipboardStore.StoreError.tooLarge }
            return [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        }
        if selected.count > 1 && selected.allSatisfy({ [.text, .link, .color].contains($0.kind) && $0.text != nil }) {
            let text = selected.compactMap(\.text).joined(separator: separator)
            guard text.utf8.count <= limit, selected.reduce(0, { $0 + $1.byteCount }) <= limit else {
                throw ClipboardStore.StoreError.tooLarge
            }
            var item = [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]
            // The common case needs no attributed copy of every large string.
            if selected.contains(where: { richTextData($0) != nil }) {
                let attributed = NSMutableAttributedString(string: "")
                var hasRichText = false
                var hasAttachments = false
                for (index, entry) in selected.enumerated() {
                    if index > 0 { attributed.append(NSAttributedString(string: separator)) }
                    if let (data, type) = richTextData(entry),
                       let rich = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil),
                       sameText(rich.string, entry.text ?? "") {
                        attributed.append(rich); hasRichText = true
                        hasAttachments = hasAttachments || type == .rtfd
                    } else { attributed.append(NSAttributedString(string: entry.text ?? "")) }
                }
                let range = NSRange(location: 0, length: attributed.length)
                if hasRichText, let rtf = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                   rtf.count <= limit {
                    item[NSPasteboard.PasteboardType.rtf.rawValue] = rtf
                }
                // Keep images and other attachments of RTFD sources.
                if hasAttachments, let rtfd = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
                   rtfd.count <= limit {
                    item[rtfdType] = rtfd
                }
            }
            // HTML-only sources (web pages, mail) merge as HTML. HTML import
            // needs the main thread, so the fragments are joined as text.
            if selected.contains(where: { $0.items.first?[htmlType] != nil }) {
                let html = mergedHTML(selected, separator: separator)
                if html.utf8.count <= limit { item[htmlType] = Data(html.utf8) }
            }
            return [item]
        }
        guard selected.reduce(0, { $0 + $1.byteCount }) <= 1_024 * 1_024 * 1_024 else { throw ClipboardStore.StoreError.tooLarge }
        return selected.flatMap(\.items)
    }

    static let rtfdType = "com.apple.flat-rtfd"
    static let htmlType = NSPasteboard.PasteboardType.html.rawValue

    private static func richTextData(_ entry: ClipboardEntry) -> (Data, NSAttributedString.DocumentType)? {
        if let rtf = entry.items.first?[NSPasteboard.PasteboardType.rtf.rawValue] { return (rtf, .rtf) }
        if let rtfd = entry.items.first?[rtfdType] { return (rtfd, .rtfd) }
        return nil
    }

    /// A rich form is used only when it says the same thing as the plain text;
    /// attachment characters and edge whitespace do not count.
    static func sameText(_ rich: String, _ plain: String) -> Bool {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean(rich) == clean(plain)
    }

    static func mergedHTML(_ selected: [ClipboardEntry], separator: String) -> String {
        let breakHTML = escapeHTML(separator).replacingOccurrences(of: "\n", with: "<br>")
        return selected.map { entry -> String in
            if let data = entry.items.first?[htmlType], let html = String(data: data, encoding: .utf8) { return html }
            return escapeHTML(entry.text ?? "").replacingOccurrences(of: "\n", with: "<br>")
        }.joined(separator: breakHTML)
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
