import Foundation

// AOM 7.2 (Oracle report 05 §3-A): emoji and symbols by name in the
// launcher — ":fire" or "불" finds 🔥 and ↩ types it into the app in front.
// The names come from macOS itself (CoreEmoji's AppleName.strings, the
// names the Character Viewer searches, read at runtime and never bundled),
// in English and the user's first language; Unicode's scalar names stand in
// when a future macOS moves those files.

struct PaletteEmoji: Hashable, Identifiable {
    let glyph: String
    /// "fire", lowercased.
    let name: String
    /// The name in the user's other language ("불"): the first non-English
    /// one in Language & Region, searched as well as the English name.
    let localizedName: String?
    /// Short words people type for it ("불", "좋아요"), beside the names.
    var keywords: [String] = []

    var id: String { glyph }

    /// The row's title in the user's first language.
    var displayName: String {
        PaletteEmojiIndex.prefersLocalNames ? (localizedName ?? name.capitalizedFirst) : name.capitalizedFirst
    }

    /// The other name, under the title.
    var otherName: String? {
        PaletteEmojiIndex.prefersLocalNames ? (localizedName == nil ? nil : name.capitalizedFirst) : localizedName
    }

    /// "U+1F525" (variation selectors left out).
    var codePoints: String {
        glyph.unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }
            .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

enum PaletteEmojiIndex {
    static let resources = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources",
                               isDirectory: true)

    /// Shown before anything is typed, after the ones used recently.
    static let favourites = ["😀", "😂", "🥲", "😊", "😍", "🤔", "😭", "😅", "🙏", "👍", "👏", "🙌", "👀", "❤️", "🔥",
                             "✨", "🎉", "✅", "❌", "⚠️", "💯", "🚀", "📌", "💡"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [PaletteEmoji]?

    /// Every emoji, read once (about 1,900 names per language).
    static func all() -> [PaletteEmoji] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    static func load(resources: URL = resources, languages: [String] = Locale.preferredLanguages) -> [PaletteEmoji] {
        let english = names(at: resources.appendingPathComponent("en.lproj/AppleName.strings"))
        guard !english.isEmpty else { return unicodeFallback() }
        // en-KR first and ko-KR second (this Mac) still searches "불".
        var localized: [String: String] = [:]
        for language in languages {
            let code = String(language.split(separator: "-").first ?? "")
            guard !code.isEmpty, code != "en" else { continue }
            let table = names(at: resources.appendingPathComponent("\(code).lproj/AppleName.strings"))
            if !table.isEmpty { localized = table; break }
        }
        return english.map { glyph, name in
            let local = localized[glyph].flatMap { $0.lowercased() == name.lowercased() ? nil : $0 }
            return PaletteEmoji(glyph: glyph, name: name.lowercased(), localizedName: local,
                                keywords: koreanWords[glyph] ?? koreanWords[glyph.replacingOccurrences(of: "\u{FE0F}", with: "")] ?? [])
        }
        .sorted(by: codePointOrder)
    }

    /// A .strings table (binary or text plist) of glyph → name.
    static func names(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return table
    }

    /// Single-scalar emoji with Unicode's names, when CoreEmoji is missing.
    static func unicodeFallback() -> [PaletteEmoji] {
        let ranges: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F,
                                             0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF]
        return ranges.flatMap { $0 }.compactMap { value -> PaletteEmoji? in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                  let name = scalar.properties.name else { return nil }
            return PaletteEmoji(glyph: String(scalar), name: name.lowercased(), localizedName: nil)
        }
    }

    private static func codePointOrder(_ lhs: PaletteEmoji, _ rhs: PaletteEmoji) -> Bool {
        let l = lhs.glyph.unicodeScalars.map(\.value), r = rhs.glyph.unicodeScalars.map(\.value)
        return l.lexicographicallyPrecedes(r)
    }

