import Foundation
import CoreGraphics

// Pure text-layout and post-processing for Capture Text (OCR).
//
// Nothing in this file talks to Vision: it works on plain strings and pixel
// rectangles, so reading order, paragraph re-flow, hyphen joining and CJK
// spacing can be unit tested deterministically.

// MARK: - Scripts

/// The writing system of a character, at the granularity OCR cares about.
enum TextScript: String, CaseIterable {
    case latin, hangul, han, kana, cjkPunctuation, cyrillic, greek, arabic, hebrew, thai, devanagari, common, other

    /// Scripts written without spaces between words (Chinese, Japanese).
    var isUnspaced: Bool { self == .han || self == .kana || self == .cjkPunctuation }

    /// Han, Kana, Hangul and full-width punctuation.
    var isCJK: Bool { isUnspaced || self == .hangul }
}

enum TextScriptClassifier {
    static func script(of scalar: Unicode.Scalar) -> TextScript {
        let v = scalar.value
        switch v {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC:
            return .hangul
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            return .kana
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .han
        case 0x3000...0x303F, 0xFE30...0xFE4F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40,
             0xFF5B...0xFF65:
            return .cjkPunctuation
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF:
            return .hebrew
        case 0x0E00...0x0E7F:
            return .thai
        case 0x0900...0x097F:
            return .devanagari
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x024F,
             0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        default:
            if scalar.properties.isAlphabetic { return .other }
            return .common
        }
    }

    static func script(of character: Character) -> TextScript {
        guard let first = character.unicodeScalars.first else { return .common }
        return script(of: first)
    }

    /// Letter counts per script, ignoring digits, punctuation and spaces.
    static func histogram(_ text: String) -> [TextScript: Int] {
        var counts: [TextScript: Int] = [:]
        for scalar in text.unicodeScalars {
            let s = script(of: scalar)
            if s != .common { counts[s, default: 0] += 1 }
        }
        return counts
    }

    /// The script with the most letters, or nil for an empty/punctuation-only string.
    static func dominantScript(_ text: String) -> TextScript? {
        let counts = histogram(text).filter { $0.key != .cjkPunctuation }
        guard let maxCount = counts.values.max() else { return nil }
        let top = counts.filter { $0.value == maxCount }
        if top.count == 1 { return top.first?.key }
        let priorityOrder: [TextScript] = [.hangul, .han, .kana, .cyrillic, .greek, .arabic, .hebrew, .thai, .devanagari, .latin, .other, .common]
        return priorityOrder.first { top.keys.contains($0) } ?? top.first?.key
    }
}

// MARK: - Spacing

enum TextSpacing {
    private static let closingCJK: Set<Character> = ["。", "、", "，", "．", "！", "？", "：", "；", "）", "」", "』", "】", "〕", "〉", "》", "”", "’", "…", "・", "ー"]
    private static let openingCJK: Set<Character> = ["（", "「", "『", "【", "〔", "〈", "《", "“", "‘"]

    /// The separator for joining two wrapped lines (or two OCR fragments on
    /// one line) into running text.
    ///
    /// Chinese and Japanese wrap anywhere and never imply a space, so a join
    /// touching Han/Kana gets none. Korean wraps at word boundaries, so a
    /// Hangul–Hangul join keeps its space, as does everything else.
    static func lineJoinSeparator(_ left: String, _ right: String) -> String {
        guard let a = left.last(where: { !$0.isWhitespace }),
              let b = right.first(where: { !$0.isWhitespace }) else { return "" }
        let sa = TextScriptClassifier.script(of: a)
        let sb = TextScriptClassifier.script(of: b)
        if sa.isUnspaced || sb.isUnspaced { return "" }
        if closingCJK.contains(b) || openingCJK.contains(a) { return "" }
        return " "
    }

