import Foundation
import CoreGraphics
import CoreImage
import Vision
import VisionKit
import NaturalLanguage

// The Capture Text recognition pipeline.
//
// TextSniper 1.12 (see the REA spec) hands Vision every supported language
// with the user's primary language first, and switches to VisionKit Live
// Text for Chinese/Japanese/Korean. Measured on this OS, Vision's accurate
// recogniser still reads essentially one script family per pass — the first
// language decides — so a single pass garbles mixed Korean/Japanese/Chinese
// lines. AOM therefore runs:
//
//   1. a discovery pass with automatic language detection,
//   2. one pass per script group present (Hangul, Japanese, Chinese, Latin…),
//   3. an inverted pass for light-on-dark captures, all on an adaptively
//      upscaled image when the text is small,
//   4. VisionKit Live Text concurrently,
//
// and fuses them token by token: each pass votes with its confidence weighted
// by how plausible the token's script is for that pass, and Live Text votes
// for the alternatives its transcript contains. Geometry from the Vision
// passes then drives reading order, columns and paragraph re-flow.

/// Per-capture recognition options. `fromSettings` mirrors the user's
/// Text Recognition preferences.
struct TextRecognitionOptions: Equatable {
    /// Explicit language priority (Vision codes). Empty uses the settings.
    var languages: [String] = []
    var keepsLineBreaks = true
    var joinsHyphenatedWords = true
    var usesLanguageCorrection = true
    var customWords: [String] = []
    var engine: TextRecognitionEngineMode = .automatic
    var detectsColumns = true
    /// Upscale small text and add an inverted pass for dark captures.
    var preprocesses = true
    var maximumScriptPasses = 4
    /// TextSniper-style instant path: one accurate Vision pass with the
    /// user's own languages. The multi-pass voting pipeline only runs when
    /// that pass is empty, low-confidence or sees a script it cannot read.
    var prefersSpeed = true

    static func fromSettings(_ settings: TextCaptureSettings = .shared, keepsLineBreaks: Bool? = nil) -> Self {
        var options = TextRecognitionOptions()
        options.languages = settings.recognitionLanguages
        options.keepsLineBreaks = keepsLineBreaks ?? settings.keepsLineBreaks
        options.joinsHyphenatedWords = settings.joinsHyphenatedWords
        options.usesLanguageCorrection = settings.usesLanguageCorrection
        options.customWords = settings.customWords
        options.engine = settings.engine
        options.prefersSpeed = settings.prefersFastRecognition
        return options
    }
}

struct TextRecognitionResult {
    var text: String
    /// Fused line segments in the original image's pixels, top-left origin.
    var lines: [TextLayoutLine]
    var imageSize: CGSize
    /// BCP-47 code of the dominant language (NaturalLanguage), if any.
    var detectedLanguage: String?
    var passCount: Int
    var usedLiveText: Bool
    var upscale: CGFloat
    var inverted: Bool
    var liveTextTranscript: String?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func empty(_ size: CGSize) -> Self {
        .init(text: "", lines: [], imageSize: size, detectedLanguage: nil, passCount: 0,
              usedLiveText: false, upscale: 1, inverted: false, liveTextTranscript: nil)
    }
}

struct TextCaptureBarcode: Equatable, Hashable {
    var payload: String
    var symbology: String
}

// MARK: - Fusion (pure)

struct OCRToken: Equatable {
    var text: String
    /// Pixels, top-left origin.
    var box: CGRect
    /// Whether the source string had whitespace right before this token.
    var leadingSpace = false
}

struct OCRPassObservation: Equatable {
    var text: String
    var box: CGRect
    var confidence: Float
    var tokens: [OCRToken]
}

struct OCRPass: Equatable {
    var label: String
    /// nil for script-agnostic passes (automatic detection, inverted).
    var group: TextScriptGroup?
    var observations: [OCRPassObservation]

    var text: String { observations.map(\.text).joined(separator: "\n") }
}

enum TextRecognitionFusion {
    /// How plausible `text` is as output of a pass reading `group`. A Korean
    /// pass that "reads" Katakana, or a Chinese pass that emits Cyrillic, is
    /// hallucinating; Latin from a CJK pass is merely less trustworthy.
    static func scriptWeight(_ text: String, group: TextScriptGroup?) -> Double {
        let histogram = TextScriptClassifier.histogram(text)
        let letters = histogram.values.reduce(0, +)
        guard let group, letters > 0 else { return 1 }
        let native = group.nativeScripts
        var total = 0.0
        for (script, count) in histogram {
            let weight: Double
            if native.contains(script) {
                weight = 1
            } else if script == .latin || script == .cjkPunctuation {
                weight = group == .latin ? 1 : 0.8
            } else if script == .han && group == .hangul {
                weight = 0.5
            } else if script == .kana && (group == .chineseSimplified || group == .chineseTraditional) {
                weight = 0.4
            } else {
                weight = 0.25
            }
            total += weight * Double(count)
        }
        var factor = total / Double(letters)
        if group != .latin, histogram.keys.contains(where: { native.contains($0) && $0 != .cjkPunctuation }) {
            factor *= 1.1
        }
        return factor
    }

