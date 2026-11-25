import Foundation
import PDFKit
import Vision

/// 7.12 (Codex NEW-2, Hazel's content conditions): what a PDF's first page
/// says, for a rule that asks. Read on the Folder Rules queue, one document
/// at a time; the text is never written to disk or logged (history keeps
/// only the verdict). 7.13 (GPT F10): it is kept in memory only briefly —
/// at most 64 pages, 4 MB and 10 minutes — so change notices for the same
/// file read it once.
struct FolderRulePDFContent: Equatable {
    enum State: String, Equatable {
        /// The page's text is in `text` (from its text layer, or recognized).
        case read
        /// Password protected: nothing can be read.
        case locked
        /// No text layer and the rule doesn't recognize scans.
        case noText
        /// The scan was recognized but nothing came out (or Vision failed).
        case recognitionFailed
        /// Not a PDF PDFKit can open, or no permission to read it.
        case unreadable
    }

    var state: State
    var text = ""
    var recognized = false

    var readText: String? { state == .read ? text : nil }

    /// Why a rule can't decide this PDF, in the history's words.
    var reviewReason: String? {
        switch state {
        case .read: return nil
        case .locked: return "the PDF is password protected"
        case .noText: return "its first page has no text (turn on “Recognize scanned PDFs” for this rule)"
        case .recognitionFailed: return "no text could be recognized on its first page"
        case .unreadable: return "the PDF couldn't be opened or read"
        }
    }
}

