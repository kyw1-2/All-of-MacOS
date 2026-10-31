import Foundation

/// Hint labels: unique, prefix-free (no label starts another one, so a
/// complete label acts at once), as short as the count allows, and made of
/// the best keys first.
enum ClickHintsLabels {
    /// `count` labels from `alphabet` (best character first), shortest first.
    ///
    /// With n characters and more than n targets, labels have length L − 1
    /// and L, where L is the smallest length with n^L ≥ count. The first k
    /// strings of length L − 1 (in alphabet order) stay labels, with k as
    /// large as possible; every other string of that length becomes a prefix
    /// for n labels of length L. So the best keys become the short labels,
    /// the weakest keys become prefixes, and every prefix group has at least
    /// two labels.
    static func make(count: Int, alphabet: [Character]) -> [String] {
        guard count > 0 else { return [] }
        let characters = unique(alphabet)
        guard characters.count >= 2 else {
            // One character can only label one target without prefixes.
            return characters.first.map { [String($0)] } ?? []
        }
        let n = characters.count
        if count <= n { return characters.prefix(count).map { String($0) } }

        // Smallest L with n^L ≥ count.
        var length = 1
        var capacity = n
        while capacity < count {
            length += 1
            capacity *= n
        }
        let shorterTotal = capacity / n                    // n^(L−1) strings of length L − 1
        let kept = min(shorterTotal - 1, (capacity - count) / (n - 1))
        let shorter = strings(length: length - 1, characters: characters, limit: shorterTotal)
        var labels = Array(shorter.prefix(kept))
        var needed = count - kept
        for prefix in shorter.dropFirst(kept) where needed > 0 {
            for character in characters where needed > 0 {
                labels.append(prefix + String(character))
                needed -= 1
            }
        }
        return labels
    }

    /// The labels for `count` targets with the person's alphabet.
    static func make(count: Int, alphabet: ClickHintsAlphabet) -> [String] {
        make(count: count, alphabet: alphabet.characters(forCount: count))
    }

    /// Gives the labels (shortest first) to targets in rank order, so the
    /// most likely target gets the shortest, most comfortable label.
    /// `ranked` lists target indices, most likely first; the result is
    /// indexed by target.
    static func assign(_ labels: [String], toRanked ranked: [Int], targetCount: Int) -> [String?] {
        var result = [String?](repeating: nil, count: targetCount)
        for (label, index) in zip(labels, ranked) where result.indices.contains(index) {
            result[index] = label
        }
        return result
    }

    /// All strings of `length` over `characters` in alphabet order.
    private static func strings(length: Int, characters: [Character], limit: Int) -> [String] {
        var current = [""]
        for _ in 0..<length {
            var next: [String] = []
            next.reserveCapacity(min(limit, current.count * characters.count))
            for prefix in current {
                for character in characters { next.append(prefix + String(character)) }
            }
            current = next
        }
        return current
    }

    private static func unique(_ characters: [Character]) -> [Character] {
        var seen = Set<Character>()
        return characters.compactMap { character in
            let lower = Character(character.lowercased())
            return seen.insert(lower).inserted ? lower : nil
        }
    }
}