    /// Splits a recognised string into vote units: words, and runs of one
    /// script inside unspaced CJK text ("世界こんにちは" → "世界", "こんにちは").
    static func tokenRanges(_ text: String) -> [Range<String.Index>] {
        func cls(_ c: Character) -> Int {
            switch TextScriptClassifier.script(of: c) {
            case .han: return 1
            case .kana: return 2
            case .hangul: return 3
            case .cjkPunctuation, .common: return -1
            default: return 0
            }
        }
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var current = 0
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isWhitespace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else {
                let k = cls(c)
                if let s = start, k != -1, current != -1, k != current {
                    ranges.append(s..<index)
                    start = index
                    current = k
                } else if start == nil {
                    start = index
                    current = k
                } else if current == -1 {
                    current = k
                }
            }
            index = text.index(after: index)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    // MARK: Token geometry

    /// Relative advance of a character, for distributing a run's width.
    private static func advance(_ c: Character) -> CGFloat {
        if c.isWhitespace { return 0.3 }
        return TextScriptClassifier.script(of: c).isCJK ? 1.0 : 0.55
    }

    /// Token boxes inside one observation. Vision's sub-range boxes are good
    /// for Latin words but often span the rest of the line for CJK runs; a
    /// box that is far wider than its share, or overlaps its neighbour, is
    /// discarded and re-estimated by distributing the free span between the
    /// reliable neighbours in proportion to character advances.
    static func layoutTokens(text: String, ranges: [Range<String.Index>], measured: [CGRect?],
                             lineBox: CGRect) -> [CGRect] {
        guard !ranges.isEmpty else { return [] }
        let totalAdvance = max(0.01, text.reduce(0) { $0 + advance($1) })
        func share(_ r: Range<String.Index>) -> CGFloat { text[r].reduce(0) { $0 + advance($1) } / totalAdvance }
        var boxes: [CGRect?] = measured
        // Colliding measured boxes are both untrustworthy (Vision reports
        // "rest of the line" for each CJK sub-range).
        for i in measured.indices.dropLast() {
            guard let a = measured[i], let b = measured[i + 1] else { continue }
            let o = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
            if o > 0.3 * min(a.width, b.width) {
                boxes[i] = nil
                boxes[i + 1] = nil
            }
        }
        for i in boxes.indices {
            guard let b = boxes[i] else { continue }
            let expected = lineBox.width * share(ranges[i])
            if b.width > max(expected * 1.7, expected + lineBox.height * 0.5) || b.minX < lineBox.minX - lineBox.height
                || b.maxX > lineBox.maxX + lineBox.height {
                boxes[i] = nil
            }
        }
        var result = [CGRect](repeating: .zero, count: ranges.count)
        var i = 0
        while i < ranges.count {
            if let b = boxes[i] {
                result[i] = CGRect(x: b.minX, y: lineBox.minY, width: b.width, height: lineBox.height)
                i += 1
                continue
            }
            var j = i
            while j < ranges.count, boxes[j] == nil { j += 1 }
            let left = i == 0 ? lineBox.minX : (boxes[i - 1]?.maxX ?? lineBox.minX)
            let right = j == ranges.count ? lineBox.maxX : (boxes[j]?.minX ?? lineBox.maxX)
            // Advance of the characters from the end of token i-1 to the start of token j.
            let runStart = i == 0 ? text.startIndex : ranges[i - 1].upperBound
            let runEnd = j == ranges.count ? text.endIndex : ranges[j].lowerBound
            let runAdvance = max(0.01, text[runStart..<runEnd].reduce(0) { $0 + advance($1) })
            let span = max(1, right - left)
            for k in i..<j {
                let before = text[runStart..<ranges[k].lowerBound].reduce(0) { $0 + advance($1) }
                let own = text[ranges[k]].reduce(0) { $0 + advance($1) }
                result[k] = CGRect(x: left + span * before / runAdvance, y: lineBox.minY,
                                   width: max(1, span * own / runAdvance), height: lineBox.height)
            }
            i = j
        }
        return result
    }

    // MARK: Voting

    struct Alternative {
        var key: String
        var text: String
        var box: CGRect
        var score: Double
        var bestWeight: Double
        var leadingSpace: Bool
    }

    struct Cluster {
        var box: CGRect
        var alternatives: [Alternative]   // best first
    }

    struct Slot {
        var clusters: [Cluster]           // left to right
        var memberCount: Int
    }

    private final class UnionFind {
        var parent: [Int]
        init(_ n: Int) { parent = Array(0..<n) }
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        func groups() -> [[Int]] {
            var map: [Int: [Int]] = [:]
            for i in parent.indices { map[find(i), default: []].append(i) }
            return map.values.sorted { $0[0] < $1[0] }
        }
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    private static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }

    /// Groups every pass's observations into slots (same text run) and the
    /// slots' tokens into clusters (same position), with tallied votes.
    static func slots(_ passes: [OCRPass], liveTextLines: [String] = [],
                      regionHints: [(region: CGRect, text: String)] = []) -> [Slot] {
        struct Obs { let pass: Int; let o: OCRPassObservation }
        var all: [Obs] = []
        for (p, pass) in passes.enumerated() {
            for o in pass.observations where !key(o.text).isEmpty && o.box.width > 0 && o.box.height > 0 {
                all.append(Obs(pass: p, o: o))
            }
        }
        guard !all.isEmpty else { return [] }

        let slotsUF = UnionFind(all.count)
        for i in all.indices {
            for j in (i + 1)..<max(i + 1, all.count) {
                let a = all[i].o.box, b = all[j].o.box
                let v = overlap(a.minY, a.maxY, b.minY, b.maxY)
                let h = overlap(a.minX, a.maxX, b.minX, b.maxX)
                if v >= 0.5 * min(a.height, b.height), h >= 0.1 * min(a.width, b.width) {
                    slotsUF.union(i, j)
                }
            }
        }
        let vkKeys = liveTextLines.map(key).filter { !$0.isEmpty }

        var result: [Slot] = []
        for slotIndices in slotsUF.groups() {
            // Passes that read this run identically are one voter, not several.
            var members: [Obs] = []
            for m in slotIndices.map({ all[$0] }).sorted(by: { $0.o.confidence > $1.o.confidence }) {
                if !members.contains(where: { $0.pass != m.pass && key($0.o.text) == key(m.o.text) }) {
                    members.append(m)
                }
            }
            struct Tok { let pass: Int; let token: OCRToken; let weight: Double }
            var tokens: [Tok] = []
            for m in members {
                let group = passes[m.pass].group
                for t in m.o.tokens where !key(t.text).isEmpty {
                    tokens.append(Tok(pass: m.pass, token: t,
                                      weight: Double(m.o.confidence) * scriptWeight(t.text, group: group)))
                }
            }
            guard !tokens.isEmpty else { continue }
            tokens.sort { $0.token.box.minX < $1.token.box.minX }
            let tokUF = UnionFind(tokens.count)
            for i in tokens.indices {
                for j in (i + 1)..<max(i + 1, tokens.count) {
                    let a = tokens[i].token.box, b = tokens[j].token.box
                    if b.minX > a.maxX { break }
                    if overlap(a.minX, a.maxX, b.minX, b.maxX) >= 0.5 * min(a.width, b.width) {
                        tokUF.union(i, j)
                    }
                }
            }
            var vkKey: String?
            if !vkKeys.isEmpty {
                var best = 0.0
                for m in members {
                    for candidate in vkKeys {
                        let s = TextPostProcessor.similarity(m.o.text, candidate)
                        if s > best { best = s; vkKey = candidate }
                    }
                }
                if best < 0.45 { vkKey = nil }
            }

            var clusters: [Cluster] = []
            for cluster in tokUF.groups() {
                var perPass: [Int: [Tok]] = [:]
                for index in cluster { perPass[tokens[index].pass, default: []].append(tokens[index]) }
                var tallies: [String: Alternative] = [:]
                for (_, toks) in perPass {
                    let ordered = toks.sorted { $0.token.box.minX < $1.token.box.minX }
                    var text = ""
                    for t in ordered {
                        text += text.isEmpty ? "" : TextSpacing.lineJoinSeparator(text, t.token.text)
                        text += t.token.text
                    }
                    let weight = ordered.map(\.weight).reduce(0, +) / Double(ordered.count)
                    let box = ordered.dropFirst().reduce(ordered[0].token.box) { $0.union($1.token.box) }
                    let k = key(text)
                    let spaced = ordered[0].token.leadingSpace
                    var entry = tallies[k] ?? Alternative(key: k, text: text, box: box, score: 0, bestWeight: 0,
                                                          leadingSpace: spaced)
                    entry.score += weight
                    if weight > entry.bestWeight {
                        entry.bestWeight = weight; entry.text = text; entry.box = box; entry.leadingSpace = spaced
                    }
                    tallies[k] = entry
                }
                if let vkKey {
                    for k in tallies.keys where vkKey.contains(k) {
                        // Whole-line Live Text guesses scripts too, so it only nudges.
                        tallies[k]!.score += k.count >= 2 ? 0.4 : 0.15
                    }
                }
                let box = cluster.map { tokens[$0].token.box }.dropFirst()
                    .reduce(tokens[cluster[0]].token.box) { $0.union($1) }
                // A re-read of this exact region (Live Text on a crop) is the
                // strongest evidence there is.
                for hint in regionHints {
                    let i = box.intersection(hint.region)
                    guard !i.isNull, i.width * i.height >= 0.5 * box.width * box.height else { continue }
                    for k in tallies.keys {
                        tallies[k]!.score += 1.5 * TextPostProcessor.containment(k, in: hint.text)
                    }
                }
                let ordered = tallies.values.sorted {
                    $0.score == $1.score ? $0.key.count > $1.key.count : $0.score > $1.score
                }
                clusters.append(Cluster(box: box, alternatives: ordered))
            }
            clusters.sort { $0.box.minX < $1.box.minX }
            result.append(Slot(clusters: clusters, memberCount: members.count))
        }
        return result
    }

    /// Regions where passes reading different scripts disagree closely
    /// enough that a re-read of just that region should decide.
    static func disputedRegions(_ passes: [OCRPass], liveTextLines: [String] = [], limit: Int = 6) -> [CGRect] {
        var regions: [CGRect] = []
        for slot in slots(passes, liveTextLines: liveTextLines) {
            for cluster in slot.clusters where cluster.alternatives.count >= 2 {
                let first = cluster.alternatives[0], second = cluster.alternatives[1]
                guard second.bestWeight >= 0.3 || second.score >= 0.5 * first.score,
                      let s1 = TextScriptClassifier.dominantScript(first.text),
                      let s2 = TextScriptClassifier.dominantScript(second.text), s1 != s2 else { continue }
                regions.append(cluster.box)
            }
        }
        return Array(regions.prefix(limit))
    }

    /// Fuses several passes over the same image into line segments.
    static func fuse(_ passes: [OCRPass], liveTextLines: [String] = [],
                     regionHints: [(region: CGRect, text: String)] = []) -> [TextLayoutLine] {
        if passes.count == 1 {
            return passes[0].observations.filter { !key($0.text).isEmpty }
                .map { TextLayoutLine(text: $0.text, box: $0.box, confidence: $0.confidence) }
        }
        var lines: [TextLayoutLine] = []
        for slot in slots(passes, liveTextLines: liveTextLines, regionHints: regionHints) {
            let winners = slot.clusters.compactMap { cluster -> Alternative? in
                guard let best = cluster.alternatives.first, best.score >= 0.12 else { return nil }
                return best
            }
            guard !winners.isEmpty else { continue }
            var text = ""
            var previous: Alternative?
            for w in winners {
                if let previous {
                    let gap = w.box.minX - previous.box.maxX
                    let h = max(previous.box.height, w.box.height)
                    let sep = TextSpacing.lineJoinSeparator(previous.text, w.text)
                    // The winning reading's own spacing decides; geometry only
                    // fills in where that reading started mid-run.
                    if w.leadingSpace { text += " " }
                    else if gap > h * (sep.isEmpty ? 0.5 : 0.3) { text += " " }
                }
                text += w.text
                previous = w
            }
            let box = winners.dropFirst().reduce(winners[0].box) { $0.union($1.box) }
            let mean = winners.map(\.score).reduce(0, +) / Double(winners.count)
            let confidence = Float(min(1, mean / Double(max(1, slot.memberCount)) * 1.5))
            lines.append(TextLayoutLine(text: text, box: box, confidence: confidence))
        }
        return lines
    }
}

// MARK: - Engine

enum TextRecognitionEngine {
    enum EngineError: LocalizedError {
        case requestFailed(String)
        var errorDescription: String? {
            switch self { case .requestFailed(let reason): return "Text recognition failed: \(reason)" }
        }
    }

