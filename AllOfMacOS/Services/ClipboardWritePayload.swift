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
            if selected.contains(where: { $0.items.first?[NSPasteboard.PasteboardType.rtf.rawValue] != nil }) {
                let attributed = NSMutableAttributedString(string: "")
                var hasRichText = false
                for (index, entry) in selected.enumerated() {
                    if index > 0 { attributed.append(NSAttributedString(string: separator)) }
                    if let data = entry.items.first?[NSPasteboard.PasteboardType.rtf.rawValue],
                       let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
                       rich.string == entry.text {
                        attributed.append(rich); hasRichText = true
                    } else { attributed.append(NSAttributedString(string: entry.text ?? "")) }
                }
                if hasRichText, let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), rtf.count <= limit {
                    item[NSPasteboard.PasteboardType.rtf.rawValue] = rtf
                }
            }
            return [item]
        }
        guard selected.reduce(0, { $0 + $1.byteCount }) <= 1_024 * 1_024 * 1_024 else { throw ClipboardStore.StoreError.tooLarge }
        return selected.flatMap(\.items)
    }
}
