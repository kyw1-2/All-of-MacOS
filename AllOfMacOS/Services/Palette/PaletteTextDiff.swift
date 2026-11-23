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
    static func lines(_ old: String, _ new: String) -> [LineChange] {
        let a = split(old), b = split(new)
        let ops = script(a, b)
        var result: [LineChange] = []
        var index = 0
        while index < ops.count {
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
    static func changes(_ old: String, _ new: String) -> [LineChange] {
        lines(old, new).filter { if case .same = $0 { return false }; return true }
    }

    /// Lines with the trailing newline kept apart: "a\n" and "a" differ in
    /// their last line, which the diff reports as "(no newline at end)".
    static func split(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast(); lines.append("⏎ (newline at end)") }
        return lines
    }

    /// The shortest edit script (LCS), capped so a huge pair stays quick.
    private static func script(_ a: [String], _ b: [String]) -> [LineChange] {
        let n = a.count, m = b.count
        guard n * m <= 4_000_000 else {
            return a.map { .removed($0) } + b.map { .added($0) }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
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
