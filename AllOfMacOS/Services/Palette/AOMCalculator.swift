import Foundation

/// 3.4 scaffold: the safe calculator shared by the ⌘K palette and Text
/// Actions (owner: the Palette agent). Never NSExpression: it can call
/// methods named in the text.
enum AOMCalculator {
    struct Result: Equatable {
        /// The numeric value, when the result is a number.
        let value: Double?
        /// What to show and copy ("132", "10 km = 6.214 mi").
        let display: String
    }

    /// The result of a plain arithmetic expression or a unit conversion, or
    /// nil when the text is not one.
    static func evaluate(_ text: String) -> Result? { nil }
}
