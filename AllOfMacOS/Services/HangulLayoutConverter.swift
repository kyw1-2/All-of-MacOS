import AppKit
import ApplicationServices

/// 7.22 (DeepSeek 7.21 report §4.7): text typed with the wrong input source
/// on the Korean 2-set (Dubeolsik) layout, converted to what was meant —
/// `dkssud` → `안녕`, `안녕` → `dkssud`. Pure and table driven.
///
/// Latin → Hangul runs the standard 2-set automaton: an initial, a medial
/// (vowels combine: ㅗ+ㅏ=ㅘ), an optional final (finals combine: ㄱ+ㅅ=ㄳ),
/// and a final that is followed by a vowel moves to the next syllable
/// (`rkqt` = 값, `rkqtl` = 갑시: the compound final gives its ㅅ away).
/// Hangul → Latin decomposes syllables into the keys that type them.
enum HangulLayoutConverter {
    // MARK: Tables

    /// The 2-set layout: key → compatibility jamo. Shift keys give the tense
    /// consonants and ㅒ ㅖ; other upper-case keys type the lower-case jamo.
    static let keyToJamo: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
    ]

    static let initials: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let medials: [Character] = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// Index 0 is "no final".
    static let finals: [Character?] = [nil] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map { Optional($0) }

    static let compoundMedials: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    static let compoundFinals: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]
    static let splitFinals: [Character: (Character, Character)] = Dictionary(uniqueKeysWithValues:
        compoundFinals.map { key, value in (value, (key.first!, key.last!)) })
    static let splitMedials: [Character: (Character, Character)] = Dictionary(uniqueKeysWithValues:
        compoundMedials.map { key, value in (value, (key.first!, key.last!)) })

    static let jamoToKey: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (key, jamo) in keyToJamo where map[jamo] == nil || key.isLowercase { map[jamo] = key }
        return map
    }()

    static func isVowel(_ jamo: Character) -> Bool { medials.contains(jamo) }
    static func isHangulSyllable(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }
    static func isJamo(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x3131...0x318E).contains(scalar.value)
    }

    // MARK: Direction

    enum Direction { case toHangul, toLatin }

    /// Hangul in the text means it was typed in Korean by mistake (convert to
    /// keys); otherwise it is Latin typed for Korean.
    static func direction(of text: String) -> Direction {
        text.contains(where: { isHangulSyllable($0) || isJamo($0) }) ? .toLatin : .toHangul
    }

    /// Converts in the direction the text suggests.
    static func convert(_ text: String) -> String {
        direction(of: text) == .toHangul ? toHangul(text) : toLatin(text)
    }

    /// True when the letters compose into whole syllables on the 2-set
    /// layout, with no jamo left over ("dkssud" yes, "qqq" no). Many English
    /// words pass too, so this only ranks; conversion stays an explicit act.
    static func looksLikeMistypedKorean(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, letters.allSatisfy({ keyToJamo[$0] != nil || keyToJamo[Character($0.lowercased())] != nil }) else { return false }
        let converted = toHangul(letters)
        return !converted.contains(where: isJamo)
    }

    // MARK: Latin → Hangul

    static func toHangul(_ text: String) -> String {
        var out = ""
        var run: [Character] = []
        func flush() { out += compose(run); run.removeAll() }
        for c in text {
            if let jamo = keyToJamo[c] ?? keyToJamo[Character(c.lowercased())] { run.append(jamo) }
            else { flush(); out.append(c) }
        }
        flush()
        return out
    }

    /// Composes a run of compatibility jamo with the 2-set automaton.
    static func compose(_ jamo: [Character]) -> String {
        var out = ""
        var initial: Character?
        var medial: Character?
        var final: Character?

        func emit() {
            if let i = initial, let m = medial { out.append(syllable(i, m, final)) }
            else {
                if let i = initial { out.append(i) }
                if let m = medial { out.append(m) }
                if let f = final { out.append(f) }
            }
            initial = nil; medial = nil; final = nil
        }

        for j in jamo {
            if isVowel(j) {
                if initial != nil, medial == nil {
                    medial = j
                } else if let m = medial, final == nil, let combined = compoundMedials[String([m, j])] {
                    medial = combined
                } else if let f = final, medial != nil {
                    // The final moves to start the next syllable (a compound
                    // final gives up only its second part).
                    if let (keep, move) = splitFinals[f] {
                        final = keep; emit(); initial = move
                    } else {
                        final = nil; emit(); initial = f
                    }
                    medial = j
                } else {
                    emit(); medial = j
                }
            } else {
                if initial == nil, medial == nil {
                    initial = j
                } else if initial != nil, medial == nil {
                    emit(); initial = j
                } else if initial == nil {
                    // A lone vowel is not a syllable to attach finals to.
                    emit(); initial = j
                } else if final == nil, finals.contains(j) {
                    final = j
                } else if let f = final, let combined = compoundFinals[String([f, j])] {
                    final = combined
                } else {
                    emit(); initial = j
                }
            }
        }
        emit()
        return out
    }

    static func syllable(_ initial: Character, _ medial: Character, _ final: Character?) -> Character {
        guard let i = initials.firstIndex(of: initial), let m = medials.firstIndex(of: medial),
              let f = finals.firstIndex(of: final) else {
            return Character(String([initial, medial] + (final.map { [$0] } ?? [])))
        }
        let value = 0xAC00 + (i * 21 + m) * 28 + f
        return Character(UnicodeScalar(value)!)
    }

    // MARK: Hangul → Latin

    static func toLatin(_ text: String) -> String {
        var out = ""
        for c in text {
            if isHangulSyllable(c), let scalar = c.unicodeScalars.first {
                let index = Int(scalar.value) - 0xAC00
                let i = index / (21 * 28), m = (index % (21 * 28)) / 28, f = index % 28
                out += keys(for: initials[i]) + keys(for: medials[m]) + (finals[f].map(keys(for:)) ?? "")
            } else if isJamo(c) {
                out += keys(for: c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func keys(for jamo: Character) -> String {
        if let key = jamoToKey[jamo] { return String(key) }
        if let (a, b) = splitMedials[jamo] ?? splitFinals[jamo] { return keys(for: a) + keys(for: b) }
        return String(jamo)
    }
}

/// The "Fix Korean/English Typing" action: convert the selection, or the
/// word before the caret when nothing is selected (⌥⇧← selects it), paste
/// the result in place, then switch to the input source that was meant.
@MainActor
enum KeyboardLayoutFixer {
    static func run(isCancelled: @escaping () -> Bool, completion: @escaping (Bool, String?) -> Void) {
        guard AXIsProcessTrusted() else { completion(false, "Fixing typing needs Accessibility permission"); return }
        SelectedTextReader.read { selected in
            if let selected, !selected.isEmpty {
                apply(selected, isCancelled: isCancelled, completion: completion)
                return
            }
            // ⌥⇧← : select the word before the caret, then read it.
            guard SyntheticInput.key(123, flags: [.maskAlternate, .maskShift]) else { completion(false, "Could not select the last word"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SelectedTextReader.read { word in
                    guard let word, !word.isEmpty else { completion(false, "No text to fix"); return }
                    apply(word, isCancelled: isCancelled, completion: completion)
                }
            }
        }
    }

    private static func apply(_ text: String, isCancelled: () -> Bool, completion: @escaping (Bool, String?) -> Void) {
        guard !isCancelled(), text.count <= 10_000 else { completion(false, nil); return }
        let direction = HangulLayoutConverter.direction(of: text)
        let converted = HangulLayoutConverter.convert(text)
        guard converted != text else { completion(true, "Nothing to convert"); return }
        ExtendedActions.pasteString(converted) { ok in
            if ok { switchInputSource(korean: direction == .toHangul) }
            completion(ok, nil)
        }
    }

    /// The first enabled Korean source, or the first ASCII-capable one.
    static func switchInputSource(korean: Bool) {
        let sources = InputSources.enabled()
        let target = korean ? sources.first { $0.id.localizedCaseInsensitiveContains("Korean") || $0.id.contains("2SetKorean") }
            : sources.first { id in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(id.id) }
              ?? sources.first { !$0.id.localizedCaseInsensitiveContains("Korean") && $0.id.hasPrefix("com.apple.keylayout.") }
        if let target { _ = InputSources.select(target.id) }
    }
}
