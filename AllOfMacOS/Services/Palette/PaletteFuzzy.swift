import Foundation

/// Fuzzy matching for the palette, menu search, bookmarks and the window
/// switcher. Case, accents and full-width forms don't matter. Tiers, best
/// first: the whole text, a prefix, the start of a word, anywhere, then the
/// letters in order starting at a word start, with bonuses for word starts
/// and runs ("gc" → "Google Chrome"). Hangul initial consonants match their
/// syllables, so "ㅋㅋㅇㅌ" finds "카카오톡".
///
/// Works on Unicode scalars, folds the query once per search and rejects a
/// candidate with one in-order pass before scoring it: about 2,000 menu
/// items and their paths per keystroke without a visible pause.
enum PaletteFuzzy {
    static let exactScore = 1000
    static let prefixScore = 900
    static let wordPrefixScore = 800
    static let containsScore = 700
    /// Subsequence matches score between 100 and 600.
    static let subsequenceFloor = 100

    /// A folded query, prepared once per search.
    struct Query {
        /// Without spaces, for the in-order match.
        let needle: [UInt32]
        /// Words joined by single spaces, for the substring tiers.
        let spaced: [UInt32]
        let isAllJamo: Bool

        init?(_ text: String) {
            var spaced: [UInt32] = []
            var pendingSpace = false
            for scalar in text.unicodeScalars {
                if scalar.properties.isWhitespace {
                    pendingSpace = !spaced.isEmpty
                    continue
                }
                guard let folded = PaletteFuzzy.fold(scalar) else { continue }
                if pendingSpace { spaced.append(0x20); pendingSpace = false }
                spaced.append(folded)
            }
            guard !spaced.isEmpty else { return nil }
            self.spaced = spaced
            needle = spaced.filter { $0 != 0x20 }
            isAllJamo = needle.allSatisfy(PaletteFuzzy.isConsonantJamo)
        }
    }

    /// A folded candidate with its word starts.
    struct Candidate {
        let scalars: [UInt32]
        let starts: [Bool]

        init(_ text: String) {
            var scalars: [UInt32] = []
            var starts: [Bool] = []
            scalars.reserveCapacity(text.utf8.count)
            starts.reserveCapacity(text.utf8.count)
            var previous: Kind?
            for scalar in text.unicodeScalars {
                guard let folded = PaletteFuzzy.fold(scalar) else { continue }
                let kind = Kind(scalar)
                let start: Bool
                if let previous {
                    start = previous.isSeparator || (previous.isLower && kind.isUpper) || previous.isLetter != kind.isLetter
                } else {
                    start = true
                }
                scalars.append(folded)
                starts.append(start)
                previous = kind
            }
            self.scalars = scalars
            self.starts = starts
        }
    }

    private struct Kind {
        let isSeparator: Bool
        let isLetter: Bool
        let isUpper: Bool
        let isLower: Bool

