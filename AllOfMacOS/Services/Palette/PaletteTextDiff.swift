import Foundation

// AOM 7.12 (Codex 30-app spec #2, Kaleidoscope's text diff): two clipboard
// texts compared line by line, and inside a changed line the characters
// that differ. Characters are grapheme clusters, so a Korean syllable or
// an emoji is never cut in half. Pure: the tests run on strings.
enum PaletteTextDiff {
    enum LineChange: Equatable {
        case same(String)
        case removed(String)
        case added(String)
        /// One line replaced by another; `old`/`new` carry the changed span.
        case changed(old: String, new: String, oldSpan: Range<Int>, newSpan: Range<Int>)
    }

    /// Lines of `old` against `new`. A removal followed by an addition
    /// pairs up as a changed line.
    static func lines(_ old: String, _ new: String, shouldStop: () -> Bool = { false }) -> [LineChange] {
        guard !shouldStop() else { return [] }
        let a = split(old), b = split(new)
        guard !shouldStop() else { return [] }
        let ops = script(a, b, shouldStop: shouldStop)
        guard !shouldStop() else { return [] }
        var result: [LineChange] = []
        var index = 0
        while index < ops.count {
            if index % 64 == 0, shouldStop() { return [] }
            switch ops[index] {
            case .same(let line): result.append(.same(line)); index += 1
            case .removed:
                // A run of removals then a run of additions: pair them in order.
                var removed: [String] = [], added: [String] = []
                while index < ops.count, case .removed(let line) = ops[index] { removed.append(line); index += 1 }
                while index < ops.count, case .added(let line) = ops[index] { added.append(line); index += 1 }
                let paired = min(removed.count, added.count)
                for i in 0..<paired {
                    let (oldSpan, newSpan) = span(removed[i], added[i])
                    result.append(.changed(old: removed[i], new: added[i], oldSpan: oldSpan, newSpan: newSpan))
                }
                result += removed.dropFirst(paired).map { .removed($0) }
                result += added.dropFirst(paired).map { .added($0) }
            case .added(let line): result.append(.added(line)); index += 1
            case .changed: index += 1
            }
        }
        return result
    }

    /// Only the changes (the rows ↑↓ steps through).
    static func changes(_ old: String, _ new: String, shouldStop: () -> Bool = { false }) -> [LineChange] {
        lines(old, new, shouldStop: shouldStop).filter { if case .same = $0 { return false }; return true }
    }

    /// What a trailing newline reads as in a row.
    static let newlineAtEnd = "⏎ (newline at end)"

