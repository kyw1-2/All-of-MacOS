import XCTest
@testable import AllOfMacOS

/// B.3 copy rules for the action catalog's user-visible strings: one factual
/// sentence per description, at most 90 characters, no filler, no em-dash
/// asides, no stacked parentheses and no emoji.
final class AutomationCopyTests: XCTestCase {
    private static let filler = ["so you can", "right away", "the normal way", "simply", "easily",
                                 "quickly", "powerful", "seamless"]

    func testActionDescriptionsFollowCopyRules() {
        for type in ActionType.allCases {
            let text = type.description
            XCTAssertLessThanOrEqual(text.count, 90, "\(type.rawValue): \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "\(type.rawValue) has an em-dash: \(text)")
            XCTAssertLessThanOrEqual(text.filter { $0 == "(" }.count, 1, "\(type.rawValue) stacks parentheses: \(text)")
            XCTAssertFalse(text.contains(";"), "\(type.rawValue) joins clauses: \(text)")
            XCTAssertEqual(text.filter { $0 == "." }.count, 1, "\(type.rawValue) is not one sentence: \(text)")
            for phrase in Self.filler {
                XCTAssertFalse(text.lowercased().contains(phrase), "\(type.rawValue) uses filler “\(phrase)”: \(text)")
            }
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation },
                           "\(type.rawValue) has emoji: \(text)")
        }
    }

    /// Preset decoding must not depend on the display strings: the raw values
    /// of the persisted enums stay as they were.
    func testPersistedRawValuesAreUnchanged() {
        XCTAssertEqual(ActionType.maximizeWindow.rawValue, "Maximize Window")
        XCTAssertEqual(ActionType.snapWindowLeft.rawValue, "Snap Window Left Half")
        XCTAssertEqual(TriggerCategory.all.rawValue, "All")
        XCTAssertEqual(TriggerCategory.otherTriggers.rawValue, "Other Triggers")
        XCTAssertEqual(ActionCategory.windowManagement.rawValue, "Window Management")
    }
}
