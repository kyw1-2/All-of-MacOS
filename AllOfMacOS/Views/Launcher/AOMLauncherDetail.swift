import AppKit
import SwiftUI

// AOM 7.0: the launcher's split preview (Raycast's List detail). Clipboard
// History shows the selected clip as its Paste card with what it is, where
// it came from and when; Window Management shows where the layout puts the
// front window on a miniature screen.

/// The selected clip, large, with its facts under it.
struct AOMLauncherClipDetail: View {
    let entry: ClipboardEntry
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            AOMPasteCraftCard(model: model, isSelected: false, showsQuickBadge: false)
                .padding(.top, 16)
            VStack(spacing: 0) {
                fact("Type", entry.kind.displayName)
                fact("From", entry.sourceName ?? "Unknown app")
                fact("Copied", AOMRelativeTime.string(entry.lastCopiedAt))
                if let text = entry.text, entry.kind == .text || entry.kind == .link {
                    fact(entry.kind == .link ? "Address" : "Length",
                         entry.kind == .link ? (URL(string: text)?.host ?? text) : "\(text.count.formatted()) characters")
                }
                if entry.kind == .file { fact("Items", "\(entry.fileURLs.count)") }
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.contentVersion) {
            guard let data = entry.imageData else { image = nil; return }
            image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(AOMCraftColor.inkSecondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(AOMCraftColor.ink).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .frame(height: 26)
        .overlay(alignment: .bottom) { Rectangle().fill(AOMCraftColor.hairline).frame(height: 0.5) }
    }

    private var model: AOMPasteCardModel {
        let metadata = AppMetadataCache.shared
        return AOMPasteCardModel(id: entry.id,
                                 headerTitle: entry.kind == .text || entry.kind == .link ? entry.kind.displayName : entry.title,
                                 relativeTime: AOMRelativeTime.string(entry.lastCopiedAt),
                                 sourceColor: metadata.bannerColor(for: entry.sourceBundleID, name: entry.sourceName),
                                 sourceAppIcon: metadata.icon(for: entry.sourceBundleID),
                                 content: content, quickIndex: nil)
    }

    private var content: AOMPasteCardModel.ContentKind {
        switch entry.kind {
        case .text:
            let text = entry.previewText
            if Self.looksLikeCode(text) { return .code(snippet: text, language: "Code") }
            return .text(body: text, charCount: entry.text?.count ?? text.count)
        case .link:
            let address = entry.text ?? entry.title
            return .link(title: entry.title, host: URL(string: address)?.host ?? "Link", urlString: address)
        case .image:
            let picture = image ?? NSImage(size: NSSize(width: 1, height: 1))
            let size = image?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
            return .image(nsImage: picture, width: Int(size.width), height: Int(size.height), format: "Image",
                          ocrSnippet: entry.recognizedText.map { String($0.prefix(60)) })
        case .color:
            let hex = entry.text ?? entry.title
            return .color(hex: hex, nsColor: ClipboardColorEditor.color(hex) ?? .gray)
        case .file:
            let urls = entry.fileURLs
            let folder = urls.first.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? ""
            return .files(names: urls.map(\.lastPathComponent), folderPath: folder,
                          icon: urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
    }

    /// Pure: a clip with code's shape (braces, semicolons, indentation).
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20)
        guard lines.count >= 2 else { return false }
        let signals = lines.filter { line in
            line.hasPrefix("    ") || line.hasPrefix("\t") || line.hasSuffix("{") || line.hasSuffix(";")
                || line.hasSuffix("}") || line.contains("func ") || line.contains("def ") || line.contains("=>")
        }.count
        return signals * 2 >= lines.count
    }
}

/// Where a Window Management row puts the front window.
struct AOMLauncherWindowDetail: View {
    let layoutID: String
    let title: String
    let shortcut: String?

    var body: some View {
        if let rect = Self.target(for: layoutID) {
            AOMWindowLayoutMiniPreview(normalizedTarget: rect, title: title, shortcut: shortcut)
        } else {
            VStack(spacing: 10) {
                Image(systemName: layoutID.contains("pin") || layoutID.contains("Pin") ? "pin.circle" : "rectangle.stack")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AOMCraftColor.inkTertiary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AOMCraftColor.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Pure: the layout as a fraction of the screen, origin top-left.
    static func target(for id: String) -> CGRect? {
        let third = 1.0 / 3.0
        switch id.replacingOccurrences(of: "window.", with: "") {
        case "left": return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case "right": return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case "maximize": return CGRect(x: 0, y: 0, width: 1, height: 1)
        case "topHalf": return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case "bottomHalf": return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case "topLeft": return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case "topRight": return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case "bottomLeft": return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case "bottomRight": return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case "leftThird": return CGRect(x: 0, y: 0, width: third, height: 1)
        case "centerThird": return CGRect(x: third, y: 0, width: third, height: 1)
        case "rightThird": return CGRect(x: 2 * third, y: 0, width: third, height: 1)
        case "leftTwoThirds": return CGRect(x: 0, y: 0, width: 2 * third, height: 1)
        case "rightTwoThirds": return CGRect(x: third, y: 0, width: 2 * third, height: 1)
        case "center": return CGRect(x: 0.15, y: 0.12, width: 0.7, height: 0.76)
        default: return nil
        }
    }
}

/// 7.2: the detail of any other row — an emoji large, a file's icon, a
/// person, an event, a snippet's text, a Homebrew package — with its facts.
struct AOMLauncherInfo {
    var title: String
    var symbol: String?
    var glyph: String?
    var image: NSImage?
    /// Longer text under the title (a snippet, a package's summary).
    var body: String?
    var fields: [(String, String)] = []

    init(title: String, symbol: String? = nil, glyph: String? = nil, image: NSImage? = nil, body: String? = nil,
         fields: [(String, String)] = []) {
        self.title = title
        self.symbol = symbol
        self.glyph = glyph
        self.image = image
        self.body = body
        self.fields = fields
    }
}

struct AOMLauncherInfoDetail: View {
    let info: AOMLauncherInfo

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Group {
                if let glyph = info.glyph {
                    Text(glyph).font(.system(size: 96)).frame(height: 120)
                } else if let image = info.image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 84, height: 84)
                } else if let symbol = info.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 84, height: 84)
                        .background(AOMCraftColor.rowHover, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.top, 18)
            .accessibilityHidden(true)
            Text(info.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AOMCraftColor.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 18)
            if let body = info.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(AOMCraftColor.rowHover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 18)
            }
            VStack(spacing: 0) {
                ForEach(Array(info.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.0).foregroundStyle(AOMCraftColor.inkSecondary)
                        Spacer(minLength: 12)
                        Text(field.1).foregroundStyle(AOMCraftColor.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .font(.system(size: 12))
                    .frame(minHeight: 26)
                    .overlay(alignment: .bottom) { Rectangle().fill(AOMCraftColor.hairline).frame(height: 0.5) }
                }
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