    /// Lines with the trailing newline kept apart: "a\n" and "a" differ in
    /// their last line, which the diff reports as "(no newline at end)".
    /// 7.13 (GPT F06): the marker line ends in a newline character, which no
    /// real line can contain, so a text that literally says "⏎ (newline at
    /// end)" never compares equal to a trailing newline. CRLF is read as LF.
    static func split(_ text: String) -> [String] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast(); lines.append(newlineAtEnd + "\n") }
        return lines
    }

    /// The row text of a line (the trailing-newline marker without its own newline).
    static func display(_ line: String) -> String {
        line.hasSuffix("\n") ? String(line.dropLast()) : line
    }

    /// The shortest edit script. 7.13 (GPT F05): the lines both texts start
    /// and end with are taken off first, so equal texts of any size compare
    /// in one pass and a one-line edit in a long text stays exact; only the
    /// differing middle runs the LCS, and Swift's Myers difference takes a
    /// middle too big for the table.
    private static func script(_ a: [String], _ b: [String], shouldStop: () -> Bool) -> [LineChange] {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let middle = middleScript(Array(a[head..<(a.count - tail)]), Array(b[head..<(b.count - tail)]), shouldStop: shouldStop)
        return a[..<head].map { .same($0) } + middle + a[(a.count - tail)...].map { .same($0) }
    }

    private static func middleScript(_ a: [String], _ b: [String], shouldStop: () -> Bool) -> [LineChange] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return a.map { .removed($0) } + b.map { .added($0) } }
        guard !shouldStop() else { return [] }
        guard n <= 4_000_000 / m else {
            // The standard library Myers pass itself is not interruptible. Never
            // start it when superseded, or convert/publish its cancelled result.
            return myers(a, b, shouldStop: shouldStop)
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            // 7.16 (GPT V15): a superseded comparison stops between rows.
            if i % 64 == 0, shouldStop() { return [] }
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [LineChange] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ops.append(.same(a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { ops.append(.removed(a[i])); i += 1 }
            else { ops.append(.added(b[j])); j += 1 }
        }
        while i < n { ops.append(.removed(a[i])); i += 1 }
        while j < m { ops.append(.added(b[j])); j += 1 }
        return ops
    }

    /// Swift's own Myers difference, for middles too big for the LCS table.
    private static func myers(_ a: [String], _ b: [String], shouldStop: () -> Bool) -> [LineChange] {
        guard !shouldStop() else { return [] }
        let difference = b.difference(from: a)
        guard !shouldStop() else { return [] }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var ops: [LineChange] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { ops.append(.removed(a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { ops.append(.added(b[j])); j += 1 }
            else if i < a.count, j < b.count { ops.append(.same(a[i])); i += 1; j += 1 }
            else if i < a.count { ops.append(.removed(a[i])); i += 1 }
            else { ops.append(.added(b[j])); j += 1 }
        }
        return ops
    }

    /// The differing middle of two lines, in characters: the common prefix
    /// and suffix are cut ("결제액 120,000원" / "결제액 125,000원" → "0"/"5").
    static func span(_ old: String, _ new: String) -> (Range<Int>, Range<Int>) {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (prefix..<(a.count - suffix), prefix..<(b.count - suffix))
    }

    /// "결제액 12[0],000원" — the span in brackets, so it reads without colour.
    static func marked(_ line: String, _ span: Range<Int>) -> String {
        let characters = Array(line)
        guard span.lowerBound <= span.upperBound, span.upperBound <= characters.count else { return line }
        let before = String(characters[..<span.lowerBound])
        let middle = String(characters[span])
        let after = String(characters[span.upperBound...])
        return middle.isEmpty ? "\(before)‸\(after)" : "\(before)[\(middle)]\(after)"
    }
}

/// 7.14 (Codex 7.13 S2): the comparison screen's one job. A big pair is
/// compared off the main thread (≈ 0.3 s for two 1 MB texts on an M1) while
/// the screen says "Comparing…"; a small one at once. The result — which
/// holds lines of both copies — belongs to the open screen and is dropped
/// when it closes. 7.16 (GPT V15): one comparison at a time on a serial
/// queue, latest wins — a newer request or `clear()` bumps the generation
/// and the running one stops at its next check; the result is kept only for
/// the exact texts it was asked about.
@MainActor
final class PaletteDiffJob {
    static let shared = PaletteDiffJob()
    /// Below this many UTF-8 bytes in all, comparing on the spot is quicker than a hop.
    static let inlineLimit = 64 * 1024

    private var request: (old: String, new: String)?
    private var result: [PaletteTextDiff.LineChange]?
    private var running = false
    // One active worker and one replaceable pending request. Never queue a
    // closure retaining every superseded clipboard pair.
    private var workerBusy = false
    private var pendingReady: (@MainActor () -> Void)?
    private let worker = DispatchQueue(label: "aom.palette.diff", qos: .userInitiated)
    nonisolated private static let generationLock = NSLock()
    nonisolated(unsafe) private static var generation = 0

    nonisolated private static func currentGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    private static func bump() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation &+= 1
        return generation
    }

    /// The changes, or nil while they are being worked out (`ready` runs once they are).
    func changes(_ old: String, _ new: String, ready: @escaping @MainActor () -> Void) -> [PaletteTextDiff.LineChange]? {
        if let request, request.old == old, request.new == new {
            if let result { return result }
            if running { return nil }
        }
        _ = Self.bump()
        request = (old, new)
        pendingReady = nil
        result = nil
        if old.utf8.count + new.utf8.count <= Self.inlineLimit {
            let changes = PaletteTextDiff.changes(old, new)
            result = changes
            running = false
            return changes
        }
        running = true
        pendingReady = ready
        launchPending()
        return nil
    }

    private func launchPending() {
        guard !workerBusy, let request, let ready = pendingReady else { return }
        let (old, new) = request
        let ticket = Self.currentGeneration()
        pendingReady = nil
        workerBusy = true
        worker.async {
            let changes = Self.currentGeneration() == ticket
                ? PaletteTextDiff.changes(old, new) { Self.currentGeneration() != ticket }
                : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let job = PaletteDiffJob.shared
                    job.workerBusy = false
                    if Self.currentGeneration() == ticket, let request = job.request,
                       request.old == old, request.new == new {
                        job.result = changes
                        job.running = false
                        ready()
                    }
                    job.launchPending()
                }
            }
        }
    }

    /// The screen closed: nothing of either copy stays, and a running
    /// comparison stops.
    func clear() {
        _ = Self.bump()
        request = nil
        pendingReady = nil
        result = nil
        running = false
    }
}
