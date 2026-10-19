import AppKit

/// A visible character is one keystroke, including composed Hangul, combining
/// marks and ordinary emoji clusters. Very long clusters are bounded at scalar
/// boundaries for Quartz's small Unicode event payload.
struct TextTypingCursor {
    struct Stroke: Equatable {
        let units: [UInt16]
        let keyCode: CGKeyCode
        let shifted: Bool
    }
    private var characters: String.Iterator
    private var overflow: ArraySlice<[UInt16]> = []

    init(_ text: String) { characters = text.makeIterator() }

    mutating func next() -> Stroke? {
        if let units = overflow.popFirst() { return Stroke(units: units, keyCode: 0, shifted: false) }
        guard let character = characters.next() else { return nil }
        if character == "\r\n" || character == "\r" || character == "\n" {
            return Stroke(units: [13], keyCode: 36, shifted: false)
        }
        if character == "\t" { return Stroke(units: [9], keyCode: 48, shifted: false) }
        let units = Array(String(character).utf16)
        if units.count <= 20 {
            let key = Self.asciiKeys[character]
            return Stroke(units: units, keyCode: key?.code ?? 0, shifted: key?.shifted ?? false)
        }
        var parts: [[UInt16]] = [], part: [UInt16] = []
        for scalar in character.unicodeScalars {
            let scalarUnits = Array(String(scalar).utf16)
            if part.count + scalarUnits.count > 20 { parts.append(part); part = [] }
            part += scalarUnits
        }
        if !part.isEmpty { parts.append(part) }
        overflow = parts.dropFirst()
        return Stroke(units: parts[0], keyCode: 0, shifted: false)
    }

    /// A real virtual key for ASCII also serves receivers that use key codes
    /// rather than the overridden Unicode string. Unicode remains authoritative
    /// for text input on a different active keyboard layout.
    private static let asciiKeys: [Character: (code: CGKeyCode, shifted: Bool)] = {
        let keys: [(String, CGKeyCode)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),
            ("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),
            ("=",24),("9",25),("7",26),("-",27),("8",28),("0",29),("]",30),("o",31),("u",32),("[",33),("i",34),("p",35),
            ("l",37),("j",38),("'",39),("k",40),(";",41),("\\",42),(",",43),("/",44),("n",45),("m",46),(".",47),(" ",49),("`",50)]
        var result: [Character: (code: CGKeyCode, shifted: Bool)] = [:]
        for (text, code) in keys {
            let char = text.first!; result[char] = (code, false)
            if text.uppercased() != text { result[text.uppercased().first!] = (code, true) }
        }
        let punctuation = [("1","!"),("2","@"),("3","#"),("4","$"),("5","%"),("6","^"),("7","&"),("8","*"),("9","("),("0",")"),
            ("-","_"),("=","+"),("[","{"),("]","}"),(";",":"),("'","\""),(",","<"),(".",">"),("/","?"),("\\","|"),("`","~")]
        for (plain, shifted) in punctuation {
            if let key = result[plain.first!] { result[shifted.first!] = (key.code, true) }
        }
        return result
    }()
}

/// Serial asynchronous delivery with injectable scheduling. No pasteboard
/// access, prebuilt array of the full text, sleep or blocking loop.
final class TextTypingSession {
    struct Environment {
        var isCancelled: () -> Bool
        var targetIsReady: () -> Bool
        var modifiersAreReleased: () -> Bool
        var now: () -> TimeInterval
        var send: (TextTypingCursor.Stroke) -> Bool
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
    }
    private var cursor: TextTypingCursor
    private let interval: TimeInterval
    private let environment: Environment
    private let completion: (Bool) -> Void
    private var started = false
    private var finished = false
    private var deadline: TimeInterval = 0

    init(text: String, intervalMs: Int?, environment: Environment, completion: @escaping (Bool) -> Void) {
        cursor = TextTypingCursor(text)
        interval = Double(min(500, max(0, intervalMs ?? 20))) / 1000
        self.environment = environment; self.completion = completion
    }

    func start() {
        guard !started else { return }; started = true
        deadline = environment.now() + 3
        begin()
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }; finished = true; completion(success)
    }
    private func begin() {
        guard !finished else { return }
        guard !environment.isCancelled(), environment.targetIsReady() else { finish(false); return }
        guard environment.modifiersAreReleased() else {
            guard environment.now() < deadline else { finish(false); return }
            environment.schedule(0.02) { self.begin() }; return
        }
        post(cursor.next())
    }
    private func post(_ stroke: TextTypingCursor.Stroke?) {
        guard !finished else { return }
        guard !environment.isCancelled(), environment.targetIsReady() else { finish(false); return }
        guard let stroke else { finish(true); return }
        guard environment.send(stroke) else { finish(false); return }
        guard let next = cursor.next() else { finish(true); return }
        environment.schedule(interval) { self.post(next) }
    }
}