    /// The everyday Korean words for the emoji typed most (macOS's own
    /// Korean names miss some of them: 🔥 has none).
    static let koreanWords: [String: [String]] = [
        "🔥": ["불", "불꽃", "핫"], "❤️": ["하트", "사랑"], "❤": ["하트", "사랑"], "💔": ["상처", "이별"], "💕": ["하트", "사랑"],
        "👍": ["좋아요", "따봉", "엄지", "최고"], "👎": ["싫어요", "별로"], "👏": ["박수", "짝짝"], "🙌": ["만세", "환호"], "🙏": ["기도", "감사", "부탁"],
        "👌": ["오케이", "좋아"], "✌️": ["브이", "피스"], "🤝": ["악수", "협력"], "💪": ["힘", "근육", "화이팅"], "👋": ["안녕", "손인사"],
        "😀": ["웃음", "미소"], "😃": ["웃음"], "😄": ["웃음", "기쁨"], "😁": ["활짝", "웃음"], "😂": ["웃겨", "눈물", "빵터짐", "ㅋㅋ"],
        "🤣": ["데굴데굴", "ㅋㅋㅋ"], "😊": ["미소", "행복"], "🥰": ["사랑", "설렘"], "😍": ["반함", "하트눈"], "😘": ["뽀뽀", "키스"],
        "😎": ["멋짐", "선글라스"], "🤔": ["생각", "고민", "흠"], "🤨": ["의심"], "😐": ["무표정"], "😶": ["침묵"], "🙄": ["어이없음"],
        "😏": ["썩소"], "😴": ["잠", "졸림", "쿨쿨"], "😪": ["졸림"], "😮": ["놀람"], "😲": ["깜짝"], "😳": ["당황", "부끄"],
        "🥺": ["애원", "부탁"], "😢": ["슬픔", "눈물"], "😭": ["오열", "울음", "엉엉", "ㅠㅠ"], "😤": ["씩씩"], "😡": ["화남", "분노"],
        "🤬": ["욕"], "😱": ["비명", "충격"], "😰": ["식은땀"], "😅": ["머쓱", "땀"], "😆": ["깔깔"], "😉": ["윙크"], "🥲": ["웃픈", "미소눈물"],
        "🤗": ["포옹", "허그"], "🤫": ["쉿", "비밀"], "🤭": ["킥킥"], "🥳": ["축하", "파티"], "🤯": ["멘붕", "충격"], "🫠": ["녹음", "녹는"],
        "😇": ["천사"], "🤓": ["범생", "공부"], "🤒": ["아픔", "열"], "🤧": ["감기", "재채기"], "😷": ["마스크"], "💩": ["똥"], "👻": ["유령"],
        "💀": ["해골", "죽음"], "👀": ["눈", "보기", "시선"], "🧠": ["뇌", "두뇌"], "✨": ["반짝", "빛"], "🌟": ["별", "반짝"], "⭐": ["별"],
        "⭐️": ["별"], "🎉": ["축하", "파티", "폭죽"], "🎊": ["축하"], "🎁": ["선물"], "🎂": ["생일", "케이크"], "🎈": ["풍선"],
        "✅": ["체크", "완료", "확인"], "☑️": ["체크"], "✔️": ["체크"], "❌": ["엑스", "취소", "틀림"], "❎": ["엑스"], "⚠️": ["경고", "주의"],
        "❗": ["느낌표", "중요"], "❗️": ["느낌표", "중요"], "❓": ["물음표", "질문"], "❓️": ["물음표"], "💯": ["백점", "완벽"],
        "🚀": ["로켓", "출시"], "💡": ["아이디어", "전구"], "📌": ["핀", "고정"], "📎": ["클립", "첨부"], "📝": ["메모", "노트"],
        "📅": ["달력", "일정"], "⏰": ["알람", "시계"], "⌛": ["모래시계", "대기"], "🔒": ["자물쇠", "잠금"], "🔑": ["열쇠", "키"],
        "💰": ["돈"], "💸": ["돈", "지출"], "📈": ["상승", "그래프"], "📉": ["하락"], "🏆": ["우승", "트로피"], "🥇": ["금메달", "1등"],
        "☀️": ["해", "맑음"], "🌙": ["달", "밤"], "☁️": ["구름"], "🌧️": ["비"], "❄️": ["눈", "겨울"], "⚡": ["번개", "전기"], "⚡️": ["번개"],
        "🌈": ["무지개"], "🌸": ["벚꽃", "꽃"], "🌹": ["장미"], "🍀": ["행운", "클로버"], "☕": ["커피"], "☕️": ["커피"], "🍺": ["맥주"],
        "🍻": ["건배"], "🍷": ["와인"], "🍕": ["피자"], "🍔": ["햄버거"], "🍜": ["라면", "국수"], "🍚": ["밥"], "🍰": ["케이크"],
        "🐶": ["강아지", "개"], "🐱": ["고양이"], "🐻": ["곰"], "🐰": ["토끼"], "🐷": ["돼지"], "🐥": ["병아리"], "🦄": ["유니콘"],
        "🏠": ["집"], "🏢": ["회사", "빌딩"], "🚗": ["차", "자동차"], "✈️": ["비행기", "여행"], "💻": ["노트북", "컴퓨터"], "📱": ["폰", "핸드폰"],
        "🎵": ["음악", "음표"], "🎮": ["게임"], "📚": ["책", "공부"], "✏️": ["연필"], "🔍": ["검색", "돋보기"], "💬": ["말풍선", "채팅"],
        "🆗": ["오케이"], "🆕": ["새로운"], "🔴": ["빨강", "빨간원"], "🟢": ["초록", "초록원"], "🟡": ["노랑"], "🔵": ["파랑"],
        "➡️": ["오른쪽", "화살표"], "⬅️": ["왼쪽"], "⬆️": ["위"], "⬇️": ["아래"], "🙈": ["못본척"], "😬": ["어색"], "🫡": ["경례"],
    ]

