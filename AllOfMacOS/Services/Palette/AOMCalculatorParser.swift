import Foundation

// The calculator's grammar, lowest precedence first:
//
//   input      := expression [ ("in" | "to" | "as" | "into" | "→" | "=") target ] end
//   expression := term { ("+" | "-") term }            "150 + 10%" adds 10% of 150
//   term       := unary { ("*" | "/" | "×" | "÷" | "x" | "%" | "mod" | "of" | "off") unary | implicit }
//   unary      := ("-" | "+") unary | power
//   power      := postfix [ "^" unary ]                 right-associative: 2^3^2 = 2^9
//   postfix    := primary { "%" | "!" | "²" | "³" }
//   primary    := number [unit {number unit}] | "(" expression ")" [unit] | constant | function (primary | unary)
//
// Nothing is looked up outside the closed tables below, so text such as
// `system("ls")` or `FUNCTION(…)` is simply not a sum.

struct AOMCalcToken {
    enum Kind: Equatable {
        case number(Double)
        case word(String)
        case symbol(Character)
        case end
    }

    var kind: Kind
    /// Whitespace came right before the token ("10 m 2" is not "10 m2").
    var spaceBefore: Bool
    /// The number was written with a decimal comma ("1,5").
    var decimalComma = false
    /// The number was written with a decimal point ("1.5").
    var decimalPoint = false
    /// The number was a 0x, 0b or 0o literal.
    var baseLiteral = false
}

enum AOMCalcError: Error {
    case syntax, unknownName, math, units, tooComplex
}

enum AOMCalcLexer {
    static let maximumTokens = 160
    private static let radixMarkers: [Character: Int] = ["x": 16, "X": 16, "b": 2, "B": 2, "o": 8, "O": 8]

