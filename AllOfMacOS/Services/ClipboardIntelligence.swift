import AppKit
import ApplicationServices
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// Intelligent Clipboard — local, on-device "what will I paste next" suggestions.
//
// Modelled on Paste 7.0.2's PastePicks (REA/strings evidence, 2026-10-17):
//   • every copied text is classified (link, email, phone, date, address,
//     money, tracking number, person / organisation name, code, secret …);
//   • the destination is classified into an input kind (search, password,
//     chat, code, terminal, cell, canvas, text) — Paste asks an on-device
//     model about a screenshot of the destination window;
//   • a paste log (source app → destination app, item class, field kind)
//     teaches which clips go where.
// AOM reads the focused element through Accessibility first (instant, no
// screenshot), and only when that is inconclusive and the user opted in,
// asks Apple's on-device model about a downscaled screenshot of the
// destination window. Nothing leaves the Mac.

enum ClipboardItemClass: String, Codable, CaseIterable {
    case unclassified, link, email, phone, date, address, money, trackingNumber
    case personName, organizationName, code, path, secret, other
}

enum ClipboardDestinationKind: String, Codable, CaseIterable {
    case search, password, chat, code, terminal, cell, canvas, text, unknown
}

struct ClipboardDestinationContext: Equatable {
    var bundleID: String?
    var appName: String?
    var windowTitle: String?
    var kind: ClipboardDestinationKind = .unknown
    var isSecureInput = false
    /// Placeholder / label / description of the focused field, lower-cased.
    var fieldHint = ""
    var source: Source = .none
    enum Source: String { case none, accessibility, appCategory, model }
}

// MARK: - Item classification

enum ClipboardItemClassifier {
    // Secret patterns (JWT, provider keys, inline credentials, auth headers).
    private static let secretPatterns: [NSRegularExpression] = [
        #"eyJ[A-Za-z0-9_-]{7,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        #"sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}"#,
        #"(?i)(?:^|[^a-z])(?:pass(?:word|wd|code)?|pwd|secret|token|api[_-]?key|private[_-]?key|client[_-]?secret)\s*[:=]\s*\S"#,
        #"\bBearer [A-Za-z0-9._~+/=-]{20,}|\bBasic [A-Za-z0-9+/=]{8,}"#,
        #"-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let tracking = try! NSRegularExpression(pattern: #"^(?:1Z[A-Z0-9]{16}|\d{20,22}|\d{15}|\d{12}|\d{10}|[A-Z]{2}\d{9}[A-Z]{2})$"#)
    private static let money = try! NSRegularExpression(pattern: #"^(?:\p{Sc}\s?\d[\d,.\s]*|\d[\d,.\s]*\s?(?:\p{Sc}|[A-Z]{3}|원|円|元))$"#)
    private static let path = try! NSRegularExpression(pattern: #"^(?:~|/)[^\s]*(?:/[^\s]+)+$|^[A-Za-z]:\\\S+$"#)
    private static let password = try! NSRegularExpression(pattern: #"^(?=.*[A-Za-z])(?=.*\d)(?=.*[^A-Za-z\d\s])\S{12,64}$"#)

    static func classify(_ entry: ClipboardEntry) -> ClipboardItemClass {
        switch entry.kind {
        case .link: return .link
        case .file: return .path
        case .image, .color: return .other
        case .text: break
        }
        return classify(text: entry.text ?? "")
    }

    static func classify(text raw: String) -> ClipboardItemClass {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unclassified }
        let whole = NSRange(text.startIndex..., in: text)
        if secretPatterns.contains(where: { $0.firstMatch(in: text, range: whole) != nil })
            || (!text.contains(" ") && password.firstMatch(in: text, range: whole) != nil) {
            return .secret
        }
        let singleLine = !text.contains("\n")
        if singleLine && text.count <= 2_048, let detected = detectorClass(text) { return detected }
        if singleLine, tracking.firstMatch(in: text, range: whole) != nil { return .trackingNumber }
        if singleLine, money.firstMatch(in: text, range: whole) != nil { return .money }
        if singleLine, path.firstMatch(in: text, range: whole) != nil { return .path }
        if looksLikeCode(text) { return .code }
        if singleLine, text.count <= 60, let name = nameClass(text) { return name }
        return text.count < 3 ? .other : .unclassified
    }

    /// NSDataDetector types, only when the match covers the whole text.
    private static func detectorClass(_ text: String) -> ClipboardItemClass? {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .date, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              match.range.length >= range.length - 1 else { return nil }
        switch match.resultType {
        case .link:
            return match.url?.scheme == "mailto" || (text.contains("@") && !text.contains("/")) ? .email : .link
        case .phoneNumber: return .phone
        case .date: return .date
        case .address: return .address
        default: return nil
        }
    }

    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        let signals = [";", "{", "}", "()", "=>", "->", "==", "!=", "&&", "||", "func ", "let ", "var ", "const ",
                       "def ", "import ", "return ", "class ", "#include", "</", "/>", "$ ", "sudo ", "git ", "npm ",
                       "swift ", "brew ", "cd ", "ls ", "--"]
        let hits = signals.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        return hits >= 2 || (lines.count > 2 && indented * 3 >= lines.count) ||
            (lines.count == 1 && hits >= 1 && text.count < 200 && text.first.map { !$0.isUppercase } == true)
    }

    private static func nameClass(_ text: String) -> ClipboardItemClass? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var person = 0, org = 0, words = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            words += 1
            if tag == .personalName { person += 1 } else if tag == .organizationName { org += 1 }
            return true
        }
        guard words > 0, words <= 6 else { return nil }
        if person > 0 && person >= org { return .personName }
        if org > 0 { return .organizationName }
        return nil
    }
}