        init(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            if value < 0x80 {
                let upper = value >= 65 && value <= 90
                let lower = value >= 97 && value <= 122
                isUpper = upper
                isLower = lower
                isLetter = upper || lower
                isSeparator = !isLetter && !(value >= 48 && value <= 57)
                return
            }
            let properties = scalar.properties
            isUpper = properties.isUppercase
            isLower = properties.isLowercase
            isLetter = properties.isAlphabetic
            switch properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator, .connectorPunctuation, .dashPunctuation,
                 .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                isSeparator = true
            default:
                isSeparator = false
            }
        }
    }

    /// Higher is better; nil when `query` does not match `candidate`.
    static func score(_ query: String, _ candidate: String) -> Int? {
        guard let prepared = Query(query) else { return nil }
        return score(prepared, Candidate(candidate))
    }

    /// The best of several fields (an app name and a window title, a menu
    /// item's title and its path); each field's penalty lowers it.
    static func bestScore(_ query: String, fields: [(String, Int)]) -> Int? {
        guard let prepared = Query(query) else { return nil }
        return bestScore(prepared, fields: fields)
    }

    static func bestScore(_ query: Query, fields: [(String, Int)]) -> Int? {
        var best: Int?
        for (field, penalty) in fields {
            guard let value = score(query, Candidate(field)) else { continue }
            best = max(best ?? Int.min, value - penalty)
        }
        return best
    }

    static func score(_ query: Query, _ text: Candidate) -> Int? {
        let haystack = text.scalars
        guard !haystack.isEmpty, inOrder(query.needle, in: haystack) else { return nil }
        let spaced = query.spaced
        if haystack == spaced { return exactScore }
        if haystack.starts(with: spaced) { return prefixScore - min(99, haystack.count - spaced.count) }
        if let offset = wordStartOffset(spaced, in: text) { return wordPrefixScore - min(99, offset) }
        if let index = firstIndex(of: spaced, in: haystack) { return containsScore - min(99, index) }
        if query.isAllJamo {
            let initials = haystack.map { initialConsonant($0) ?? $0 }
            if initials.starts(with: query.needle) {
                return wordPrefixScore + 50 - min(49, haystack.count - query.needle.count)
            }
            if let index = firstIndex(of: query.needle, in: initials) { return containsScore - min(99, index) }
        }
        return subsequence(query.needle, in: text)
    }

    // MARK: Pieces

    /// One scalar lower-cased, without accents, full-width forms as ASCII;
    /// nil for combining marks (decomposed accents). Hangul and Han are kept
    /// as they are: folding would split a syllable into its jamo.
    static func fold(_ scalar: Unicode.Scalar) -> UInt32? {
        let value = scalar.value
        if value < 0x80 { return value >= 65 && value <= 90 ? value + 32 : value }
        if (0xAC00...0xD7A3).contains(value) || (0x3131...0x318E).contains(value) || (0x1100...0x11FF).contains(value)
            || (0x4E00...0x9FFF).contains(value) { return value }
        if (0xFF01...0xFF5E).contains(value) {
            let ascii = value - 0xFEE0
            return ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii
        }
        let properties = scalar.properties
        if properties.generalCategory == .nonspacingMark || properties.generalCategory == .enclosingMark { return nil }
        guard properties.isAlphabetic else { return value }
        let folded = String(Character(scalar)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.unicodeScalars.first?.value ?? value
    }

    private static func inOrder(_ needle: [UInt32], in haystack: [UInt32]) -> Bool {
        var index = 0
        for wanted in needle {
            while index < haystack.count, !matches(wanted, haystack[index]) { index += 1 }
            guard index < haystack.count else { return false }
            index += 1
        }
        return true
    }

    private static func firstIndex(of needle: [UInt32], in haystack: [UInt32]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var start = 0
        while start + needle.count <= haystack.count {
            if haystack[start] == needle[0] {
                var offset = 1
                while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return start }
            }
            start += 1
        }
        return nil
    }

    private static func wordStartOffset(_ needle: [UInt32], in text: Candidate) -> Int? {
        let haystack = text.scalars
        guard needle.count <= haystack.count else { return nil }
        var wordIndex = 0
        var start = 1
        while start + needle.count <= haystack.count {
            if text.starts[start] {
                wordIndex += 1
                var offset = 0
                while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return wordIndex * 5 + start }
            }
            start += 1
        }
        return nil
    }

    private static func subsequence(_ needle: [UInt32], in text: Candidate) -> Int? {
        let haystack = text.scalars
        // The match has to start where a word starts ("gc" finds Google
        // Chrome, not "Big cache"); after that, letters may skip ahead.
        guard let first = needle.first,
              let start = haystack.indices.first(where: { text.starts[$0] && matches(first, haystack[$0]) }) else { return nil }
        var total = 0
        var cursor = start
        var previous = -2
        for wanted in needle {
            while cursor < haystack.count, !matches(wanted, haystack[cursor]) { cursor += 1 }
            guard cursor < haystack.count else { return nil }
            var points = 10
            if text.starts[cursor] { points += 20 }
            if cursor == previous + 1 { points += 15 }
            if previous >= 0 { points -= min(10, cursor - previous - 1) }
            total += points
            previous = cursor
            cursor += 1
        }
        let lengthPenalty = min(50, haystack.count / 4)
        return subsequenceFloor + max(0, min(499, total - lengthPenalty))
    }

    private static func matches(_ wanted: UInt32, _ candidate: UInt32) -> Bool {
        if wanted == candidate { return true }
        guard isConsonantJamo(wanted), let initial = initialConsonant(candidate) else { return false }
        return initial == wanted
    }

    // MARK: Hangul

    /// ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ as Compatibility Jamo.
    private static let initials: [UInt32] = [0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
                                             0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E]

    static func isConsonantJamo(_ value: UInt32) -> Bool { (0x3131...0x314E).contains(value) }

    /// ㄱ … ㅎ (Hangul Compatibility Jamo consonants).
    static func isConsonantJamo(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return isConsonantJamo(scalar.value)
    }

    static func initialConsonant(_ value: UInt32) -> UInt32? {
        guard (0xAC00...0xD7A3).contains(value) else { return nil }
        return initials[Int(value - 0xAC00) / (21 * 28)]
    }

}