    static func tokens(_ input: String, localeDecimal: Character) throws -> [AOMCalcToken] {
        let chars = Array(input)
        var index = 0
        var tokens: [AOMCalcToken] = []
        var space = false

        func at(_ offset: Int) -> Character? {
            let position = index + offset
            return position < chars.count ? chars[position] : nil
        }
        func push(_ kind: AOMCalcToken.Kind) {
            tokens.append(AOMCalcToken(kind: kind, spaceBefore: space))
            space = false
        }

        while index < chars.count {
            guard tokens.count < maximumTokens else { throw AOMCalcError.tooComplex }
            let char = chars[index]
            if char.isWhitespace { space = true; index += 1; continue }

            // 0x1F, 0b1010, 0o17
            if char == "0", let marker = at(1), let radix = radixMarkers[marker],
               let first = at(2), first.isHexDigit, Int(String(first), radix: radix) != nil {
                var end = index + 2
                var digits = ""
                while end < chars.count, chars[end].isASCII, Int(String(chars[end]), radix: radix) != nil {
                    digits.append(chars[end]); end += 1
                }
                guard digits.count <= 15, let value = UInt64(digits, radix: radix) else { throw AOMCalcError.tooComplex }
                tokens.append(AOMCalcToken(kind: .number(Double(value)), spaceBefore: space, baseLiteral: true))
                space = false
                index = end
                continue
            }

            if char.isCalcDigit || (char == "." && at(1)?.isCalcDigit == true) {
                var end = index
                var raw = ""
                while end < chars.count {
                    let c = chars[end]
                    if c.isCalcDigit { raw.append(c); end += 1; continue }
                    if c == "." || c == ",", end + 1 < chars.count, chars[end + 1].isCalcDigit { raw.append(c); end += 1; continue }
                    break
                }
                // A trailing point ("5.") belongs to the number.
                if end < chars.count, chars[end] == ".", !raw.contains("."), !raw.contains(","),
                   end + 1 >= chars.count || !chars[end + 1].isCalcDigit { end += 1 }
                var exponent = 0
                if end < chars.count, chars[end] == "e" || chars[end] == "E" {
                    var cursor = end + 1
                    var negative = false
                    if cursor < chars.count, chars[cursor] == "+" || chars[cursor] == "-" {
                        negative = chars[cursor] == "-"; cursor += 1
                    }
                    if cursor < chars.count, chars[cursor].isCalcDigit {
                        var digits = ""
                        while cursor < chars.count, chars[cursor].isCalcDigit { digits.append(chars[cursor]); cursor += 1 }
                        guard digits.count <= 4, let value = Int(digits) else { throw AOMCalcError.tooComplex }
                        exponent = negative ? -value : value
                        end = cursor
                    }
                }
                let (mantissa, comma, point) = try decimal(raw, localeDecimal: localeDecimal)
                let value = exponent == 0 ? mantissa : mantissa * pow(10, Double(exponent))
                tokens.append(AOMCalcToken(kind: .number(value), spaceBefore: space, decimalComma: comma, decimalPoint: point))
                space = false
                index = end
                continue
            }

            switch char {
            case "+", "-", "/", "^", "%", "!", "(", ")", "²", "³":
                if char == "-", at(1) == ">" { push(.word("to")); index += 2; continue }
                push(.symbol(char)); index += 1; continue
            case "*":
                if at(1) == "*" { push(.symbol("^")); index += 2; continue }
                push(.symbol("*")); index += 1; continue
            case "×", "✕", "✖", "⋅", "·", "∙":
                push(.symbol("*")); index += 1; continue
            case "÷", "∕":
                push(.symbol("/")); index += 1; continue
            case "−", "–":
                push(.symbol("-")); index += 1; continue
            case "→":
                push(.word("to")); index += 1; continue
            case "=":
                if at(1) == ">" { index += 2 } else { index += 1 }
                push(.word("to")); continue
            case "√":
                push(.word("sqrt")); index += 1; continue
            case "℃":
                push(.word("°C")); index += 1; continue
            case "℉":
                push(.word("°F")); index += 1; continue
            case "'", "\"", "′", "″":
                push(.word(String(char))); index += 1; continue
            case "°":
                var word = "°"
                var end = index + 1
                while end < chars.count, chars[end].isLetter { word.append(chars[end]); end += 1 }
                push(.word(word)); index = end; continue
            default:
                break
            }

            if char.isLetter || char == "µ" || char == "μ" {
                var word = ""
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end] == "µ" || chars[end] == "μ" {
                    word.append(chars[end]); end += 1
                }
                // log2 and log10 are single names; "log 2" is log(2).
                if word.lowercased() == "log", end < chars.count, chars[end].isCalcDigit {
                    var digits = ""
                    var cursor = end
                    while cursor < chars.count, chars[cursor].isCalcDigit { digits.append(chars[cursor]); cursor += 1 }
                    if digits == "2" || digits == "10" { word += digits; end = cursor }
                }
                push(.word(word))
                index = end
                continue
            }
            // Anything else (; $ ` @ quotes, control characters …) is not a sum.
            throw AOMCalcError.syntax
        }
        tokens.append(AOMCalcToken(kind: .end, spaceBefore: space))
        return tokens
    }

    /// Reads digits with "." or "," as the decimal separator. With both, the
    /// last one is the decimal separator ("1,234.5", "1.234,5"). One comma
    /// or point before exactly three digits ("1,000") is a thousands
    /// separator unless it is the locale's decimal separator; anything else
    /// with one separator is a decimal ("1,5", "3.14").
    static func decimal(_ raw: String, localeDecimal: Character) throws -> (Double, comma: Bool, point: Bool) {
        let dots = raw.filter { $0 == "." }.count
        let commas = raw.filter { $0 == "," }.count
        var decimalSeparator: Character?
        var groupSeparator: Character?
        if dots > 0 && commas > 0 {
            guard let lastDot = raw.lastIndex(of: "."), let lastComma = raw.lastIndex(of: ",") else { throw AOMCalcError.syntax }
            decimalSeparator = lastDot > lastComma ? "." : ","
            groupSeparator = decimalSeparator == "." ? "," : "."
            guard raw.filter({ $0 == decimalSeparator }).count == 1 else { throw AOMCalcError.syntax }
        } else if dots + commas == 1 {
            let separator: Character = dots == 1 ? "." : ","
            let parts = raw.split(separator: separator, omittingEmptySubsequences: false)
            let integer = parts.first ?? ""
            let fraction = parts.count > 1 ? parts[1] : ""
            let looksGrouped = fraction.count == 3 && (1...3).contains(integer.count) && integer != "0"
            if looksGrouped && separator != localeDecimal { groupSeparator = separator } else { decimalSeparator = separator }
        } else if dots > 1 || commas > 1 {
            groupSeparator = dots > 1 ? "." : ","
        }

        var integerPart = Substring(raw)
        var fractionPart: Substring = ""
        if let decimalSeparator, let split = raw.lastIndex(of: decimalSeparator) {
            integerPart = raw[raw.startIndex..<split]
            fractionPart = raw[raw.index(after: split)...]
        }
        if let groupSeparator {
            guard !fractionPart.contains(groupSeparator) else { throw AOMCalcError.syntax }
            let groups = integerPart.split(separator: groupSeparator, omittingEmptySubsequences: false)
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { throw AOMCalcError.syntax }
            integerPart = Substring(groups.joined())
        }
        let text = (integerPart.isEmpty ? "0" : String(integerPart)) + (fractionPart.isEmpty ? "" : "." + fractionPart)
        guard let value = Double(text) else { throw AOMCalcError.syntax }
        return (value, decimalSeparator == ",", decimalSeparator == ".")
    }
}

