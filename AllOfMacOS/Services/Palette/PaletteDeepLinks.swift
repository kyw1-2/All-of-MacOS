import AppKit
import ApplicationServices
import Foundation

/// A link to the item in front: a tab, a file, a message, a document or an app.
struct PaletteLink: Equatable {
    let title: String
    let url: URL
}

/// "Copy Link to Current Item" (Hookmark-lite) as text: Markdown, a plain
/// URL, and HTML / RTF hyperlinks for rich editors (Notes, Mail, Pages).
enum PaletteLinkFormat {
    enum Style: Equatable {
        /// Markdown as plain text, plus HTML, RTF and the URL types: a rich
        /// editor pastes the linked title, a plain one the Markdown.
        case rich
        /// "[title](url)" only.
        case markdown
        /// The URL only.
        case plainURL
    }

    /// `[title](url)`: brackets and backslashes in the title are escaped, line
    /// breaks become spaces; parentheses, spaces and angle brackets in the
    /// URL are percent-encoded so the link can't end early.
    static func markdown(_ link: PaletteLink) -> String {
        "[\(markdownText(link.title))](\(markdownDestination(link.url)))"
    }

    static func markdown(_ links: [PaletteLink]) -> String {
        links.map(markdown).joined(separator: "\n")
    }

    static func plain(_ links: [PaletteLink]) -> String {
        links.map(\.url.absoluteString).joined(separator: "\n")
    }

    static func html(_ links: [PaletteLink]) -> String {
        links.map { "<a href=\"\(htmlEscaped($0.url.absoluteString))\">\(htmlEscaped($0.title))</a>" }
            .joined(separator: "<br>")
    }

    /// RTF with a HYPERLINK field per link. Non-ASCII characters are
    /// written as \uN escapes, so Korean titles survive any reader.
    static func rtf(_ links: [PaletteLink]) -> Data {
        var body = ""
        for (index, link) in links.enumerated() {
            if index > 0 { body += "\\par\n" }
            body += "{\\field{\\*\\fldinst{HYPERLINK \"\(rtfEscaped(link.url.absoluteString, inQuotes: true))\"}}"
            body += "{\\fldrslt{\\ul \(rtfEscaped(link.title, inQuotes: false))}}}"
        }
        let document = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0 \(body)}"
        return Data(document.utf8)
    }

    static func markdownText(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", "[", "]": result += "\\\(character)"
            case "\n", "\r", "\r\n", "\t": result += " "
            default: result.append(character)
            }
        }
        return result
    }

    static func markdownDestination(_ url: URL) -> String {
        var result = ""
        for character in url.absoluteString {
            switch character {
            case "(": result += "%28"
            case ")": result += "%29"
            case " ": result += "%20"
            case "<": result += "%3C"
            case ">": result += "%3E"
            default: result.append(character)
            }
        }
        return result
    }

    static func htmlEscaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    static func rtfEscaped(_ text: String, inQuotes: Bool) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "\"" where inQuotes: result += "%22"
            case "\n", "\r": result += inQuotes ? "" : " "
            default:
                if scalar.value < 0x20 { continue }
                if scalar.isASCII {
                    result.unicodeScalars.append(scalar)
                } else {
                    // RTF \u takes a signed 16-bit value per UTF-16 unit, then a fallback "?".
                    for unit in String(scalar).utf16 { result += "\\u\(Int16(bitPattern: unit))?" }
                }
            }
        }
        return result
    }

    /// Puts the links on `pasteboard` in `style`. False when there was nothing to write.
    @discardableResult
    static func write(_ links: [PaletteLink], style: Style, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !links.isEmpty else { return false }
        pasteboard.clearContents()
        switch style {
        case .markdown:
            return pasteboard.setString(markdown(links), forType: .string)
        case .plainURL:
            let item = NSPasteboardItem()
            item.setString(plain(links), forType: .string)
            if links.count == 1 { item.setString(links[0].url.absoluteString, forType: .URL) }
            return pasteboard.writeObjects([item])
        case .rich:
            let item = NSPasteboardItem()
            item.setString(markdown(links), forType: .string)
            item.setString(html(links), forType: .html)
            item.setData(rtf(links), forType: .rtf)
            if links.count == 1 {
                item.setString(links[0].url.absoluteString, forType: .URL)
                item.setString(links[0].title, forType: NSPasteboard.PasteboardType("public.url-name"))
            }
            return pasteboard.writeObjects([item])
        }
    }

    /// Mail's own link form: message://%3C<Message-ID>%3E.
    static func mailMessageURL(messageID: String) -> URL? {
        var id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        guard !id.isEmpty else { return nil }
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~!$&'*+,;=@")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "message://%3C\(encoded)%3E")
    }
}