    /// Full pipeline: passes, fusion, layout and post-processing.
    static func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        let size = CGSize(width: image.width, height: image.height)
        guard image.width >= 2, image.height >= 2 else { return .empty(size) }
        let priority = options.languages.isEmpty
            ? TextCaptureLanguages.priorityList(selected: [], automatic: true)
            : TextCaptureLanguages.priorityList(selected: options.languages, automatic: false)

        if options.prefersSpeed, options.engine != .liveText,
           let fast = try await fastRecognize(image, priority: priority, options: options) {
            return fast
        }

        var working = image
        var scale: CGFloat = 1
        var passes: [OCRPass] = []
        let useVision = options.engine != .liveText || !ImageAnalyzer.isSupported
        let useLiveText = options.engine != .vision && ImageAnalyzer.isSupported

        // Discovery pass (automatic detection), then decide on upscaling.
        var discovery = try await visionPass(working, label: "auto", group: nil, languages: priority,
                                             autoDetect: true, options: options)
        if options.preprocesses, let factor = upscaleFactor(for: discovery, imageHeight: image.height),
           let upscaled = TextCaptureImageTools.upscale(image, by: factor) {
            working = upscaled
            scale = factor
            discovery = try await visionPass(working, label: "auto×\(Int(factor))", group: nil,
                                             languages: priority, autoDetect: true, options: options)
        }
        passes.append(discovery)