enum FolderRulePDFText {
    private static let numericDateRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})\s*일?(?!\d)"#)
    private static let englishDateRegex = try! NSRegularExpression(pattern: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b"#)
    private static let dayFirstDateRegex = try! NSRegularExpression(pattern: #"(?i)\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(\d{4})\b"#)
    /// Recognitions done since launch (tests check a text PDF needs none).
    nonisolated(unsafe) static var recognitionCount = 0
    private static let lock = NSLock()
    /// One entry per file version (volume, inode, modification, size, OCR):
    /// three change notices for the same file read it once.
    nonisolated(unsafe) private static var cache: [String: (content: FolderRulePDFContent, at: TimeInterval)] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static var cachedBytes = 0
    static let cacheLimit = (entries: 64, bytes: 4 << 20, seconds: 600.0)

    static func read(_ info: FolderRuleFileInfo, recognizesScans: Bool) -> FolderRulePDFContent {
        let key = "\(info.device):\(info.inode):\(info.dateModified?.timeIntervalSince1970 ?? 0):\(info.size):\(recognizesScans)"
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // 7.14 (Codex 7.13): expired pages go on every read, not only when evicted.
        evictExpired(now: now)
        if let cached = cache[key] { lock.unlock(); return cached.content }
        let started = cacheGeneration
        lock.unlock()
        let content = readUncached(info.url, recognizesScans: recognizesScans)
        lock.lock()
        // Folder Rules stopped while this page was read: it isn't kept.
        guard started == cacheGeneration else { lock.unlock(); return content }
        if let old = cache[key] { cachedBytes -= old.content.text.utf8.count; order.removeAll { $0 == key } }
        // Timestamp at insertion, under the lock: concurrent OCR reads may finish out of order.
        let insertedAt = ProcessInfo.processInfo.systemUptime
        cache[key] = (content, insertedAt)
        cachedBytes += content.text.utf8.count
        order.append(key)
        while !order.isEmpty, order.count > cacheLimit.entries || cachedBytes > cacheLimit.bytes {
            let oldest = order.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.content.text.utf8.count ?? 0
        }
        lock.unlock()
        // Nothing read for 10 minutes: the last pages go then too.
        scheduleExpiry()
        return content
    }

    /// Call with `lock` held. `order` is oldest first, so expired pages lead.
    private static func evictExpired(now: TimeInterval) {
        while let oldest = order.first, now - (cache[oldest]?.at ?? 0) >= cacheLimit.seconds {
            order.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.content.text.utf8.count ?? 0
        }
    }

    nonisolated(unsafe) private static var cacheGeneration = 0
    nonisolated(unsafe) private static var expiryScheduled = false

    /// 7.16 (GPT V16): one pending sweep, timed for the oldest page's own
    /// expiry (not ten minutes after the first insert), so no page outlives
    /// its ten minutes by more than a second.
    private static func scheduleExpiry() {
        lock.lock()
        guard !expiryScheduled, let oldest = order.first, let at = cache[oldest]?.at else { lock.unlock(); return }
        expiryScheduled = true
        let delay = max(1, at + cacheLimit.seconds - ProcessInfo.processInfo.systemUptime + 0.5)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            lock.lock()
            expiryScheduled = false
            evictExpired(now: ProcessInfo.processInfo.systemUptime)
            let more = !cache.isEmpty
            lock.unlock()
            if more { scheduleExpiry() }
        }
    }

    /// Entries held now (tests).
    static var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// Forgets every page read (a rule turned off, the module stopped).
    static func clearCache() {
        lock.lock()
        cache = [:]; order = []; cachedBytes = 0
        cacheGeneration &+= 1
        lock.unlock()
    }

    static func readUncached(_ url: URL, recognizesScans: Bool) -> FolderRulePDFContent {
        guard FileManager.default.isReadableFile(atPath: url.path), let document = PDFDocument(url: url) else {
            return FolderRulePDFContent(state: .unreadable)
        }
        if document.isLocked { return FolderRulePDFContent(state: .locked) }
        guard let page = document.page(at: 0) else { return FolderRulePDFContent(state: .unreadable) }
        let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !layer.isEmpty { return FolderRulePDFContent(state: .read, text: layer) }
        guard recognizesScans else { return FolderRulePDFContent(state: .noText) }
        lock.lock(); recognitionCount += 1; lock.unlock()
        guard let image = render(page) else { return FolderRulePDFContent(state: .recognitionFailed) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return FolderRulePDFContent(state: .recognitionFailed)
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? FolderRulePDFContent(state: .recognitionFailed)
            : FolderRulePDFContent(state: .read, text: text, recognized: true)
    }

    /// The page at about 200 dpi, white behind it (scans are often transparent).
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(200.0 / 72.0, 4000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: Pure helpers (tests run on strings)

    /// NFC, one space between words, so "청구서" typed in the editor matches
    /// a decomposed or line-broken one from the PDF.
    static func searchable(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The text after `label` on its line ("공급자: 한빛상사" → "한빛상사").
    /// Nil when the label isn't there or nothing follows it.
    static func value(after label: String, in text: String) -> String? {
        let wanted = searchable(label)
        guard !wanted.isEmpty else { return nil }
        for line in text.precomposedStringWithCanonicalMapping.components(separatedBy: .newlines) {
            let flat = searchable(line)
            guard let range = flat.range(of: wanted, options: [.caseInsensitive]) else { continue }
            var rest = flat[range.upperBound...].trimmingCharacters(in: .whitespaces)
            while let first = rest.first, ":：-–=·|".contains(first) { rest.removeFirst(); rest = rest.trimmingCharacters(in: .whitespaces) }
            if !rest.isEmpty { return String(rest.prefix(80)) }
        }
        return nil
    }

    /// Every date written on the page: 2026-11-03, 2026.11.3, 2026/11/03,
    /// 2026년 11월 3일, Nov 3, 2026 and 3 November 2026 — distinct days, in order.
    static func dates(in text: String) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var found: [(Int, Date)] = []
        func add(_ year: Int, _ month: Int, _ day: Int, at offset: Int) {
            guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day else { return }
            found.append((offset, date))
        }
        let ns = text as NSString
        let numeric = numericDateRegex
        for match in numeric.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            add(Int(ns.substring(with: match.range(at: 1))) ?? 0, Int(ns.substring(with: match.range(at: 2))) ?? 0,
                Int(ns.substring(with: match.range(at: 3))) ?? 0, at: match.range.location)
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let english = englishDateRegex
        for match in english.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let month = (months.firstIndex(of: ns.substring(with: match.range(at: 1)).lowercased()) ?? -1) + 1
            add(Int(ns.substring(with: match.range(at: 3))) ?? 0, month, Int(ns.substring(with: match.range(at: 2))) ?? 0, at: match.range.location)
        }
        let dayFirst = dayFirstDateRegex
        for match in dayFirst.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let month = (months.firstIndex(of: ns.substring(with: match.range(at: 2)).lowercased()) ?? -1) + 1
            add(Int(ns.substring(with: match.range(at: 3))) ?? 0, month, Int(ns.substring(with: match.range(at: 1))) ?? 0, at: match.range.location)
        }
        var seen = Set<Date>()
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// The page's one date; nil when it has none or more than one (the
    /// rule can't tell which is the issue date, so the file needs review).
    static func singleDate(in text: String) -> Date? {
        let all = dates(in: text)
        return all.count == 1 ? all[0] : nil
    }

    /// Why `rule` can't decide this PDF, or nil when it can: the page
    /// couldn't be read, or a Rename names a value the page doesn't have
    /// once (a label not found, no date or two dates).
    static func reviewReason(_ rule: FolderRule, _ pdf: FolderRulePDFContent) -> String? {
        if let reason = pdf.reviewReason { return reason }
        for action in rule.actions where action.kind == .rename {
            for token in FolderRulePatterns.tokens(in: action.pattern) {
                if token.name == "after", let label = token.argument, value(after: label, in: pdf.text) == nil {
                    return "“\(label)” isn't on its first page"
                }
                if token.name == "pdfdate" {
                    let count = dates(in: pdf.text).count
                    if count == 0 { return "its first page has no date" }
                    if count > 1 { return "its first page has \(count) different dates, so the issue date isn't clear" }
                }
            }
        }
        return nil
    }
}
