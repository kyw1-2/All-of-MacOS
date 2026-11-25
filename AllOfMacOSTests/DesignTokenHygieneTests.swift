import XCTest

final class DesignTokenHygieneTests: XCTestCase {
    private let files = [
        "Launcher/AOMLauncherCraftViews.swift", "Clipboard/AOMPasteCraftCard.swift",
        "Audio/AOMSoundSourceControlBoard.swift", "Automation/AOMAutomationRecipeView.swift",
        "MenuBar/AOMMenuBarCraftPanel.swift"
    ]

    /// A source convention for the reviewed view files, not a Swift parser.
    private func violations(in source: String) -> [String] {
        let rules = [
            (#"\bwithAnimation\s*\(\s*(?!\s*AOMCraftMotion\.resolve\s*\()"#, "Use AOMCraftMotion.resolve"),
            (#"\bwithAnimation\s*\{"#, "Choose a motion token"),
            (#"\bColor\s*\(\s*red\s*:"#, "Use a color token"),
            (#"\.scaleEffect\s*\("#, "Keep content size stable")
        ]
        let withoutLineComments = source.components(separatedBy: .newlines).map {
            String($0.components(separatedBy: "//")[0])
        }.joined(separator: "\n")
        let text = withoutLineComments as NSString
        return rules.flatMap { pattern, message -> [String] in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: withoutLineComments, range: NSRange(location: 0, length: text.length)).map {
                let line = text.substring(to: $0.range.location).components(separatedBy: "\n").count
                return "\(line): \(message)"
            }
        }
    }

    func testCraftViewsDoNotBypassMotionOrColorTokens() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AllOfMacOS/Views")
        for path in files {
            let source = try String(contentsOf: views.appendingPathComponent(path), encoding: .utf8)
            let issues = violations(in: source)
            XCTAssertTrue(issues.isEmpty, "\(path) \(issues.joined(separator: ", "))")
        }
    }

    func testApprovedMotionAndForbiddenForms() {
        XCTAssertTrue(violations(in: "withAnimation(\n AOMCraftMotion.resolve(curve, reduceMotion: true)) {}").isEmpty)
        for sample in ["withAnimation(.spring) {}", "withAnimation { run() }",
                       "Color(\nred: 1, green: 1, blue: 1)", "card.scaleEffect(1.05)"] {
            XCTAssertEqual(violations(in: sample).count, 1, sample)
        }
    }
}