        // Live Text in parallel with the script passes.
        let liveTask: Task<String?, Never>? = useLiveText ? Task.detached(priority: .userInitiated) { [working] in
            await liveTextTranscript(working, locales: priority)
        } : nil

        var inverted = false
        var extra: [(label: String, group: TextScriptGroup?, image: CGImage, languages: [String], auto: Bool)] = []
        if options.preprocesses, TextCaptureImageTools.meanLuminance(working) < 0.45,
           let negative = TextCaptureImageTools.invert(working) {
            inverted = true
            extra.append(("inverted", nil, negative, priority, true))
        }
        var groups = TextScriptGroup.groups(forScripts: TextScriptClassifier.histogram(discovery.text), priority: priority)
        for code in priority.prefix(2) {
            let g = TextScriptGroup.group(forLanguage: code)
            if !groups.contains(g) { groups.append(g) }
        }
        var ranGroups: [TextScriptGroup] = []
        if useVision {
            for g in groups.prefix(options.maximumScriptPasses) {
                ranGroups.append(g)
                extra.append((g.rawValue, g, working, TextCaptureLanguages.passLanguages(for: g, priority: priority), false))
            }
            passes += try await runPasses(extra, options: options)
        }

        let transcript = await liveTask?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveLines = (transcript ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // Scripts only Live Text noticed get their own pass too.
        if useVision, let transcript, !transcript.isEmpty {
            let missing = TextScriptGroup.groups(forScripts: TextScriptClassifier.histogram(transcript), priority: priority)
                .filter { !ranGroups.contains($0) }
                .prefix(max(0, options.maximumScriptPasses + 1 - ranGroups.count))
            if !missing.isEmpty {
                passes += try await runPasses(missing.map {
                    ($0.rawValue, $0, working, TextCaptureLanguages.passLanguages(for: $0, priority: priority), false)
                }, options: options)
            }
        }

        // Fuse in working pixels, then report in original pixels.
        // Mixed-script disagreements are settled by Live Text re-reading
        // just the disputed region, where it no longer has to guess the script.
        var hints: [(region: CGRect, text: String)] = []
        if useLiveText {
            let disputes = TextRecognitionFusion.disputedRegions(passes, liveTextLines: liveLines)
            for region in disputes {
                if let crop = TextCaptureImageTools.crop(working, to: region),
                   let reread = await liveTextTranscript(crop, locales: priority), !reread.isEmpty {
                    hints.append((region, reread))
                }
            }
        }
        if ProcessInfo.processInfo.environment["AOM_OCR_DEBUG"] != nil {
            for pass in passes {
                print("[OCR pass \(pass.label)]")
                for o in pass.observations {
                    print("   \(String(format: "%.2f", o.confidence)) \(Int(o.box.minX))-\(Int(o.box.maxX)) | " +
                          o.tokens.map { "\($0.text)@\(Int($0.box.minX))-\(Int($0.box.maxX))" }.joined(separator: " "))
                }
            }
            print("[OCR live] \(transcript ?? "nil")")
            for hint in hints { print("[OCR hint] \(hint.region.integral) → \(hint.text)") }
        }
        let fusedWorking = TextRecognitionFusion.fuse(passes, liveTextLines: liveLines,
                                                      regionHints: hints)
        let fused = fusedWorking.map { line -> TextLayoutLine in
            var l = line
            l.box = CGRect(x: line.box.minX / scale, y: line.box.minY / scale,
                           width: line.box.width / scale, height: line.box.height / scale)
            return l
        }
        let layout = TextLayoutOptions(keepsLineBreaks: options.keepsLineBreaks,
                                       joinsHyphenatedWords: options.joinsHyphenatedWords,
                                       detectsColumns: options.detectsColumns)
        var text = TextLayoutAssembler.assemble(fused, options: layout)
        var usedLiveText = false
        if !liveLines.isEmpty {
            let liveText = postProcessTranscript(liveLines, options: options)
            let liveCount = liveText.filter { !$0.isWhitespace }.count
            let fusedCount = text.filter { !$0.isWhitespace }.count
            if options.engine == .liveText || fusedCount == 0
                || (liveCount >= 8 && Double(fusedCount) < 0.6 * Double(liveCount)) {
                text = liveText
                usedLiveText = true
            }
        }
        return TextRecognitionResult(text: text, lines: fused, imageSize: size,
                                     detectedLanguage: dominantLanguage(text), passCount: passes.count,
                                     usedLiveText: usedLiveText, upscale: scale, inverted: inverted,
                                     liveTextTranscript: transcript)
    }