    /// Removes the spurious spaces OCR engines put between Chinese/Japanese
    /// characters and around full-width punctuation. Spaces between Hangul
    /// words are real word spacing and are kept.
    static func normalizeCJKSpacing(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count > 2 else { return text }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\u{3000}" {
                var j = i
                while j < chars.count, chars[j] == " " || chars[j] == "\u{3000}" { j += 1 }
                if let prev = out.last, j < chars.count {
                    let next = chars[j]
                    let sp = TextScriptClassifier.script(of: prev)
                    let sn = TextScriptClassifier.script(of: next)
                    let bothUnspaced = sp.isUnspaced && sn.isUnspaced
                    let punctuation = closingCJK.contains(next) || openingCJK.contains(prev)
                    if bothUnspaced || punctuation {
                        i = j
                        continue
                    }
                }
                out.append(contentsOf: chars[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}

// MARK: - Hyphenation

enum TextHyphenation {
    private static let hyphens: Set<Character> = ["-", "\u{00AD}", "\u{2010}", "\u{2011}"]

    /// True when `line` ends in a word broken by a hyphen and `next` continues
    /// it in lower case ("infor-" + "mation"). Dashes after a space ("a -")
    /// and lone hyphens are list markers or punctuation, not hyphenation.
    static func isHyphenBreak(_ line: String, next: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, hyphens.contains(last) else { return false }
        let body = trimmed.dropLast()
        guard let beforeHyphen = body.last, beforeHyphen.isLetter,
              body.count >= 2 else { return false }
        let script = TextScriptClassifier.script(of: beforeHyphen)
        guard script == .latin || script == .cyrillic || script == .greek else { return false }
        guard let first = next.trimmingCharacters(in: .whitespaces).first else { return false }
        return first.isLetter && first.isLowercase
    }

    /// Joins a hyphen-broken word across two lines and returns the merged text.
    static func join(_ line: String, _ next: String) -> String {
        var head = line.trimmingCharacters(in: .whitespaces)
        head.removeLast()
        return head + next.trimmingCharacters(in: .whitespaces)
    }

    /// Keep-line-breaks variant: the continuation fragment is pulled up onto
    /// the line where the word starts, the rest of the next line stays put.
    static func joinPreservingLines(_ lines: [String]) -> [String] {
        var result = lines
        var index = 0
        while index + 1 < result.count {
            if isHyphenBreak(result[index], next: result[index + 1]) {
                let next = result[index + 1].trimmingCharacters(in: .whitespaces)
                let splitAt = next.firstIndex(where: { $0.isWhitespace }) ?? next.endIndex
                var fragment = String(next[..<splitAt])
                var rest = String(next[splitAt...]).trimmingCharacters(in: .whitespaces)
                // Keep trailing punctuation with the completed word.
                if fragment.isEmpty { fragment = next; rest = "" }
                result[index] = join(result[index], fragment)
                if rest.isEmpty {
                    result.remove(at: index + 1)
                } else {
                    result[index + 1] = rest
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return result
    }
}

// MARK: - Text-only post-processing

enum TextPostProcessor {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", "。", "！", "？", "：", "…"]

    static func isListItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return false }
        if ["•", "◦", "▪", "‣", "·", "●", "○", "■", "□", "–", "—", "*", "-", "✓", "✔", "☐", "☑"].contains(first) {
            return t.count == 1 || t.dropFirst().first?.isWhitespace == true
        }
        // "1.", "2)", "a)" style enumerations.
        let prefix = t.prefix(4)
        if let marker = prefix.firstIndex(where: { $0 == "." || $0 == ")" }), marker != prefix.startIndex {
            let head = prefix[..<marker]
            let afterMarker = t.index(after: marker)
            let spaced = afterMarker == t.endIndex || t[afterMarker].isWhitespace
            return spaced && (head.allSatisfy(\.isNumber) || (head.count == 1 && head.first!.isLetter))
        }
        return false
    }

    static func endsSentence(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
        return sentenceEnders.contains(last)
    }

    /// Joins already-ordered lines into paragraphs without geometry (used for
    /// Live Text transcripts). Blank lines and list items start a new line;
    /// everything else is re-flowed with script-aware separators.
    static func reflow(_ lines: [String], joinsHyphenatedWords: Bool) -> String {
        var paragraphs: [String] = []
        var current = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                continue
            }
            if current.isEmpty {
                current = line
            } else if isListItem(line) {
                paragraphs.append(current)
                current = line
            } else if joinsHyphenatedWords && TextHyphenation.isHyphenBreak(current, next: line) {
                current = TextHyphenation.join(current, line)
            } else {
                current += TextSpacing.lineJoinSeparator(current, line) + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }

    /// Final clean-up applied to every result.
    static func finalize(_ text: String, normalizesCJK: Bool = true) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            return normalizesCJK ? TextSpacing.normalizeCJKSpacing(l) : l
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Web/mail links found in `text`, in order of appearance, de-duplicated.
    static func links(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme),
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Normalised similarity (0…1) of two strings ignoring whitespace, based
    /// on the longest common subsequence. Used to align engine outputs.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.filter { !$0.isWhitespace })
        let y = Array(b.filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        if x.count * y.count > 250_000 { return x == y ? 1 : 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var current = previous
        for i in 1...x.count {
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(2 * previous[y.count]) / Double(x.count + y.count)
    }

    /// Fraction of `needle`'s characters (ignoring whitespace) that appear, in
    /// order, in `haystack` — how much of a candidate a re-read confirms.
    static func containment(_ needle: String, in haystack: String) -> Double {
        let x = Array(needle.filter { !$0.isWhitespace })
        let y = Array(haystack.filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty, x.count * y.count <= 250_000 else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var current = previous
        for i in 1...x.count {
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) / Double(x.count)
    }
}

// MARK: - Geometric layout

/// One recognised run of text on one visual line, in image pixels with a
/// top-left origin.
struct TextLayoutLine: Equatable {
    var text: String
    var box: CGRect
    var confidence: Float = 1
}

struct TextLayoutOptions: Equatable {
    var keepsLineBreaks = true
    var joinsHyphenatedWords = true
    var detectsColumns = true
    var normalizesCJKSpacing = true
}

enum TextLayoutAssembler {
    /// Orders `segments` into reading order (blocks top-to-bottom, columns
    /// left-to-right) and renders them as text.
    static func assemble(_ segments: [TextLayoutLine], options: TextLayoutOptions = .init()) -> String {
        let usable = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.box.width > 0 && $0.box.height > 0 }
        guard !usable.isEmpty else { return "" }
        let medianHeight = median(usable.map(\.box.height))
        let blocks = options.detectsColumns ? cut(usable, medianHeight: medianHeight, depth: 0) : [usable]
        let rendered = blocks.map { render(block: $0, medianHeight: medianHeight, options: options) }
            .filter { !$0.isEmpty }
        let text = rendered.joined(separator: "\n")
        return TextPostProcessor.finalize(text, normalizesCJK: options.normalizesCJKSpacing)
    }

    /// Recursive XY-cut. A clean vertical gutter that is a genuine text
    /// column split wins; otherwise the block is split at its widest
    /// horizontal gap (headers, separate paragraphs) and both halves recurse.
    static func cut(_ segments: [TextLayoutLine], medianHeight: CGFloat, depth: Int) -> [[TextLayoutLine]] {
        guard segments.count >= 2, depth < 8 else { return [segments] }
        if let (left, right) = verticalSplit(segments, medianHeight: medianHeight) {
            return cut(left, medianHeight: medianHeight, depth: depth + 1)
                + cut(right, medianHeight: medianHeight, depth: depth + 1)
        }
        if let (top, bottom) = horizontalSplit(segments, medianHeight: medianHeight) {
            return cut(top, medianHeight: medianHeight, depth: depth + 1)
                + cut(bottom, medianHeight: medianHeight, depth: depth + 1)
        }
        return [segments]
    }

    private static func verticalSplit(_ segments: [TextLayoutLine], medianHeight: CGFloat)
        -> ([TextLayoutLine], [TextLayoutLine])? {
        let intervals = merged(segments.map { ($0.box.minX, $0.box.maxX) })
        guard intervals.count >= 2 else { return nil }
        var best: (gap: CGFloat, at: CGFloat)?
        for (a, b) in zip(intervals, intervals.dropFirst()) {
            let gap = b.0 - a.1
            if gap >= medianHeight * 1.0, gap > (best?.gap ?? 0) { best = (gap, (a.1 + b.0) / 2) }
        }
        guard let split = best?.at else { return nil }
        let left = segments.filter { $0.box.midX < split }
        let right = segments.filter { $0.box.midX >= split }
        guard isTextColumn(left), isTextColumn(right) else { return nil }
        // Columns must sit side by side, not one below the other.
        let lv = (left.map(\.box.minY).min()!, left.map(\.box.maxY).max()!)
        let rv = (right.map(\.box.minY).min()!, right.map(\.box.maxY).max()!)
        let overlap = min(lv.1, rv.1) - max(lv.0, rv.0)
        guard overlap > medianHeight * 1.5 else { return nil }
        return (left, right)
    }

    /// A prose column has several lines that mostly fill its width. Table
    /// cells (short, ragged) are left to row-wise rendering instead.
    private static func isTextColumn(_ segments: [TextLayoutLine]) -> Bool {
        let lines = visualLines(segments)
        guard lines.count >= 3 else { return false }
        let minX = segments.map(\.box.minX).min()!
        let maxX = segments.map(\.box.maxX).max()!
        let width = max(1, maxX - minX)
        let filled = lines.map { line -> CGFloat in
            (line.map(\.box.maxX).max()! - line.map(\.box.minX).min()!) / width
        }
        return median(filled) >= 0.6
    }

    private static func horizontalSplit(_ segments: [TextLayoutLine], medianHeight: CGFloat)
        -> ([TextLayoutLine], [TextLayoutLine])? {
        let intervals = merged(segments.map { ($0.box.minY, $0.box.maxY) })
        guard intervals.count >= 2 else { return nil }
        var best: (gap: CGFloat, at: CGFloat)?
        for (a, b) in zip(intervals, intervals.dropFirst()) {
            let gap = b.0 - a.1
            if gap >= medianHeight * 1.2, gap > (best?.gap ?? 0) { best = (gap, (a.1 + b.0) / 2) }
        }
        guard let split = best?.at else { return nil }
        let top = segments.filter { $0.box.midY < split }
        let bottom = segments.filter { $0.box.midY >= split }
        guard !top.isEmpty, !bottom.isEmpty else { return nil }
        return (top, bottom)
    }

    /// Groups segments into visual lines (top to bottom), each sorted left to right.
    static func visualLines(_ segments: [TextLayoutLine]) -> [[TextLayoutLine]] {
        let sorted = segments.sorted { $0.box.midY < $1.box.midY }
        var lines: [[TextLayoutLine]] = []
        var bands: [(minY: CGFloat, maxY: CGFloat)] = []
        for segment in sorted {
            if let index = bands.indices.last,
               verticalOverlap(bands[index], (segment.box.minY, segment.box.maxY))
                >= 0.5 * min(bands[index].maxY - bands[index].minY, segment.box.height) {
                lines[index].append(segment)
                bands[index] = (min(bands[index].minY, segment.box.minY), max(bands[index].maxY, segment.box.maxY))
            } else {
                lines.append([segment])
                bands.append((segment.box.minY, segment.box.maxY))
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private struct RenderedLine {
        var text: String
        var box: CGRect
    }

    private static func render(block: [TextLayoutLine], medianHeight: CGFloat, options: TextLayoutOptions) -> String {
        let lines: [RenderedLine] = visualLines(block).map { parts in
            var text = ""
            var previous: TextLayoutLine?
            for part in parts {
                let piece = part.text.trimmingCharacters(in: .whitespaces)
                if let previous {
                    let gap = part.box.minX - previous.box.maxX
                    let height = max(previous.box.height, part.box.height)
                    if gap > height * 2.5 {
                        text += options.keepsLineBreaks ? "\t" : " "
                    } else {
                        let sep = TextSpacing.lineJoinSeparator(text, piece)
                        text += (sep.isEmpty && gap > height * 0.6) ? " " : sep
                    }
                }
                text += piece
                previous = part
            }
            let box = parts.dropFirst().reduce(parts[0].box) { $0.union($1.box) }
            return RenderedLine(text: text, box: box)
        }
        guard !lines.isEmpty else { return "" }
        if options.keepsLineBreaks {
            let texts = lines.map(\.text)
            return (options.joinsHyphenatedWords ? TextHyphenation.joinPreservingLines(texts) : texts)
                .joined(separator: "\n")
        }
        return reflow(lines, medianHeight: medianHeight, joinsHyphens: options.joinsHyphenatedWords)
    }

    /// Paragraph re-flow with geometry: lines are joined unless the gap,
    /// indentation, size change or a short sentence-ending line marks a new
    /// paragraph (the same signals TextSniper's line separator weighs).
    private static func reflow(_ lines: [RenderedLine], medianHeight: CGFloat, joinsHyphens: Bool) -> String {
        guard lines.count > 1 else { return lines.first?.text ?? "" }
        let minX = lines.map(\.box.minX).min()!
        let maxX = lines.map(\.box.maxX).max()!
        let width = max(1, maxX - minX)
        let gaps = zip(lines, lines.dropFirst()).map { max(0, $1.box.minY - $0.box.maxY) }
        let normalGap = median(gaps)
        var output = lines[0].text
        for index in 1..<lines.count {
            let prev = lines[index - 1]
            let next = lines[index]
            let h = max(1, min(prev.box.height, next.box.height))
            let gap = max(0, next.box.minY - prev.box.maxY)
            let heightChange = abs(prev.box.height - next.box.height) / max(prev.box.height, next.box.height)
            let indented = next.box.minX - minX > h * 1.5 && prev.box.minX - minX < h * 0.5
            let shortPrevious = prev.box.maxX < maxX - width * 0.2
            var breakLine = gap > normalGap + h * 0.6
                || heightChange > 0.3
                || indented
                || TextPostProcessor.isListItem(next.text)
                || (shortPrevious && TextPostProcessor.endsSentence(prev.text))
            // A short unpunctuated line followed by a capitalised one is a
            // heading or a label, not a wrapped sentence.
            if shortPrevious && !TextPostProcessor.endsSentence(prev.text)
                && next.text.first?.isUppercase == true && prev.text.count < 40 {
                breakLine = true
            }
            if breakLine {
                output += "\n" + next.text
            } else if joinsHyphens && TextHyphenation.isHyphenBreak(output, next: next.text) {
                output = TextHyphenation.join(output, next.text)
            } else {
                output += TextSpacing.lineJoinSeparator(output, next.text) + next.text
            }
        }
        return output
    }

    // MARK: Helpers

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func merged(_ intervals: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var result: [(CGFloat, CGFloat)] = []
        for interval in sorted {
            if let last = result.last, interval.0 <= last.1 {
                result[result.count - 1].1 = max(last.1, interval.1)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func verticalOverlap(_ a: (minY: CGFloat, maxY: CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat {
        max(0, min(a.maxY, b.1) - max(a.minY, b.0))
    }
}