// MARK: - Destination context

enum ClipboardDestinationReader {
    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                                 "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty",
                                                 "co.zeit.hyper", "com.github.wez.wezterm"]
    private static let editors: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                                               "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm",
                                               "com.panic.Nova", "dev.zed.Zed", "com.exafunction.windsurf", "com.barebones.bbedit"]
    private static let chats: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
                                             "com.kakao.KakaoTalkMac", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
                                             "com.microsoft.teams2", "jp.naver.line.mac", "com.facebook.archon"]
    private static let sheets: Set<String> = ["com.apple.iWork.Numbers", "com.microsoft.Excel"]
    private static let canvases: Set<String> = ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.apple.Keynote",
                                                "com.apple.freeform", "com.adobe.Photoshop", "com.pixelmatorteam.pixelmator.x"]

    /// The focused element of `app`, classified from its AX role/subrole and
    /// labels, falling back to the app's category.
    @MainActor
    static func read(app: NSRunningApplication?) -> ClipboardDestinationContext {
        var context = ClipboardDestinationContext(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        guard let app, !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return context }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        if let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) {
            context.windowTitle = attribute(window, kAXTitleAttribute)
        }
        if AXIsProcessTrusted(), let focused: AXUIElement = attribute(element, kAXFocusedUIElementAttribute) {
            let role: String = attribute(focused, kAXRoleAttribute) ?? ""
            let subrole: String = attribute(focused, kAXSubroleAttribute) ?? ""
            let hints = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, "AXLabel"]
                .compactMap { attribute(focused, $0) as String? }
            context.fieldHint = hints.joined(separator: " ").lowercased()
            context.isSecureInput = subrole == (kAXSecureTextFieldSubrole as String)
            context.kind = kind(role: role, subrole: subrole, hint: context.fieldHint, bundleID: context.bundleID)
            if context.kind != .unknown { context.source = .accessibility }
        }
        if context.kind == .unknown || context.kind == .text, let category = category(context.bundleID) {
            context.kind = category
            context.source = .appCategory
        }
        return context
    }

    static func kind(role: String, subrole: String, hint: String, bundleID: String?) -> ClipboardDestinationKind {
        if subrole == (kAXSecureTextFieldSubrole as String) { return .password }
        if subrole == (kAXSearchFieldSubrole as String) || hint.contains("search") || hint.contains("검색") { return .search }
        if hint.contains("password") || hint.contains("비밀번호") { return .password }
        if let bundleID, terminals.contains(bundleID) { return .terminal }
        if let bundleID, editors.contains(bundleID), role == (kAXTextAreaRole as String) { return .code }
        if role == "AXCell" || (bundleID.map(sheets.contains) ?? false) { return .cell }
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) || role == (kAXComboBoxRole as String)
            || role == "AXWebArea" { return .text }
        return .unknown
    }

    static func category(_ bundleID: String?) -> ClipboardDestinationKind? {
        guard let bundleID else { return nil }
        if terminals.contains(bundleID) { return .terminal }
        if editors.contains(bundleID) { return .code }
        if chats.contains(bundleID) { return .chat }
        if sheets.contains(bundleID) { return .cell }
        if canvases.contains(bundleID) { return .canvas }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}

