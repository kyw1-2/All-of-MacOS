import XCTest
@testable import AllOfMacOS

/// The ⌘K calculator's grammar (also used by Text Actions): precedence and
/// associativity, percentages, functions, errors, very large numbers, the
/// decimal comma, number bases and text that must never evaluate.
final class PaletteCalculatorTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    private func answer(_ text: String, _ locale: Locale? = nil) -> String? {
        AOMCalculator.evaluate(text, locale: locale ?? english)?.display
    }

    // MARK: Precedence and associativity

    func testMultiplicationBindsTighterThanAddition() {
        XCTAssertEqual(answer("2+3*4"), "14")
        XCTAssertEqual(answer("(2+3)*4"), "20")
        XCTAssertEqual(answer("2 * 3 ^ 2"), "18")
        XCTAssertEqual(answer("12 × 11"), "132")
        XCTAssertEqual(answer("100 ÷ 8"), "12.5")
        XCTAssertEqual(answer("3 x 4"), "12")
        XCTAssertEqual(answer("3x4"), "12")
    }

    func testSubtractionAndDivisionAreLeftAssociative() {
        XCTAssertEqual(answer("10-2-3"), "5")
        XCTAssertEqual(answer("100/10/2"), "5")
        XCTAssertEqual(answer("8/2*4"), "16")
    }

    func testPowerIsRightAssociativeAndBindsTighterThanUnaryMinus() {
        XCTAssertEqual(answer("2^3^2"), "512")
        XCTAssertEqual(answer("2**3"), "8")
        XCTAssertEqual(answer("-2^2"), "-4")
        XCTAssertEqual(answer("2^-1"), "0.5")
        XCTAssertEqual(answer("2*-3"), "-6")
        XCTAssertEqual(answer("3²"), "9")
    }

    func testImplicitMultiplicationByAGroupOrAName() {
        XCTAssertEqual(answer("2(3+4)"), "14")
        XCTAssertEqual(answer("(1+2)(3+4)"), "21")
        XCTAssertEqual(answer("2pi"), "6.28318530718")
        XCTAssertNil(answer("2 3"), "two numbers side by side are not a product")
    }

    // MARK: Percentages

    func testPercentages() {
        XCTAssertEqual(answer("20% of 150"), "30")
        XCTAssertEqual(answer("150 + 10%"), "165")
        XCTAssertEqual(answer("150 - 10%"), "135")
        XCTAssertEqual(answer("150 * 10%"), "15")
        XCTAssertEqual(answer("25% off 80"), "60")
        XCTAssertEqual(answer("10 % 3"), "1", "a percent sign before an operand is the remainder")
        XCTAssertEqual(answer("10 mod 4"), "2")
    }

    // MARK: Functions and constants

    func testFunctions() {
        XCTAssertEqual(answer("sqrt(16)"), "4")
        XCTAssertEqual(answer("sqrt 16 + 9"), "13", "a function without parentheses takes the next term")
        XCTAssertEqual(answer("√9"), "3")
        XCTAssertEqual(answer("abs(-3.5)"), "3.5")
        XCTAssertEqual(answer("round(2.5)"), "3")
        XCTAssertEqual(answer("floor(-1.5)"), "-2")
        XCTAssertEqual(answer("ceil(1.2)"), "2")
        XCTAssertEqual(answer("sin(pi/2)"), "1")
        XCTAssertEqual(answer("cos(0)"), "1")
        XCTAssertEqual(answer("tan(0)"), "0")
        XCTAssertEqual(answer("sin(pi)"), "0", "floating-point dust is shown as 0")
        XCTAssertEqual(answer("sin(30°)"), "0.5", "an angle unit converts to radians")
        XCTAssertEqual(answer("log(1000)"), "3")
        XCTAssertEqual(answer("ln(e)"), "1")
        XCTAssertEqual(answer("log2(8)"), "3")
        XCTAssertEqual(answer("5!"), "120")
    }

    func testConstantsNeedAnOperation() {
        XCTAssertNil(answer("pi"), "a lone constant is not a calculation")
        XCTAssertNil(answer("e"), "typing e to search must not show 2.718")
        XCTAssertEqual(answer("pi*2"), "6.28318530718")
        XCTAssertEqual(answer("e^2"), "7.38905609893")
    }

    func testALoneNumberIsNotACalculation() {
        XCTAssertNil(answer("42"))
        XCTAssertNil(answer("-5"))
        XCTAssertNil(answer("(7)"))
        XCTAssertNil(answer("3.14"))
    }

    // MARK: Errors

    func testInvalidInputGivesNoAnswer() {
        for text in ["1/0", "0/0", "sqrt(-1)", "log(0)", "(1+2", "1+2)", "1+", "*3", "", "   ", "1,2,3", "171!", "2.5!",
                     "10 % 0", "5 ++", "abc", "1password", "100 USD", "0x", "0xZZ", "2 apples"] {
            XCTAssertNil(answer(text), "“\(text)” is not a sum")
        }
    }

    func testEqualsSignsAreIgnored() {
        XCTAssertEqual(answer("2 + 2 ="), "4")
        XCTAssertEqual(answer("= 6 * 7"), "42")
        XCTAssertEqual(answer("1 km in m = ?"), "1000 m")
    }

    // MARK: Large and small numbers

    func testHugeNumbers() {
        XCTAssertEqual(answer("10^15"), "1000000000000000")
        XCTAssertEqual(answer("2^52"), "4503599627370496", "whole numbers up to 2^53 are shown in full")
        XCTAssertEqual(answer("2^60"), "1.15292150461e+18")
        XCTAssertEqual(answer("20!"), "2.43290200818e+18")
        XCTAssertEqual(answer("1e300 * 1e8"), "1e+308")
        XCTAssertNil(answer("10^308 * 10"), "an overflow is no answer, not “inf”")
        XCTAssertNil(answer("1e308 + 1e308"))
        XCTAssertNil(answer("2^2^2^2^2^2^2^2"))
        XCTAssertNil(answer("9!!!"), "362880! overflows at once instead of looping")
        XCTAssertEqual(answer("1/3"), "0.333333333333")
        XCTAssertEqual(answer("0.1 + 0.2"), "0.3", "binary rounding error is cut at 12 significant digits")
        XCTAssertEqual(answer("1e-12 * 3"), "3e-12")
    }

    // MARK: Decimal comma

    func testDecimalCommaFromTheText() {
        XCTAssertEqual(answer("3,5 + 1,25"), "4,75", "the answer uses the separator the text used")
        XCTAssertEqual(answer("0,1 + 0,2"), "0,3")
        XCTAssertEqual(answer("1,5 × 2"), "3")
    }

    func testThousandsSeparatorDependsOnTheLocale() {
        XCTAssertEqual(answer("1,000 + 1", english), "1001", "a comma before three digits groups thousands in English")
        XCTAssertEqual(answer("1,000 + 1", german), "2", "but is a decimal comma in German")
        XCTAssertEqual(answer("1.000 + 1", german), "1001")
        XCTAssertEqual(answer("1,234,567 + 1", english), "1234568")
        XCTAssertEqual(answer("1.234,5 * 2", german), "2469")
        XCTAssertEqual(answer("1,234.5 * 2", english), "2469")
        XCTAssertNil(answer("1,23,4 + 1", english), "irregular groups are refused")
    }

    func testAnswerSeparatorFollowsTheLocaleWithoutDecimals() {
        XCTAssertEqual(answer("7/2", english), "3.5")
        XCTAssertEqual(answer("7/2", german), "3,5")
    }

    // MARK: Bases

    func testNumberBases() {
        XCTAssertEqual(answer("0xff"), "255")
        XCTAssertEqual(answer("0b1010 + 1"), "11")
        XCTAssertEqual(answer("0o17"), "15")
        XCTAssertEqual(answer("255 in hex"), "0xFF")
        XCTAssertEqual(answer("10 in bin"), "0b1010")
        XCTAssertEqual(answer("8 in octal"), "0o10")
        XCTAssertEqual(answer("0x1F in dec"), "31")
        XCTAssertEqual(answer("-255 in hex"), "-0xFF")
        XCTAssertNil(answer("2.5 in hex"), "only whole numbers have a hex form")
        XCTAssertEqual(AOMCalculator.evaluate("255 in hex", locale: english)?.kind, .base)
    }

    // MARK: Hostile text

    func testInjectionStringsNeverEvaluate() {
        let hostile = [
            "system(\"ls\")", "NSExpression(format: \"1+1\")", "FUNCTION(1, 'exit')", "1; rm -rf ~", "$(whoami)", "`id`",
            "%@ %@", "1 + 1\u{0}", "../../etc/passwd", "<script>alert(1)</script>", "\u{202E}1+1", "1+1 # comment",
            "valueForKey:", "@sum.self", "1 + '1'", "eval(1)", "exec 1", "1 && 2", "1 | 2", "{1}", "[1]",
        ]
        for text in hostile { XCTAssertNil(answer(text), "“\(text)” must not evaluate") }
    }

    func testOversizedInputIsRefusedQuickly() {
        let long = Array(repeating: "1+", count: 500).joined() + "1"
        XCTAssertNil(answer(long), "longer than 256 characters")
        let deep = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        XCTAssertNil(answer(deep), "nesting is bounded")
        let start = Date()
        _ = answer(String(repeating: "-", count: 250) + "1")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testFullWidthInputFromAnInputMethod() {
        XCTAssertEqual(answer("１２＋３"), "15")
        XCTAssertEqual(answer("１０％　ｏｆ　５０"), "5")
    }

    // MARK: Result

    func testResultCarriesTheQuestionAndTheValue() throws {
        let result = try XCTUnwrap(AOMCalculator.evaluate("12   *  11", locale: english))
        XCTAssertEqual(result.value, 132)
        XCTAssertEqual(result.expression, "12 * 11")
        XCTAssertEqual(result.kind, .number)
        // Text Actions builds results with the two-field initializer.
        XCTAssertEqual(AOMCalculator.Result(value: 7, display: "7").display, "7")
    }

    func testFormatting() {
        XCTAssertEqual(AOMCalculator.format(-0.0, significant: 12), "0")
        XCTAssertEqual(AOMCalculator.format(1234.5678, significant: 12), "1234.5678")
        XCTAssertEqual(AOMCalculator.format(2.5, significant: 12, decimal: ","), "2,5")
        XCTAssertNil(AOMCalculator.format(.infinity, significant: 12))
        XCTAssertNil(AOMCalculator.format(.nan, significant: 12))
        XCTAssertEqual(AOMCalculator.baseString(255, base: 16), "0xFF")
        XCTAssertNil(AOMCalculator.baseString(1.5, base: 2))
    }
}
