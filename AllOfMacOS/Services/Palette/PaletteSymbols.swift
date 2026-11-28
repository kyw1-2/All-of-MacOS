import Foundation

// 7.23 (DeepSeek design reference 2026-11-25 §2.10, Monodraw's character
// picker): box drawing, arrows, maths, shapes and currency in one launcher
// screen — the characters emoji search doesn't find by name. Search matches
// the English name, the Unicode name and a few Korean words; ↩ types the
// character into the app in front; the last 18 are kept.

struct PaletteSymbol: Hashable, Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case box, arrows, math, shapes, currency
        var id: String { rawValue }
        var title: String {
            switch self {
            case .box: "Box drawing"
            case .arrows: "Arrows"
            case .math: "Maths"
            case .shapes: "Shapes"
            case .currency: "Currency"
            }
        }
    }

    let glyph: String
    let name: String
    let category: Category
    var keywords: String = ""

    var id: String { glyph }

    /// "U+2500".
    var codePoint: String { glyph.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") }

    /// Unicode's own name ("BOX DRAWINGS LIGHT HORIZONTAL"), lowercased.
    var unicodeName: String {
        glyph.unicodeScalars.compactMap { $0.properties.name?.lowercased() }.joined(separator: " ")
    }
}

enum PaletteSymbols {
    static let all: [PaletteSymbol] = {
        func list(_ category: PaletteSymbol.Category, _ pairs: [(String, String, String)]) -> [PaletteSymbol] {
            pairs.map { PaletteSymbol(glyph: $0.0, name: $0.1, category: category, keywords: $0.2) }
        }
        return list(.box, [
            ("─", "Light horizontal", "line 가로선"), ("│", "Light vertical", "line 세로선"),
            ("┌", "Light down and right", "corner top left 모서리"), ("┐", "Light down and left", "corner top right 모서리"),
            ("└", "Light up and right", "corner bottom left 모서리"), ("┘", "Light up and left", "corner bottom right 모서리"),
            ("├", "Light vertical and right", "tee 분기"), ("┤", "Light vertical and left", "tee 분기"),
            ("┬", "Light down and horizontal", "tee 분기"), ("┴", "Light up and horizontal", "tee 분기"),
            ("┼", "Light vertical and horizontal", "cross 십자"), ("═", "Double horizontal", "double line 이중선"),
            ("║", "Double vertical", "double line 이중선"), ("╔", "Double down and right", "double corner"),
            ("╗", "Double down and left", "double corner"), ("╚", "Double up and right", "double corner"),
            ("╝", "Double up and left", "double corner"), ("╠", "Double vertical and right", "double tee"),
            ("╣", "Double vertical and left", "double tee"), ("╦", "Double down and horizontal", "double tee"),
            ("╩", "Double up and horizontal", "double tee"), ("╬", "Double vertical and horizontal", "double cross"),
            ("╭", "Light arc down and right", "rounded corner 둥근 모서리"), ("╮", "Light arc down and left", "rounded corner"),
            ("╰", "Light arc up and right", "rounded corner"), ("╯", "Light arc up and left", "rounded corner"),
            ("━", "Heavy horizontal", "bold line 굵은 선"), ("┃", "Heavy vertical", "bold line 굵은 선"),
            ("┄", "Light triple dash horizontal", "dashed 점선"), ("┆", "Light triple dash vertical", "dashed 점선"),
            ("▏", "Left one eighth block", "thin bar"), ("█", "Full block", "block 블록"),
            ("▓", "Dark shade", "shade 음영"), ("▒", "Medium shade", "shade 음영"), ("░", "Light shade", "shade 음영"),
            ("▀", "Upper half block", "half"), ("▄", "Lower half block", "half"),
        ])
        + list(.arrows, [
            ("→", "Right arrow", "오른쪽 화살표"), ("←", "Left arrow", "왼쪽 화살표"), ("↑", "Up arrow", "위 화살표"),
            ("↓", "Down arrow", "아래 화살표"), ("↔", "Left right arrow", "양쪽 화살표"), ("↕", "Up down arrow", "위아래"),
            ("⇒", "Rightwards double arrow", "implies 그러므로"), ("⇐", "Leftwards double arrow", "double"),
            ("⇔", "Left right double arrow", "iff 동치"), ("↗", "North east arrow", "대각선"), ("↘", "South east arrow", "대각선"),
            ("↖", "North west arrow", "대각선"), ("↙", "South west arrow", "대각선"), ("↩", "Return arrow", "return enter 엔터"),
            ("↪", "Rightwards arrow with hook", "redo"), ("⟶", "Long right arrow", "long"), ("⟵", "Long left arrow", "long"),
            ("➜", "Heavy round-tipped right arrow", "bold"), ("▶", "Right triangle", "play 재생"), ("◀", "Left triangle", "back"),
            ("▲", "Up triangle", "up"), ("▼", "Down triangle", "down"), ("⌘", "Command key", "cmd mac 커맨드"),
            ("⌥", "Option key", "alt mac 옵션"), ("⇧", "Shift key", "shift 시프트"), ("⌃", "Control key", "ctrl 컨트롤"),
            ("⎋", "Escape key", "esc"), ("⌫", "Delete key", "backspace 지우기"), ("⇥", "Tab key", "tab 탭"), ("⏎", "Return symbol", "enter"),
        ])
        + list(.math, [
            ("±", "Plus minus", "플러스마이너스"), ("×", "Multiplication", "times 곱하기"), ("÷", "Division", "divide 나누기"),
            ("≠", "Not equal", "다르다"), ("≈", "Almost equal", "approx 약"), ("≤", "Less than or equal", "이하"),
            ("≥", "Greater than or equal", "이상"), ("∞", "Infinity", "무한"), ("√", "Square root", "root 루트"),
            ("∑", "Summation", "sum sigma 합"), ("∏", "Product", "pi product"), ("∫", "Integral", "적분"),
            ("∂", "Partial differential", "partial 편미분"), ("∆", "Increment", "delta 델타"), ("∇", "Nabla", "gradient"),
            ("π", "Pi", "파이"), ("µ", "Micro", "mu 마이크로"), ("°", "Degree", "도 온도"), ("‰", "Per mille", "퍼밀"),
            ("∈", "Element of", "in 원소"), ("∉", "Not an element of", "not in"), ("⊂", "Subset of", "부분집합"),
            ("∪", "Union", "합집합"), ("∩", "Intersection", "교집합"), ("∅", "Empty set", "공집합"),
            ("∀", "For all", "forall 모든"), ("∃", "There exists", "exists 존재"), ("¬", "Not", "negation 부정"),
            ("∧", "Logical and", "and 그리고"), ("∨", "Logical or", "or 또는"), ("∴", "Therefore", "따라서"),
            ("½", "One half", "half 반"), ("¼", "One quarter", "quarter"), ("²", "Superscript two", "squared 제곱"),
            ("³", "Superscript three", "cubed 세제곱"),
        ])
        + list(.shapes, [
            ("●", "Black circle", "dot circle 원"), ("○", "White circle", "circle 원"), ("◉", "Fisheye", "radio"),
            ("■", "Black square", "square 사각형"), ("□", "White square", "square 사각형"), ("▪", "Small black square", "bullet"),
            ("◆", "Black diamond", "diamond 마름모"), ("◇", "White diamond", "diamond"), ("★", "Black star", "star 별"),
            ("☆", "White star", "star 별"), ("✓", "Check mark", "check tick 체크"), ("✔", "Heavy check mark", "check 체크"),
            ("✗", "Ballot X", "cross x 엑스"), ("✕", "Multiplication X", "close 닫기"), ("•", "Bullet", "dot 점"),
            ("·", "Middle dot", "interpunct 가운뎃점"), ("…", "Ellipsis", "dots 말줄임"), ("—", "Em dash", "dash 대시"),
            ("–", "En dash", "dash range"), ("§", "Section", "섹션"), ("¶", "Pilcrow", "paragraph 문단"),
            ("†", "Dagger", "단검"), ("※", "Reference mark", "참고표 당구장"), ("©", "Copyright", "저작권"),
            ("®", "Registered", "등록상표"), ("™", "Trade mark", "상표"), ("♥", "Heart suit", "heart 하트"),
            ("♪", "Eighth note", "music 음표"), ("☐", "Ballot box", "checkbox 체크박스"), ("☑", "Ballot box with check", "checkbox"),
        ])
        + list(.currency, [
            ("₩", "Won", "won krw 원화"), ("$", "Dollar", "usd 달러"), ("€", "Euro", "eur 유로"), ("£", "Pound", "gbp 파운드"),
            ("¥", "Yen", "jpy cny 엔 위안"), ("₹", "Rupee", "inr 루피"), ("₽", "Ruble", "rub 루블"), ("₿", "Bitcoin", "btc 비트코인"),
            ("¢", "Cent", "센트"), ("₫", "Dong", "vnd 동"), ("฿", "Baht", "thb 바트"), ("₺", "Lira", "try 리라"),
        ])
    }()

    /// The search: every word must be in the name, the Unicode name or the
    /// keywords; a pasted character finds itself.
    static func matches(_ query: String, in symbols: [PaletteSymbol] = all, limit: Int = 80) -> [PaletteSymbol] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Array(symbols.prefix(limit)) }
        if let exact = symbols.first(where: { $0.glyph == trimmed }) { return [exact] }
        let words = trimmed.split(separator: " ").map(String.init)
        return symbols.filter { symbol in
            let haystack = "\(symbol.name.lowercased()) \(symbol.unicodeName) \(symbol.keywords.lowercased()) \(symbol.category.title.lowercased())"
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(limit).map { $0 }
    }
}

enum PaletteRecentSymbols {
    static let key = "AOMLauncherRecentSymbols"
    static let limit = 18

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func record(_ glyph: String) {
        UserDefaults.standard.set(recorded(glyph, in: all), forKey: key)
    }

    static func recorded(_ glyph: String, in list: [String]) -> [String] {
        Array(([glyph] + list.filter { $0 != glyph }).prefix(limit))
    }
}
