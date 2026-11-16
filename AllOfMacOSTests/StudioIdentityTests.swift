import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// AOM 5.0 "Studio": every destination has a distinct identity, and the
/// action bar offers each page its own actions, related tools and AOM-wide
/// commands.
final class StudioIdentityTests: XCTestCase {
    func testEveryDestinationHasADistinctMark() {
        let identities = AOMMainTab.allCases.map(\.identity)
        XCTAssertEqual(Set(identities.map(\.symbol)).count, AOMMainTab.allCases.count, "symbols must be unique")
        // Only Workspace wears the brand gradient.
        XCTAssertEqual(AOMMainTab.allCases.filter { $0.identity.isBrand }, [.home])
        for tab in AOMMainTab.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tab.identity.symbol, accessibilityDescription: nil),
                            "\(tab) uses a missing SF Symbol \(tab.identity.symbol)")
            XCTAssertFalse(tab.tagline.isEmpty)
        }
    }

    func testModuleHuesAreDistinctInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            var seen: [String] = []
            for tab in AOMMainTab.allCases where !tab.identity.isBrand {
                var key = ""
                appearance.performAsCurrentDrawingAppearance {
                    let color = NSColor(tab.identity.color).usingColorSpace(.sRGB)!
                    key = String(format: "%.2f-%.2f-%.2f", color.redComponent, color.greenComponent, color.blueComponent)
                }
                XCTAssertFalse(seen.contains(key), "\(tab) repeats another tool's hue in \(name.rawValue)")
                seen.append(key)
            }
        }
    }

    func testSettingsCategoriesUseExistingSymbols() {
        for category in SettingsCategory.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: category.identity.symbol, accessibilityDescription: nil),
                            "\(category) uses a missing SF Symbol")
        }
    }

    func testActionBarRelatedToolsStayInTheTaskFamily() {
        for group in AOMFeatureGroup.allCases {
            for tab in group.tabs {
                let related = AOMActionBarModel.related(to: tab)
                XCTAssertFalse(related.contains(tab))
                XCTAssertEqual(Set(related), Set(group.tabs).subtracting([tab]))
            }
        }
        // Workspace points at the first tool of every family.
        XCTAssertEqual(AOMActionBarModel.related(to: .home), AOMFeatureGroup.allCases.compactMap(\.tabs.first))
    }

    func testEveryQuickActionBelongsToExactlyOnePage() {
        let owned = AOMMainTab.allCases.flatMap { AOMActionBarModel.quickActions(for: $0) }
        XCTAssertEqual(Set(owned), Set(WorkspaceQuickActionKind.allCases))
        XCTAssertEqual(owned.count, WorkspaceQuickActionKind.allCases.count)
        XCTAssertEqual(AOMActionBarModel.quickActions(for: .capture).first, .captureArea)
    }

    @MainActor
    func testActionPanelEndsWithAOMCommands() {
        let appState = AppState()
        for tab in AOMMainTab.allCases {
            let sections = AOMActionBarModel.sections(for: tab, appState: appState, paletteKeys: "⌘K",
                                                      openPalette: {}, openSettings: {})
            XCTAssertEqual(sections.last?.title, "All of MacOS")
            XCTAssertEqual(sections.last?.actions.map(\.id), ["aom.search", "aom.pause", "aom.settings"])
            let ids = sections.flatMap(\.actions).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(tab) lists an action twice")
        }
    }

    func testWorkspaceGreetingFollowsTheClock() {
        func at(_ hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        XCTAssertEqual(AOMWorkspaceGreeting.text(at: at(8)), "Good morning")
        XCTAssertEqual(AOMWorkspaceGreeting.text(at: at(14)), "Good afternoon")
        XCTAssertEqual(AOMWorkspaceGreeting.text(at: at(20)), "Good evening")
        XCTAssertEqual(AOMWorkspaceGreeting.text(at: at(2)), "Working late")
    }
}