private extension Character {
    var isCalcDigit: Bool { ("0"..."9").contains(self) }
}

/// A number, possibly with a unit, as the parser carries it. `isPercent`
/// marks a bare "10%" so "150 + 10%" can add a share of the left side.
struct AOMCalcValue {
    var number: Double
    var unit: AOMCalculatorUnit?
    var isPercent = false

    init(_ number: Double, unit: AOMCalculatorUnit? = nil, isPercent: Bool = false) {
        self.number = number
        self.unit = unit
        self.isPercent = isPercent
    }
}

enum AOMCalcTarget {
    case unit(AOMCalculatorUnit)
    /// 2, 8, 10 or 16.
    case base(Int)
}

/// The closed list of names: anything else is an unknown word.
enum AOMCalcNames {
    static let constants: [String: Double] = ["pi": Double.pi, "π": Double.pi, "e": M_E, "tau": 2 * Double.pi, "τ": 2 * Double.pi]
    static let functions: Set<String> = ["sqrt", "cbrt", "abs", "round", "floor", "ceil", "trunc",
                                         "sin", "cos", "tan", "asin", "acos", "atan",
                                         "log", "log10", "log2", "ln", "exp"]
    static let conversionWords: Set<String> = ["in", "to", "as", "into"]
    static let baseTargets: [String: Int] = ["hex": 16, "hexadecimal": 16, "bin": 2, "binary": 2,
                                             "oct": 8, "octal": 8, "dec": 10, "decimal": 10]
    /// Words that are operators, never units.
    static let operatorWords: Set<String> = ["x", "mod", "of", "off"]

    static func isReserved(_ lower: String) -> Bool {
        constants[lower] != nil || functions.contains(lower) || conversionWords.contains(lower)
            || operatorWords.contains(lower) || baseTargets[lower] != nil
    }
}

struct AOMCalcParser {
    /// Five levels per parenthesis: about 24 nested groups.
    static let maximumDepth = 120

    private var tokens: [AOMCalcToken]
    private var position = 0
    private var depth = 0
    /// Operators, functions and postfixes seen: zero means the text was a
    /// lone number or quantity.
    private(set) var arithmetic = 0