    /// Text-only post-processing for a Live Text transcript.
    static func postProcessTranscript(_ lines: [String], options: TextRecognitionOptions) -> String {
        let text: String
        if options.keepsLineBreaks {
            text = (options.joinsHyphenatedWords ? TextHyphenation.joinPreservingLines(lines) : lines)
                .joined(separator: "\n")
        } else {
            text = TextPostProcessor.reflow(lines, joinsHyphenatedWords: options.joinsHyphenatedWords)
        }
        return TextPostProcessor.finalize(text)
    }

    // MARK: Fast path

    /// The user's own languages (plus English) for the instant pass. Handing
    /// Vision every supported language only adds model work; the first
    /// language decides the script anyway.
    static func fastLanguages(_ priority: [String], limit: Int = 3) -> [String] {
        var head = Array(priority.prefix(limit))
        if !head.contains("en-US"), TextCaptureLanguages.supported.contains("en-US") { head.append("en-US") }
        return head
    }

    /// Whether one pass is trustworthy enough to skip voting: text was found,
    /// confidence is reasonable, and every script it contains is one the
    /// pass's lead language reads natively (Latin is read by every model).
    static func fastPassIsAcceptable(_ pass: OCRPass, leadGroup: TextScriptGroup, priority: [String]) -> Bool {
        let usable = pass.observations.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return false }
        // Weighted by text length: a stray icon glyph read as "88" must not
        // push a whole page of clean text into the slow voting pipeline.
        let lengths = usable.map { Float(max(1, $0.text.count)) }
        let total = lengths.reduce(0, +)
        let mean = zip(usable, lengths).map { $0.0.confidence * $0.1 }.reduce(0, +) / total
        guard mean >= 0.35 else { return false }
        let groups = TextScriptGroup.groups(forScripts: TextScriptClassifier.histogram(pass.text), priority: priority)
        return groups.allSatisfy { $0 == leadGroup || $0 == .latin }
    }