    /// "Korean": the language of `localizedName`, for the detail pane.
    static var localLanguageTitle: String {
        let code = Locale.preferredLanguages.lazy.map { String($0.split(separator: "-").first ?? "") }.first { $0 != "en" } ?? ""
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Titles in the first preferred language when it isn't English.
    static var prefersLocalNames: Bool {
        !(Locale.preferredLanguages.first ?? "en").hasPrefix("en")
    }

    /// The query without the colon trigger (":fire" → "fire").
    static func needle(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(":") { text.removeFirst() }
        if text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Pure: the name itself, then a whole word of it ("red heart" for
    /// "heart"), then a name or word starting with the query, then anywhere
    /// in it — in English or the other language. Within a rank the
    /// favourites come first, then shorter names: ":heart" gives ❤️, not ♥️.
    static func matches(_ query: String, in emoji: [PaletteEmoji], limit: Int) -> [PaletteEmoji] {
        let needle = needle(query)
        guard !needle.isEmpty else { return [] }
        let favouriteRank = Dictionary(favourites.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func words(_ text: String) -> [Substring] { text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" || $0 == "," }) }
        func rank(_ item: PaletteEmoji) -> Int? {
            if item.glyph == needle { return 0 }
            let local = item.localizedName?.lowercased()
            if item.name == needle || local == needle || item.keywords.contains(needle) { return 0 }
            if item.keywords.contains(where: { $0.hasPrefix(needle) }) { return 2 }
            if words(item.name).contains(where: { $0 == needle }) || local.map({ words($0).contains { $0 == needle } }) == true { return 1 }
            if item.name.hasPrefix(needle) || local?.hasPrefix(needle) == true { return 2 }
            if words(item.name).contains(where: { $0.hasPrefix(needle) }) || local.map({ words($0).contains { $0.hasPrefix(needle) } }) == true { return 3 }
            if needle.count >= 2, item.name.contains(needle) || local?.contains(needle) == true { return 4 }
            return nil
        }
        return emoji.compactMap { item in rank(item).map { (item, $0) } }
            .sorted { lhs, rhs in
                let l = (lhs.1, favouriteRank[lhs.0.glyph] == nil ? 1 : 0, lhs.0.name.count)
                let r = (rhs.1, favouriteRank[rhs.0.glyph] == nil ? 1 : 0, rhs.0.name.count)
                return l < r
            }
            .prefix(limit).map(\.0)
    }

    /// Before anything is typed: recently used first, then the favourites.
    static func browsing(recent: [String], in emoji: [PaletteEmoji]) -> [PaletteEmoji] {
        let byGlyph = Dictionary(emoji.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (recent + favourites).compactMap { glyph in
            guard seen.insert(glyph).inserted else { return nil }
            return byGlyph[glyph] ?? byGlyph[glyph + "\u{FE0F}"] ?? byGlyph[glyph.replacingOccurrences(of: "\u{FE0F}", with: "")]
        }
    }
}

/// The emoji typed from the launcher, newest first (for the empty Emoji screen).
enum PaletteRecentEmoji {
    static let key = "AOMLauncherRecentEmoji"
    static let limit = 16

    static var all: [String] {
        guard !PresetManager.isUIPreview else { return ["🚀", "✅", "🔥"] }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ glyph: String) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        UserDefaults.standard.set(Self.recorded(glyph, in: all), forKey: key)
    }

    /// Pure: `glyph` first, no duplicate, at most `limit`.
    static func recorded(_ glyph: String, in list: [String]) -> [String] {
        Array(([glyph] + list.filter { $0 != glyph }).prefix(limit))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