/// Where "Copy Link to Current Item" reads the item, by front app.
enum PaletteLinkSource: Equatable {
    /// Safari or a Chromium browser: the current tab.
    case browser(bundleID: String, safari: Bool)
    /// The Finder selection (or the front window's folder).
    case finder
    /// The selected messages.
    case mail
    /// The front window's document (AXDocument), else the app.
    case documentOrApp

    static let chromiumScriptable: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                                                  "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
                                                  "com.naver.Whale", "company.thebrowser.Browser", "org.chromium.Chromium"]

    static func source(for bundleID: String?) -> PaletteLinkSource {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return .browser(bundleID: bundleID ?? "", safari: true)
        case "com.apple.finder": return .finder
        case "com.apple.mail": return .mail
        case let id? where chromiumScriptable.contains(id): return .browser(bundleID: id, safari: false)
        default: return .documentOrApp
        }
    }

    /// The AppleScript that returns the item, one per line, title and URL
    /// separated by U+001F. Only bundle ids from the fixed lists above are
    /// ever placed in a script.
    var script: String? {
        switch self {
        case .browser(let bundleID, let safari):
            let tab = safari ? "current tab" : "active tab"
            let title = safari ? "name" : "title"
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set theTab to \(tab) of front window
                return (\(title) of theTab) & (character id 31) & (URL of theTab)
            end tell
            """
        case .finder:
            return """
            tell application id "com.apple.finder"
                set theItems to selection as alias list
                if theItems is {} then
                    if (count of Finder windows) is 0 then return ""
                    set theItems to {(target of front Finder window) as alias}
                end if
                set out to ""
                repeat with anItem in theItems
                    set out to out & (POSIX path of anItem) & linefeed
                end repeat
                return out
            end tell
            """
        case .mail:
            return """
            tell application id "com.apple.mail"
                set theMessages to selection
                if theMessages is {} then return ""
                set out to ""
                repeat with aMessage in theMessages
                    set out to out & (subject of aMessage) & (character id 31) & (message id of aMessage) & linefeed
                end repeat
                return out
            end tell
            """
        case .documentOrApp:
            return nil
        }
    }

    /// Reads the script's answer.
    func links(fromScriptOutput output: String) -> [PaletteLink] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        switch self {
        case .browser:
            return lines.compactMap { line in
                let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let url = URL(string: parts[1].trimmingCharacters(in: .whitespaces)),
                      url.scheme != nil else { return nil }
                let title = parts[0].trimmingCharacters(in: .whitespaces)
                return PaletteLink(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url)
            }
        case .finder:
            return lines.map { path in
                let url = URL(fileURLWithPath: path)
                let name = FileManager.default.displayName(atPath: path)
                return PaletteLink(title: name.isEmpty ? url.lastPathComponent : name, url: url)
            }
        case .mail:
            return lines.compactMap { line in
                let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let url = PaletteLinkFormat.mailMessageURL(messageID: parts[1]) else { return nil }
                let subject = parts[0].trimmingCharacters(in: .whitespaces)
                return PaletteLink(title: subject.isEmpty ? "Message" : subject, url: url)
            }
        case .documentOrApp:
            return []
        }
    }
}

/// Reads the current item of an app: Apple events for browsers, Finder and
/// Mail (one `osascript` run with a timeout), Accessibility for documents,
/// the app itself otherwise. Never on the main thread.
enum PaletteLinkResolver {
    struct Outcome {
        let links: [PaletteLink]
        /// Why the preferred source failed and a fallback was used, if it did.
        let note: String?
    }

    static func resolve(pid: pid_t, bundleID: String?, appName: String, appURL: URL?) async -> Outcome {
        let source = PaletteLinkSource.source(for: bundleID)
        var note: String?
        if let script = source.script {
            let output = await PaletteProcess.run("/usr/bin/osascript", arguments: ["-e", script], timeout: 5)
            if output.status == 0 {
                let links = source.links(fromScriptOutput: output.standardOutput)
                if !links.isEmpty { return Outcome(links: links, note: nil) }
                note = "\(appName) has nothing selected"
            } else if output.standardError.contains("-1743") {
                note = "All of MacOS isn't allowed to control \(appName) (System Settings › Privacy & Security › Automation)"
            } else if output.timedOut {
                note = "\(appName) didn't answer in time"
            } else {
                note = "\(appName) didn't return the item"
            }
        }
        if let document = documentLink(pid: pid) { return Outcome(links: [document], note: note) }
        guard let appURL else { return Outcome(links: [], note: note) }
        return Outcome(links: [PaletteLink(title: appName, url: appURL)], note: note)
    }

    /// The focused (or main) window's AXDocument, titled by the window.
    static func documentLink(pid: pid_t) -> PaletteLink? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        guard let window = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, 0.4)
        guard let raw = string(window, kAXDocumentAttribute), let url = URL(string: raw), url.scheme != nil else { return nil }
        let title = string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
            ?? (url.isFileURL ? url.lastPathComponent : url.absoluteString)
        return PaletteLink(title: title, url: url)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