    init(tokens: [AOMCalcToken]) {
        self.tokens = tokens.isEmpty ? [AOMCalcToken(kind: .end, spaceBefore: false)] : tokens
    }

    private var current: AOMCalcToken { tokens[position] }
    private func peek(_ offset: Int) -> AOMCalcToken { tokens[min(position + offset, tokens.count - 1)] }
    private mutating func advance() { if position < tokens.count - 1 { position += 1 } }

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw AOMCalcError.tooComplex }
    }

    mutating func parseInput() throws -> (AOMCalcValue, AOMCalcTarget?) {
        let value = try parseExpression()
        var target: AOMCalcTarget?
        if case .word(let word) = current.kind, AOMCalcNames.conversionWords.contains(word.lowercased()) {
            advance()
            target = try parseTarget()
        }
        guard case .end = current.kind else { throw AOMCalcError.syntax }
        return (value, target)
    }

    private mutating func parseTarget() throws -> AOMCalcTarget {
        guard case .word(let word) = current.kind else { throw AOMCalcError.syntax }
        if let base = AOMCalcNames.baseTargets[word.lowercased()] {
            advance()
            return .base(base)
        }
        guard let unit = parseUnitName() else { throw AOMCalcError.unknownName }
        return .unit(unit)
    }

    // MARK: Levels

    private mutating func parseExpression() throws -> AOMCalcValue {
        try enter(); defer { depth -= 1 }
        var lhs = try parseTerm()
        while case .symbol(let op) = current.kind, op == "+" || op == "-" {
            advance()
            let rhs = try parseTerm()
            lhs = try AOMCalcMath.add(lhs, rhs, subtract: op == "-")
            arithmetic += 1
        }
        return lhs
    }

    private mutating func parseTerm() throws -> AOMCalcValue {
        try enter(); defer { depth -= 1 }
        var lhs = try parseUnary()
        while true {
            let token = current
            if case .symbol(let op) = token.kind, op == "*" || op == "/" || op == "%" {
                advance()
                let rhs = try parseUnary()
                switch op {
                case "*": lhs = try AOMCalcMath.multiply(lhs, rhs)
                case "/": lhs = try AOMCalcMath.divide(lhs, rhs)
                default: lhs = try AOMCalcMath.modulo(lhs, rhs)
                }
                arithmetic += 1
                continue
            }
            if case .word(let word) = token.kind {
                let lower = word.lowercased()
                if lower == "x", startsNumberOrGroup(peek(1)) {
                    advance()
                    lhs = try AOMCalcMath.multiply(lhs, try parseUnary())
                    arithmetic += 1
                    continue
                }
                if lower == "mod" {
                    advance()
                    lhs = try AOMCalcMath.modulo(lhs, try parseUnary())
                    arithmetic += 1
                    continue
                }
                if lower == "of" || lower == "off", lhs.isPercent {
                    advance()
                    let rhs = try parseUnary()
                    let share = lower == "of" ? lhs.number : 1 - lhs.number
                    lhs = AOMCalcValue(rhs.number * share, unit: rhs.unit)
                    arithmetic += 1
                    continue
                }
                // "2pi", "3 sqrt 16": implicit multiplication by a name.
                if AOMCalcNames.constants[lower] != nil || AOMCalcNames.functions.contains(lower) {
                    lhs = try AOMCalcMath.multiply(lhs, try parseUnary())
                    arithmetic += 1
                    continue
                }
            }
            // "2(3 + 4)", "(1 + 2)(3 + 4)"
            if case .symbol("(") = token.kind {
                lhs = try AOMCalcMath.multiply(lhs, try parseUnary())
                arithmetic += 1
                continue
            }
            break
        }
        return lhs
    }

    private mutating func parseUnary() throws -> AOMCalcValue {
        try enter(); defer { depth -= 1 }
        if case .symbol(let op) = current.kind, op == "-" || op == "+" {
            advance()
            var value = try parseUnary()
            if op == "-" { value.number = -value.number }
            return value
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> AOMCalcValue {
        try enter(); defer { depth -= 1 }
        let base = try parsePostfix()
        if case .symbol("^") = current.kind {
            advance()
            let exponent = try parseUnary()
            arithmetic += 1
            return try AOMCalcMath.power(base, exponent)
        }
        return base
    }

    private mutating func parsePostfix() throws -> AOMCalcValue {
        var value = try parsePrimary()
        while case .symbol(let op) = current.kind {
            switch op {
            case "%":
                // "10 % 3" is a remainder: leave the sign to parseTerm.
                if startsNumberOrGroup(peek(1)) || startsName(peek(1)) { return value }
                advance()
                value = AOMCalcValue(value.number / 100, unit: value.unit, isPercent: true)
            case "!":
                advance()
                value = try AOMCalcMath.factorial(value)
            case "²", "³":
                advance()
                value = try AOMCalcMath.power(value, AOMCalcValue(op == "²" ? 2 : 3))
            default:
                return value
            }
            arithmetic += 1
        }
        return value
    }

    private mutating func parsePrimary() throws -> AOMCalcValue {
        try enter(); defer { depth -= 1 }
        let token = current
        switch token.kind {
        case .number(let number):
            advance()
            if token.baseLiteral { arithmetic += 1 }
            var value = AOMCalcValue(number)
            try attachUnit(&value)
            return value
        case .symbol("("):
            advance()
            var inner = try parseExpression()
            guard case .symbol(")") = current.kind else { throw AOMCalcError.syntax }
            advance()
            try attachUnit(&inner)
            return inner
        case .word(let word):
            let lower = word.lowercased()
            if let constant = AOMCalcNames.constants[lower] {
                advance()
                return AOMCalcValue(constant)
            }
            if AOMCalcNames.functions.contains(lower) {
                advance()
                let argument: AOMCalcValue
                if case .symbol("(") = current.kind { argument = try parsePrimary() } else { argument = try parseUnary() }
                arithmetic += 1
                return try AOMCalcMath.apply(lower, to: argument)
            }
            throw AOMCalcError.unknownName
        default:
            throw AOMCalcError.syntax
        }
    }

    // MARK: Units

    /// Attaches the unit after a number ("10 km"), then any further
    /// quantities of the same dimension ("5 ft 11 in", "1 h 30 min").
    private mutating func attachUnit(_ value: inout AOMCalcValue) throws {
        guard value.unit == nil, case .word(let word) = current.kind else { return }
        let lower = word.lowercased()
        if lower == "in" {
            // "10 in" and "10 in to cm" are inches; "10 cm in mm" converts.
            if case .word(let next) = peek(1).kind, next.lowercased() != "in", isUnitOrTarget(next) { return }
        } else if AOMCalcNames.isReserved(lower) {
            return
        }
        let saved = position
        guard let unit = parseUnitName() else { position = saved; return }
        value.unit = unit
        while case .number(let more) = current.kind {
            let before = position
            advance()
            guard let next = parseUnitName(), next.dimension == unit.dimension, unit.dimension != .temperature else {
                position = before
                break
            }
            value.number += next.deltaToBase(more) / unit.factor
        }
    }

    private func isUnitOrTarget(_ word: String) -> Bool {
        AOMCalculatorUnits.lookup(word) != nil || AOMCalcNames.baseTargets[word.lowercased()] != nil
            || AOMCalculatorUnits.multiWordStarts.contains(word.lowercased())
    }

    /// Reads a unit at the current word: "km", "km/h", "MB/s", "m²", "m2",
    /// "m^2", "sq ft", "cubic m", "fl oz", "nautical miles", "°C".
    private mutating func parseUnitName() -> AOMCalculatorUnit? {
        guard case .word(let first) = current.kind else { return nil }
        let lower = first.lowercased()
        if AOMCalculatorUnits.multiWordStarts.contains(lower), case .word(let second) = peek(1).kind {
            let secondLower = second.lowercased()
            var combined: AOMCalculatorUnit?
            switch lower {
            case "sq", "square": combined = AOMCalculatorUnits.lookup(second).flatMap(AOMCalculatorUnits.squared)
            case "cubic": combined = AOMCalculatorUnits.lookup(second).flatMap(AOMCalculatorUnits.cubed)
            case "fl": combined = secondLower == "oz" ? AOMCalculatorUnits.unit("fl oz") : nil
            case "fluid": combined = ["ounce", "ounces", "oz"].contains(secondLower) ? AOMCalculatorUnits.unit("fl oz") : nil
            case "nautical": combined = ["mile", "miles"].contains(secondLower) ? AOMCalculatorUnits.unit("nmi") : nil
            default: break
            }
            if let combined {
                advance(); advance()
                return combined
            }
        }
        // km/h, MB/s, Mbit/s: one name when nothing separates the parts.
        if case .symbol("/") = peek(1).kind, !peek(1).spaceBefore, case .word(let denominator) = peek(2).kind,
           !peek(2).spaceBefore, let compound = AOMCalculatorUnits.lookup("\(first)/\(denominator)") {
            advance(); advance(); advance()
            return compound
        }
        guard var unit = AOMCalculatorUnits.lookup(first) else { return nil }
        advance()
        if unit.dimension == .length {
            if case .symbol(let mark) = current.kind, !current.spaceBefore, mark == "²" || mark == "³",
               let raised = mark == "²" ? AOMCalculatorUnits.squared(unit) : AOMCalculatorUnits.cubed(unit) {
                unit = raised
                advance()
            } else if case .number(let power) = current.kind, !current.spaceBefore, !current.decimalPoint,
                      !current.decimalComma, power == 2 || power == 3,
                      let raised = power == 2 ? AOMCalculatorUnits.squared(unit) : AOMCalculatorUnits.cubed(unit) {
                unit = raised
                advance()
            } else if case .symbol("^") = current.kind, !current.spaceBefore, case .number(let power) = peek(1).kind,
                      power == 2 || power == 3,
                      let raised = power == 2 ? AOMCalculatorUnits.squared(unit) : AOMCalculatorUnits.cubed(unit) {
                unit = raised
                advance(); advance()
            }
        }
        return unit
    }

    // MARK: Lookahead

    private func startsNumberOrGroup(_ token: AOMCalcToken) -> Bool {
        switch token.kind {
        case .number: return true
        case .symbol(let s): return s == "("
        default: return false
        }
    }

    private func startsName(_ token: AOMCalcToken) -> Bool {
        guard case .word(let word) = token.kind else { return false }
        let lower = word.lowercased()
        return AOMCalcNames.constants[lower] != nil || AOMCalcNames.functions.contains(lower)
    }
}

/// Arithmetic on values with units.
enum AOMCalcMath {
    static func add(_ a: AOMCalcValue, _ b: AOMCalcValue, subtract: Bool) throws -> AOMCalcValue {
        let sign: Double = subtract ? -1 : 1
        if b.isPercent && !a.isPercent {
            return AOMCalcValue(a.number * (1 + sign * b.number), unit: a.unit)
        }
        switch (a.unit, b.unit) {
        case (nil, nil):
            return AOMCalcValue(a.number + sign * b.number, isPercent: a.isPercent && b.isPercent)
        case (let unit?, nil), (nil, let unit?):
            return AOMCalcValue(a.number + sign * b.number, unit: unit)
        case (let left?, let right?):
            guard left.dimension == right.dimension else { throw AOMCalcError.units }
            return AOMCalcValue(a.number + sign * right.deltaToBase(b.number) / left.factor, unit: left)
        }
    }

    static func multiply(_ a: AOMCalcValue, _ b: AOMCalcValue) throws -> AOMCalcValue {
        switch (a.unit, b.unit) {
        case (nil, nil): return AOMCalcValue(a.number * b.number)
        case (let unit?, nil), (nil, let unit?): return AOMCalcValue(a.number * b.number, unit: unit)
        case (let left?, let right?): return try product(a.number, left, b.number, right)
        }
    }

    static func divide(_ a: AOMCalcValue, _ b: AOMCalcValue) throws -> AOMCalcValue {
        guard b.number != 0 else { throw AOMCalcError.math }
        switch (a.unit, b.unit) {
        case (nil, nil): return AOMCalcValue(a.number / b.number)
        case (let unit?, nil): return AOMCalcValue(a.number / b.number, unit: unit)
        case (nil, _?): throw AOMCalcError.units
        case (let left?, let right?):
            if left.dimension == right.dimension, left.dimension != .temperature {
                return AOMCalcValue(left.deltaToBase(a.number) / right.deltaToBase(b.number))
            }
            return try quotient(a.number, left, b.number, right)
        }
    }

    static func modulo(_ a: AOMCalcValue, _ b: AOMCalcValue) throws -> AOMCalcValue {
        guard b.unit == nil, b.number != 0 else { throw AOMCalcError.math }
        return AOMCalcValue(fmod(a.number, b.number), unit: a.unit)
    }

    static func power(_ base: AOMCalcValue, _ exponent: AOMCalcValue) throws -> AOMCalcValue {
        guard exponent.unit == nil else { throw AOMCalcError.units }
        guard let unit = base.unit else { return AOMCalcValue(pow(base.number, exponent.number)) }
        // (3 m)^2 is an area, (2 cm)^3 a volume.
        if exponent.number == 2, let square = AOMCalculatorUnits.squared(unit) {
            return AOMCalcValue(base.number * base.number, unit: square)
        }
        if exponent.number == 3, let cube = AOMCalculatorUnits.cubed(unit) {
            return AOMCalcValue(base.number * base.number * base.number, unit: cube)
        }
        throw AOMCalcError.units
    }

    static func factorial(_ value: AOMCalcValue) throws -> AOMCalcValue {
        guard value.unit == nil, value.number >= 0, value.number <= 170, value.number.rounded() == value.number else {
            throw AOMCalcError.math
        }
        var result = 1.0
        var factor = 2.0
        while factor <= value.number { result *= factor; factor += 1 }
        return AOMCalcValue(result)
    }

    static func apply(_ name: String, to argument: AOMCalcValue) throws -> AOMCalcValue {
        let x = argument.number
        func plain(_ f: (Double) -> Double) throws -> AOMCalcValue {
            guard argument.unit == nil else { throw AOMCalcError.units }
            return AOMCalcValue(f(x))
        }
        func angle() throws -> Double {
            guard let unit = argument.unit else { return x }
            guard unit.dimension == .angle else { throw AOMCalcError.units }
            return unit.toBase(x)
        }
        switch name {
        case "sqrt":
            if let unit = argument.unit, unit.dimension == .area, unit.id.hasSuffix("²"),
               let length = AOMCalculatorUnits.unit(String(unit.id.dropLast())) {
                return AOMCalcValue(x.squareRoot(), unit: length)
            }
            return try plain { $0.squareRoot() }
        case "cbrt": return try plain(cbrt)
        case "abs": return AOMCalcValue(Swift.abs(x), unit: argument.unit)
        case "round": return AOMCalcValue(x.rounded(.toNearestOrAwayFromZero), unit: argument.unit)
        case "floor": return AOMCalcValue(x.rounded(.down), unit: argument.unit)
        case "ceil": return AOMCalcValue(x.rounded(.up), unit: argument.unit)
        case "trunc": return AOMCalcValue(x.rounded(.towardZero), unit: argument.unit)
        case "sin": return AOMCalcValue(snap(sin(try angle())))
        case "cos": return AOMCalcValue(snap(cos(try angle())))
        case "tan": return AOMCalcValue(snap(tan(try angle())))
        case "asin": return try plain(asin)
        case "acos": return try plain(acos)
        case "atan": return try plain(atan)
        case "log", "log10": return try plain(log10)
        case "log2": return try plain(log2)
        case "ln": return try plain(log)
        case "exp": return try plain(exp)
        default: throw AOMCalcError.unknownName
        }
    }

    /// sin(π) is 1.2e-16 in binary floating point; show 0.
    private static func snap(_ value: Double) -> Double {
        Swift.abs(value) < 1e-14 ? 0 : value
    }

    /// 3 m × 4 m, 2 m × 3 m², 60 km/h × 2 h, 100 Mbps × 10 s.
    private static func product(_ a: Double, _ left: AOMCalculatorUnit, _ b: Double, _ right: AOMCalculatorUnit) throws -> AOMCalcValue {
        let base = left.toBase(a) * right.toBase(b)
        func express(_ dimension: AOMCalculatorUnit.Dimension, preferred: AOMCalculatorUnit?) throws -> AOMCalcValue {
            guard let unit = preferred ?? AOMCalculatorUnits.base(of: dimension) else { throw AOMCalcError.units }
            return AOMCalcValue(unit.fromBase(base), unit: unit)
        }
        switch (left.dimension, right.dimension) {
        case (.length, .length): return try express(.area, preferred: AOMCalculatorUnits.squared(left))
        case (.length, .area): return try express(.volume, preferred: AOMCalculatorUnits.cubed(left))
        case (.area, .length): return try express(.volume, preferred: AOMCalculatorUnits.cubed(right))
        case (.speed, .time): return try express(.length, preferred: numerator(of: left))
        case (.time, .speed): return try express(.length, preferred: numerator(of: right))
        case (.dataRate, .time): return try express(.data, preferred: numerator(of: left))
        case (.time, .dataRate): return try express(.data, preferred: numerator(of: right))
        default: throw AOMCalcError.units
        }
    }

    /// 100 km / 2 h, 1 GB / 8 s, 12 m² / 3 m.
    private static func quotient(_ a: Double, _ left: AOMCalculatorUnit, _ b: Double, _ right: AOMCalculatorUnit) throws -> AOMCalcValue {
        let base = left.toBase(a) / right.toBase(b)
        func express(_ dimension: AOMCalculatorUnit.Dimension, preferred: AOMCalculatorUnit?) throws -> AOMCalcValue {
            guard let unit = preferred ?? AOMCalculatorUnits.base(of: dimension) else { throw AOMCalcError.units }
            return AOMCalcValue(unit.fromBase(base), unit: unit)
        }
        let compound = AOMCalculatorUnits.lookup("\(left.symbol)/\(right.symbol)")
        switch (left.dimension, right.dimension) {
        case (.length, .time): return try express(.speed, preferred: compound?.dimension == .speed ? compound : nil)
        case (.data, .time): return try express(.dataRate, preferred: compound?.dimension == .dataRate ? compound : nil)
        case (.area, .length): return try express(.length, preferred: right)
        case (.volume, .length): return try express(.area, preferred: AOMCalculatorUnits.squared(right))
        case (.volume, .area):
            let length = right.id.hasSuffix("²") ? AOMCalculatorUnits.unit(String(right.id.dropLast())) : nil
            return try express(.length, preferred: length)
        default: throw AOMCalcError.units
        }
    }

    /// km/h → km, MB/s → MB, Mbps → Mbit.
    private static func numerator(of rate: AOMCalculatorUnit) -> AOMCalculatorUnit? {
        let map = ["km/h": "km", "mph": "mi", "m/s": "m", "ft/s": "ft", "kn": "nmi",
                   "B/s": "B", "KB/s": "kB", "MB/s": "MB", "GB/s": "GB", "MiB/s": "MiB",
                   "bps": "bit", "kbps": "kbit", "Mbps": "Mbit", "Gbps": "Gbit"]
        return map[rate.id].flatMap(AOMCalculatorUnits.unit)
    }
}