    /// One accurate pass (two when the text is tiny). Returns nil when the
    /// full multi-pass pipeline should decide instead.
    static func fastRecognize(_ image: CGImage, priority: [String],
                              options: TextRecognitionOptions) async throws -> TextRecognitionResult? {
        let languages = fastLanguages(priority)
        guard let lead = languages.first else { return nil }
        var leadGroup = TextScriptGroup.group(forLanguage: lead)
        var passLanguages = languages
        var pass = try await visionPass(image, label: "fast", group: nil, languages: languages,
                                        autoDetect: true, options: options)
        // One non-Latin script that the lead language does not read (Korean
        // text under an English-first system) gets a single re-read led by
        // that script's language — still two passes, not a dozen.
        if !fastPassIsAcceptable(pass, leadGroup: leadGroup, priority: priority) {
            let scripts = TextScriptGroup.groups(forScripts: TextScriptClassifier.histogram(pass.text), priority: priority)
                .filter { $0 != .latin }
            // Only scripts with no Han ambiguity: a Japanese/Chinese guess can
            // swallow Hangul, so those always get the voting pipeline.
            let unambiguous: Set<TextScriptGroup> = [.hangul, .cyrillic, .thai, .arabic, .devanagari]
            if scripts.count == 1, let group = scripts.first, group != leadGroup, unambiguous.contains(group) {
                var relead = TextCaptureLanguages.passLanguages(for: group, priority: priority)
                relead = Array(relead.prefix(3))
                if !relead.contains("en-US"), TextCaptureLanguages.supported.contains("en-US") { relead.append("en-US") }
                let reread = try await visionPass(image, label: "fast-\(group.rawValue)", group: group,
                                                  languages: relead, autoDetect: true, options: options)
                if fastPassIsAcceptable(reread, leadGroup: group, priority: priority) {
                    pass = reread
                    leadGroup = group
                    passLanguages = relead
                }
            }
        }
        var passCount = pass.label == "fast" ? 1 : 2
        var scale: CGFloat = 1
        // Tiny UI text (1× displays, small fonts) gets one upscaled re-read.
        let median = TextLayoutAssembler.median(pass.observations.map(\.box.height))
        if options.preprocesses, !pass.observations.isEmpty, median < 14 {
            let factor = min(3, max(2, (28 / max(median, 6)).rounded(.up)))
            if let upscaled = TextCaptureImageTools.upscale(image, by: factor) {
                let reread = try await visionPass(upscaled, label: "fast×\(Int(factor))", group: nil,
                                                  languages: passLanguages, autoDetect: true, options: options)
                passCount += 1
                if fastPassIsAcceptable(reread, leadGroup: leadGroup, priority: priority) {
                    pass = reread
                    scale = factor
                }
            }
        }
        guard fastPassIsAcceptable(pass, leadGroup: leadGroup, priority: priority) else { return nil }
        let lines = TextRecognitionFusion.fuse([pass]).map { line -> TextLayoutLine in
            var l = line
            l.box = CGRect(x: line.box.minX / scale, y: line.box.minY / scale,
                           width: line.box.width / scale, height: line.box.height / scale)
            return l
        }
        let layout = TextLayoutOptions(keepsLineBreaks: options.keepsLineBreaks,
                                       joinsHyphenatedWords: options.joinsHyphenatedWords,
                                       detectsColumns: options.detectsColumns)
        let text = TextLayoutAssembler.assemble(lines, options: layout)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TextRecognitionResult(text: text, lines: lines,
                                     imageSize: CGSize(width: image.width, height: image.height),
                                     detectedLanguage: dominantLanguage(text), passCount: passCount,
                                     usedLiveText: false, upscale: scale, inverted: false,
                                     liveTextTranscript: nil)
    }

