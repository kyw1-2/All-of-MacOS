import Foundation

/// Fuzzy matching for the palette, menu search and the window switcher.
/// Case and accents don't matter. Tiers, best first: the whole text, a
/// prefix, the start of a word, anywhere, then the letters in order with
/// bonuses for word starts and runs ("gc" → "Google Chrome"). Hangul
/// initial consonants match their syllables, so "ㅋㅋㅇㅌ" finds "카카오톡".
enum PaletteFuzzy {
    static let exactScore = 1000
    static let prefixScore = 900
    static let wordPrefixScore = 800
    static let containsScore = 700
    /// Subsequence matches score between 100 and 600.
    static let subsequenceFloor = 100

    /// Higher is better; nil when `query` does not match `candidate`.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = fold(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return nil }
        let text = fold(candidate)
        guard !text.isEmpty else { return nil }
        let original = Array(candidate)
        let spaced = String(fold(query)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let haystack = String(text)

        if haystack == spaced { return exactScore }
        if haystack.hasPrefix(spaced) { return prefixScore - min(99, text.count - spaced.count) }
        if let word = wordStartOffset(of: spaced, in: text, original: original) {
            return wordPrefixScore - min(99, word)
        }
        if let range = haystack.range(of: spaced) {
            return containsScore - min(99, haystack.distance(from: haystack.startIndex, to: range.lowerBound))
        }
        // Initial consonants: "ㅋㅋㅇ" is a prefix of 카카오톡's ㅋㅋㅇㅌ.
        if needle.allSatisfy(isConsonantJamo) {
            let initialLetters = String(text.map { initialConsonant(of: $0) ?? $0 })
            let compact = String(needle)
            if initialLetters.hasPrefix(compact) { return wordPrefixScore + 50 - min(49, text.count - needle.count) }
            if let range = initialLetters.range(of: compact) {
                return containsScore - min(99, initialLetters.distance(from: initialLetters.startIndex, to: range.lowerBound))
            }
        }
        return subsequence(needle, in: text, original: original)
    }

    /// The best of several fields (an app name and a window title, a menu
    /// item's title and its path); `penalties` lower weaker fields.
    static func bestScore(_ query: String, fields: [(String, Int)]) -> Int? {
        fields.compactMap { field, penalty in score(query, field).map { $0 - penalty } }.max()
    }

    // MARK: Pieces

    /// Lower-cased, accents removed, one Character per Character so offsets
    /// line up with the original text. ASCII and Hangul take a fast path
    /// (folding would also decompose a Hangul syllable into its jamo).
    static func fold(_ text: String) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if let ascii = character.asciiValue {
                result.append(ascii >= 65 && ascii <= 90 ? Character(Unicode.Scalar(ascii + 32)) : character)
                continue
            }
            if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
               (0xAC00...0xD7A3).contains(scalar.value) || (0x3131...0x318E).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                result.append(character)
                continue
            }
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                   locale: nil)
            result.append(folded.first ?? character)
        }
        return result
    }

    private static func isBoundary(_ original: [Character], _ index: Int) -> Bool {
        guard index > 0, index < original.count else { return index == 0 }
        let previous = original[index - 1]
        let current = original[index]
        if previous.isWhitespace || previous.isPunctuation || previous.isSymbol { return true }
        if previous.isLowercase && current.isUppercase { return true }
        if previous.isLetter != current.isLetter { return true }
        return false
    }

    private static func wordStartOffset(of needle: String, in text: [Character], original: [Character]) -> Int? {
        let needleChars = Array(needle)
        guard needleChars.count <= text.count else { return nil }
        var wordIndex = 0
        for start in 1..<max(1, text.count - needleChars.count + 1) where isBoundary(original, start) {
            wordIndex += 1
            if Array(text[start..<start + needleChars.count]) == needleChars { return wordIndex * 5 + start }
        }
        return nil
    }

    private static func subsequence(_ needle: [Character], in text: [Character], original: [Character]) -> Int? {
        var total = 0
        var cursor = 0
        var previous = -2
        for wanted in needle {
            guard let found = (cursor..<text.count).first(where: { matches(wanted, text[$0]) }) else { return nil }
            var points = 10
            if isBoundary(original, found) { points += 20 }
            if found == previous + 1 { points += 15 }
            if previous >= 0 { points -= min(10, found - previous - 1) }
            total += points
            previous = found
            cursor = found + 1
        }
        let lengthPenalty = min(50, text.count / 4)
        return subsequenceFloor + max(0, min(499, total - lengthPenalty))
    }

    private static func matches(_ wanted: Character, _ candidate: Character) -> Bool {
        if wanted == candidate { return true }
        if isConsonantJamo(wanted), let initial = initialConsonant(of: candidate) { return initial == wanted }
        return false
    }

    // MARK: Hangul

    private static let initials: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
                                                "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    /// ㄱ … ㅎ (Hangul Compatibility Jamo consonants).
    static func isConsonantJamo(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0x3131...0x314E).contains(scalar.value)
    }

    /// 카 → ㅋ; nil for anything that is not a precomposed syllable.
    static func initialConsonant(of character: Character) -> Character? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let index = Int(scalar.value - 0xAC00) / (21 * 28)
        return initials.indices.contains(index) ? initials[index] : nil
    }
}
