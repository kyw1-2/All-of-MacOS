import Foundation

/// The safe calculator shared by the ⌘K palette and Text Actions. A
/// recursive-descent parser over a closed grammar (AOMCalculatorParser.swift):
/// numbers with "." or "," decimals, + − × ÷ * / ^ % !, parentheses, a fixed
/// list of functions and constants, percentages ("20% of 150", "150 + 10%"),
/// unit conversions (AOMCalculatorUnits.swift) and 0x / 0b / 0o numbers.
/// Never NSExpression: it can call methods named in the text. Nothing in the
/// text is looked up, run or used as a format string.
enum AOMCalculator {
    struct Result: Equatable {
        /// The numeric value (in the answer's unit), when the result is a number.
        let value: Double?
        /// The answer alone, to show and copy: "132", "6.21371 mi", "0xFF".
        let display: String
        /// The question as read, for context: "12 * 11", "10 km".
        var expression: String? = nil
        var kind: Kind = .number
    }

    enum Kind: Equatable {
        /// Arithmetic ("12 * 11" → "132", "1 km + 500 m" → "1.5 km").
        case number
        /// A unit conversion ("10 km in mi", or "10 km" alone → mi).
        case conversion
        /// A number in another base ("255 in hex" → "0xFF").
        case base
    }

    /// Longer text is never a sum worth evaluating (and bounds the work).
    static let maximumLength = 256

    /// The answer for arithmetic or a unit conversion, or nil when the text
    /// is not one. A lone number ("42", "pi") is not a calculation.
    static func evaluate(_ text: String) -> Result? {
        evaluate(text, locale: .current)
    }

    /// `locale` decides "1,000" (a thousand where "," groups digits, one
    /// where it is the decimal separator) and the answer's separator when
    /// the text has no decimals.
    static func evaluate(_ text: String, locale: Locale) -> Result? {
        guard let input = normalized(text) else { return nil }
        let localeDecimal: Character = locale.decimalSeparator == "," ? "," : "."
        guard let tokens = try? AOMCalcLexer.tokens(input, localeDecimal: localeDecimal) else { return nil }
        var parser = AOMCalcParser(tokens: tokens)
        guard let parsed = try? parser.parseInput() else { return nil }
        let (value, target) = parsed
        // Answer in the writer's convention: "1,5 + 2" → "3,5".
        let decimal: Character = tokens.contains(where: \.decimalComma) ? ","
            : tokens.contains(where: \.decimalPoint) ? "." : localeDecimal
        let echo = collapsed(input)

        switch target {
        case .base(let base)?:
            guard value.unit == nil, let display = baseString(value.number, base: base) else { return nil }
            return Result(value: value.number, display: display, expression: echo, kind: .base)
        case .unit(let unit)?:
            guard let source = value.unit else { return nil }
            return convert(value.number, from: source, to: unit, decimal: decimal, question: echo)
        case nil:
            if let unit = value.unit {
                if parser.arithmetic == 0 {
                    // "10 km" alone: the usual counterpart (mi), if there is one.
                    guard let fallback = AOMCalculatorUnits.defaultTarget(for: unit) else { return nil }
                    return convert(value.number, from: unit, to: fallback, decimal: decimal, question: echo)
                }
                guard let number = format(value.number, significant: 10, decimal: decimal) else { return nil }
                return Result(value: value.number, display: quantity(number, unit), expression: echo, kind: .number)
            }
            guard parser.arithmetic > 0, let display = format(value.number, significant: 12, decimal: decimal) else { return nil }
            return Result(value: value.number, display: display, expression: echo, kind: .number)
        }
    }

    // MARK: Input

    /// Full-width forms (from a Korean or Japanese input source) become
    /// ASCII; "= 2 + 2" and "2 + 2 =" lose the equals sign. Control and
    /// format characters (NUL, bidi overrides) are refused.
    static func normalized(_ text: String) -> String? {
        guard text.utf16.count <= maximumLength * 4 else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                if let ascii = Unicode.Scalar(scalar.value - 0xFEE0) { scalars.append(ascii) }
            case 0x3000:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("=") { result.removeFirst() }
        while let last = result.last, last == "=" || last == "?" || last.isWhitespace { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= maximumLength,
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return result
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Output

    private static func convert(_ number: Double, from source: AOMCalculatorUnit, to target: AOMCalculatorUnit,
                                decimal: Character, question: String) -> Result? {
        guard source.dimension == target.dimension else { return nil }
        let converted = target.fromBase(source.toBase(number))
        guard let shown = format(converted, significant: 6, decimal: decimal) else { return nil }
        return Result(value: converted, display: quantity(shown, target), expression: question, kind: .conversion)
    }

    static func quantity(_ number: String, _ unit: AOMCalculatorUnit) -> String {
        unit.spaced ? "\(number) \(unit.symbol)" : "\(number)\(unit.symbol)"
    }

    /// Plain digits without grouping, so the answer pastes into any field:
    /// whole numbers up to 2^53 in full, then scientific ("1.2e+18");
    /// fractions rounded to `significant` digits with trailing zeros cut
    /// (0.1 + 0.2 → "0.3"). Nil for infinity and NaN.
    static func format(_ value: Double, significant: Int, decimal: Character = ".") -> String? {
        guard value.isFinite else { return nil }
        if value == 0 { return "0" }
        let magnitude = Swift.abs(value)
        let exactInteger = value.rounded() == value && magnitude < 9_007_199_254_740_992
        var text: String
        if exactInteger && magnitude >= 1 {
            text = String(Int64(value))
        } else if magnitude >= 1e15 || magnitude < 1e-9 {
            text = scientific(value, significant: significant)
        } else {
            let digits = max(0, min(15, significant - 1 - Int(floor(log10(magnitude)))))
            text = String(format: "%.\(digits)f", value)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            if text == "-0" { text = "0" }
        }
        return decimal == "," ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    private static func scientific(_ value: Double, significant: Int) -> String {
        let raw = String(format: "%.\(max(0, significant - 1))e", value)
        guard let marker = raw.firstIndex(of: "e") else { return raw }
        var mantissa = String(raw[raw.startIndex..<marker])
        if mantissa.contains(".") {
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
        }
        let exponent = raw[raw.index(after: marker)...]
        let sign = exponent.first == "-" ? "-" : "+"
        let digits = exponent.drop { $0 == "+" || $0 == "-" || $0 == "0" }
        return mantissa + "e" + sign + (digits.isEmpty ? "0" : String(digits))
    }

    /// "0xFF", "0b1010", "0o17", or plain digits; whole numbers only.
    static func baseString(_ value: Double, base: Int) -> String? {
        guard value.isFinite, value.rounded() == value, Swift.abs(value) <= 9_007_199_254_740_992 else { return nil }
        let integer = Int64(value)
        let magnitude = integer.magnitude
        let body: String
        switch base {
        case 16: body = "0x" + String(magnitude, radix: 16, uppercase: true)
        case 2: body = "0b" + String(magnitude, radix: 2)
        case 8: body = "0o" + String(magnitude, radix: 8)
        default: body = String(magnitude)
        }
        return integer < 0 ? "-" + body : body
    }
}