    /// Loads Vision's accurate text model off the main thread so the first
    /// Capture Text of a session is as quick as the rest.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            _ = TextCaptureLanguages.supported
            guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            guard let image = context.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequest.currentRevision
            request.recognitionLanguages = fastLanguages(TextCaptureLanguages.priorityList(selected: [], automatic: true))
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    /// Upscale when the discovered text is small: Vision's accurate model is
    /// trained on text roughly 20–40 px tall.
    static func upscaleFactor(for pass: OCRPass, imageHeight: Int) -> CGFloat? {
        let heights = pass.observations.map(\.box.height)
        let median = TextLayoutAssembler.median(heights)
        if heights.isEmpty {
            return imageHeight < 120 ? (imageHeight < 40 ? 4 : 2) : nil
        }
        guard median < 20 else { return nil }
        return min(4, max(2, (30 / max(median, 6)).rounded(.up)))
    }

    static func dominantLanguage(_ text: String) -> String? {
        guard text.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }

    private static func runPasses(_ specs: [(label: String, group: TextScriptGroup?, image: CGImage, languages: [String], auto: Bool)],
                                  options: TextRecognitionOptions) async throws -> [OCRPass] {
        try await withThrowingTaskGroup(of: (Int, OCRPass).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    (index, try await visionPass(spec.image, label: spec.label, group: spec.group,
                                                 languages: spec.languages, autoDetect: spec.auto, options: options))
                }
            }
            var results: [(Int, OCRPass)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Vision

    static func visionPass(_ image: CGImage, label: String, group: TextScriptGroup?, languages: [String],
                           autoDetect: Bool, options: TextRecognitionOptions) async throws -> OCRPass {
        let observations = try await recognizeObservations(image, languages: languages, autoDetect: autoDetect,
                                                           correction: options.usesLanguageCorrection,
                                                           customWords: options.customWords)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * width, y: (1 - r.maxY) * height, width: r.width * width, height: r.height * height)
        }
        let mapped: [OCRPassObservation] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            let box = pixels(observation.boundingBox)
            let ranges = TextRecognitionFusion.tokenRanges(string)
            let measured: [CGRect?] = ranges.map { range in
                guard let rect = (try? candidate.boundingBox(for: range))?.boundingBox,
                      rect.width > 0, rect.height > 0 else { return nil }
                return pixels(rect)
            }
            let boxes = TextRecognitionFusion.layoutTokens(text: string, ranges: ranges, measured: measured, lineBox: box)
            let tokens = zip(ranges, boxes).map { range, rect in
                OCRToken(text: String(string[range]), box: rect,
                         leadingSpace: range.lowerBound > string.startIndex
                            && string[string.index(before: range.lowerBound)].isWhitespace)
            }
            return OCRPassObservation(text: string, box: box, confidence: observation.confidence, tokens: tokens)
        }
        return OCRPass(label: label, group: group, observations: mapped)
    }

    /// One accurate, latest-revision VNRecognizeTextRequest.
    static func recognizeObservations(_ image: CGImage, languages: [String], autoDetect: Bool,
                                      correction: Bool, customWords: [String]) async throws
        -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                func makeRequest(_ langs: [String]) -> VNRecognizeTextRequest {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.revision = VNRecognizeTextRequest.currentRevision
                    let supported = Set(TextCaptureLanguages.supported)
                    let usable = langs.filter { supported.contains($0) }
                    if !usable.isEmpty { request.recognitionLanguages = usable }
                    request.automaticallyDetectsLanguage = autoDetect
                    request.usesLanguageCorrection = correction
                    if correction, !customWords.isEmpty { request.customWords = customWords }
                    return request
                }
                do {
                    let request = makeRequest(languages)
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    } catch {
                        // Some language combinations are rejected on older
                        // revisions; retry with only the lead language.
                        let fallback = makeRequest(Array(languages.prefix(1)))
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([fallback])
                        continuation.resume(returning: fallback.results ?? [])
                        return
                    }
                    continuation.resume(returning: request.results ?? [])
                } catch {
                    continuation.resume(throwing: EngineError.requestFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: VisionKit

    /// Live Text transcript, or nil when unavailable or slower than 10 s.
    static func liveTextTranscript(_ image: CGImage, locales: [String]) async -> String? {
        guard ImageAnalyzer.isSupported else { return nil }
        let supported = Set(ImageAnalyzer.supportedTextRecognitionLanguages)
        var configuration = ImageAnalyzer.Configuration(.text)
        let usable = locales.filter { supported.contains($0) }
        if !usable.isEmpty { configuration.locales = usable }
        let requestConfiguration = configuration
        return await TextAnalysisDeadline<String>.run(seconds: 10) {
            let analyzer = ImageAnalyzer()
            return try? await analyzer.analyze(image, orientation: .up, configuration: requestConfiguration).transcript
        }
    }

    // MARK: Barcodes

    /// Every symbology Vision supports (QR, Aztec, PDF417, EAN, Code 128…).
    static func detectBarcodes(_ image: CGImage, symbologies: [VNBarcodeSymbology]? = nil) async throws -> [TextCaptureBarcode] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.revision = VNDetectBarcodesRequest.currentRevision
                if let symbologies { request.symbologies = symbologies }
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    var seen = Set<String>()
                    let codes = (request.results ?? []).compactMap { observation -> TextCaptureBarcode? in
                        guard let payload = observation.payloadStringValue, !payload.isEmpty,
                              seen.insert(payload).inserted else { return nil }
                        return TextCaptureBarcode(payload: payload, symbology: observation.symbology.rawValue)
                    }
                    continuation.resume(returning: codes)
                } catch {
                    continuation.resume(throwing: EngineError.requestFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Image tools

enum TextCaptureImageTools {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// High-quality resample; capped at 40 MP so a huge capture cannot balloon.
    static func upscale(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor > 1 else { return image }
        let width = Int((CGFloat(image.width) * factor).rounded())
        let height = Int((CGFloat(image.height) * factor).rounded())
        guard width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Pads `region` (pixels, top-left origin) by part of its height, crops,
    /// and upscales small crops so a re-read has enough pixels.
    static func crop(_ image: CGImage, to region: CGRect) -> CGImage? {
        let pad = region.height * 0.35
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = region.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
        guard !rect.isNull, rect.width >= 4, rect.height >= 4, let cropped = image.cropping(to: rect) else { return nil }
        return cropped.height < 48 ? (upscale(cropped, by: 2) ?? cropped) : cropped
    }

    static func invert(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorInvert")
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Mean luminance (0 dark … 1 light) from a 32×32 grey thumbnail.
    static func meanLuminance(_ image: CGImage) -> Double {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return 1 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var sum = 0
        for i in 0..<(side * side) { sum += Int(pixels[i]) }
        return Double(sum) / Double(side * side * 255)
    }
}