// MARK: - Paste log

struct ClipboardPasteEvent: Codable, Equatable {
    var entryID: UUID
    var itemClass: ClipboardItemClass
    var sourceBundleID: String?
    var destinationBundleID: String?
    var destinationKind: ClipboardDestinationKind
    var date: Date
}

/// Local, capped log of what was pasted where (JSON next to the clipboard
/// store, so tests and previews stay isolated with it).
@MainActor
final class ClipboardPasteLog {
    static let limit = 2_000
    private(set) var events: [ClipboardPasteEvent] = []
    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("paste-events.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ClipboardPasteEvent].self, from: data) {
            events = Array(decoded.suffix(Self.limit))
        }
    }

    func record(_ event: ClipboardPasteEvent) {
        events.append(event)
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        let snapshot = events, url = url
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func erase() {
        events.removeAll()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Ranking

enum ClipboardSuggestionRanker {
    static let maximumSuggestions = 3
    static let threshold = 0.75

    /// How well an item class fits a destination kind (0…1).
    static func fit(_ item: ClipboardItemClass, _ kind: ClipboardDestinationKind, hint: String) -> Double {
        let hinted: [(keys: [String], cls: ClipboardItemClass)] = [
            (["email", "e-mail", "이메일"], .email), (["phone", "tel", "mobile", "전화", "휴대"], .phone),
            (["address", "street", "주소"], .address), (["url", "link", "website", "링크"], .link),
            (["name", "이름", "성명"], .personName), (["company", "organization", "회사"], .organizationName),
            (["tracking", "운송장", "송장"], .trackingNumber), (["amount", "price", "금액", "가격"], .money),
            (["date", "날짜", "birthday", "생년"], .date),
        ]
        if !hint.isEmpty, hinted.contains(where: { $0.cls == item && $0.keys.contains(where: hint.contains) }) { return 1 }
        switch (kind, item) {
        case (.password, .secret): return 1
        case (.password, _), (_, .secret): return 0
        case (.code, .code), (.terminal, .code), (.terminal, .path): return 0.9
        case (.code, .path): return 0.6
        case (.cell, .money), (.cell, .date), (.cell, .phone), (.cell, .trackingNumber): return 0.7
        case (.search, .link), (.search, .trackingNumber), (.search, .personName), (.search, .organizationName): return 0.55
        case (.chat, .link), (.chat, .unclassified): return 0.45
        case (.text, .address), (.text, .email), (.text, .personName), (.text, .phone): return 0.35
        case (.canvas, .other): return 0.5
        default: return 0
        }
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init).prefix(200))
    }

    /// Up to three entry IDs, best first. Secrets are only ever suggested for
    /// password fields; nothing older than 30 days unless the user pasted it
    /// into this app before.
    static func rank(_ entries: [ClipboardEntry], context: ClipboardDestinationContext,
                     events: [ClipboardPasteEvent], classes: (ClipboardEntry) -> ClipboardItemClass,
                     now: Date = Date()) -> [UUID] {
        guard context.bundleID != nil || context.kind != .unknown else { return [] }
        let destination = context.bundleID
        let here = events.filter { destination != nil && $0.destinationBundleID == destination }
        var pastedHere: [UUID: Double] = [:]
        var classShare: [ClipboardItemClass: Double] = [:]
        for event in here {
            let decay = exp(-now.timeIntervalSince(event.date) / (7 * 86_400))
            pastedHere[event.entryID, default: 0] += decay
            classShare[event.itemClass, default: 0] += 1
        }
        let classTotal = max(1, classShare.values.reduce(0, +))
        let titleTokens = tokens(context.windowTitle ?? "")
        var scored: [(UUID, Double)] = []
        for entry in entries.prefix(400) {
            let cls = classes(entry)
            let age = now.timeIntervalSince(entry.lastCopiedAt)
            let history = min(1.5, pastedHere[entry.id] ?? 0)
            if age > 30 * 86_400 && history == 0 { continue }
            if cls == .secret && context.kind != .password { continue }
            if context.kind == .password && cls != .secret && history == 0 { continue }
            var score = 1.2 * fit(cls, context.kind, hint: context.fieldHint)
            score += 0.9 * history
            score += 0.5 * (classShare[cls] ?? 0) / classTotal
            if !titleTokens.isEmpty, let text = entry.text {
                let overlap = tokens(text).intersection(titleTokens).count
                score += min(0.5, Double(overlap) * 0.2)
            }
            score += 0.35 * exp(-age / 3_600)
            if entry.sourceBundleID != nil, entry.sourceBundleID == destination { score -= 0.25 }
            if score >= threshold { scored.append((entry.id, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(maximumSuggestions).map(\.0)
    }
}

// MARK: - Coordinator

@MainActor
final class ClipboardIntelligence {
    static let shared = ClipboardIntelligence()

    static let enabledKey = "AOMIntelligentClipboardEnabled"
    static let readsScreenKey = "AOMIntelligentClipboardReadsScreen"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    /// Opt-in: let the on-device model look at the destination window.
    var readsDestinationScreen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.readsScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.readsScreenKey) }
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private var classCache: [UUID: (digest: Int, value: ClipboardItemClass)] = [:]
    private var logs: [ObjectIdentifier: ClipboardPasteLog] = [:]
    private(set) var lastContext = ClipboardDestinationContext()

    func log(for store: ClipboardStore) -> ClipboardPasteLog {
        let key = ObjectIdentifier(store)
        if let log = logs[key] { return log }
        let log = ClipboardPasteLog(directory: store.directory)
        logs[key] = log
        return log
    }

    func itemClass(_ entry: ClipboardEntry) -> ClipboardItemClass {
        let digest = (entry.text ?? entry.title).hashValue ^ entry.kind.hashValue
        if let cached = classCache[entry.id], cached.digest == digest { return cached.value }
        let value = ClipboardItemClassifier.classify(entry)
        classCache[entry.id] = (digest, value)
        return value
    }

    /// Instant suggestions from Accessibility + history; `update` is called
    /// again if the on-device model refines the destination kind.
    func suggestions(for destination: NSRunningApplication?, store: ClipboardStore,
                     update: @escaping @MainActor ([UUID]) -> Void) -> [UUID] {
        guard isEnabled else { lastContext = .init(); return [] }
        let context = ClipboardDestinationReader.read(app: destination)
        lastContext = context
        let entries = store.entries
        let events = log(for: store).events
        let initial = ClipboardSuggestionRanker.rank(entries, context: context, events: events, classes: itemClass)
        if readsDestinationScreen, context.kind == .unknown || context.source == .appCategory,
           Self.modelAvailable, ScreenCaptureService.hasPermission, !PresetManager.isUIPreview {
            Task { @MainActor [weak self] in
                guard let self, let kind = await Self.modelDestinationKind(), kind != .unknown else { return }
                var refined = context
                refined.kind = kind
                refined.source = .model
                self.lastContext = refined
                update(ClipboardSuggestionRanker.rank(store.entries, context: refined,
                                                      events: self.log(for: store).events, classes: self.itemClass))
            }
        }
        return initial
    }

    func recordPaste(entryIDs: [UUID], destination: NSRunningApplication?, store: ClipboardStore) {
        guard isEnabled, let destination, !PresetManager.isUIPreview else { return }
        let log = log(for: store)
        for id in entryIDs.prefix(20) {
            guard let entry = store.entries.first(where: { $0.id == id }) else { continue }
            let cls = itemClass(entry)
            guard cls != .secret else { continue }  // never log where secrets go
            log.record(.init(entryID: id, itemClass: cls, sourceBundleID: entry.sourceBundleID,
                             destinationBundleID: destination.bundleIdentifier,
                             destinationKind: lastContext.bundleID == destination.bundleIdentifier ? lastContext.kind : .unknown,
                             date: Date()))
        }
    }

    // MARK: On-device model (Apple Intelligence)

    private static func modelDestinationKind() async -> ClipboardDestinationKind? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            guard let window = try? await ScreenCaptureService.shared.frontmostCapturableWindow(),
                  let shot = try? await ScreenCaptureService.shared.captureWindow(window),
                  let image = downscaled(shot.image, maxSide: 1_024) else { return nil }
            return try? await ScreenCaptureService.withDeadline(seconds: 4) {
                let session = LanguageModelSession(instructions: """
                    You are shown a screenshot of the window a person is about to paste text into. \
                    It is not the frontmost window, so it may draw no text cursor or focus ring. \
                    Answer with the kind of input the pasted text is most likely headed for, judging from \
                    what the window is for and how it is laid out. Answer unknown when it is not clear.
                    """)
                let response = try await session.respond(generating: DestinationKindAnswer.self) {
                    "Which kind of input is the pasted text most likely headed for?"
                    Attachment(image)
                }
                return ClipboardDestinationKind(rawValue: response.content.kind.rawValue) ?? .unknown
            }
        }
        #endif
        return nil
    }

    private static func downscaled(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// Refines `unclassified` texts with the on-device model, in the
    /// background, a few recent items at a time.
    func refineClassesWithModel(_ entries: [ClipboardEntry]) {
        #if canImport(FoundationModels)
        guard isEnabled, Self.modelAvailable, !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        if #available(macOS 26.0, *) {
            let pending = entries.prefix(30).filter { itemClass($0) == .unclassified && ($0.text?.count ?? 0) < 600 }.prefix(6)
            guard !pending.isEmpty else { return }
            Task { @MainActor [weak self] in
                let session = LanguageModelSession(instructions: """
                    Classify the kind of text a person copied to their clipboard. Answer with the single best category. \
                    Use secret for passwords, API keys, tokens and private keys. Use other when unsure.
                    """)
                for entry in pending {
                    guard let text = entry.text,
                          let answer = try? await session.respond(to: text, generating: ItemClassAnswer.self),
                          let value = ClipboardItemClass(rawValue: answer.content.category.rawValue) else { continue }
                    let digest = text.hashValue ^ entry.kind.hashValue
                    self?.classCache[entry.id] = (digest, value)
                }
            }
        }
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct DestinationKindAnswer {
    @Generable enum Kind: String { case search, password, chat, code, terminal, cell, canvas, text, unknown }
    @Guide(description: "The kind of input the pasted text is most likely headed for.")
    var kind: Kind
}

@available(macOS 26.0, *)
@Generable
struct ItemClassAnswer {
    @Generable enum Category: String {
        case link, email, phone, date, address, money, trackingNumber, personName, organizationName, code, path, secret, other
    }
    @Guide(description: "The single best category for the copied text.")
    var category: Category
}
#endif
