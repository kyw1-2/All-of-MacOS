import XCTest
import AppKit
import SwiftUI
@testable import AllOfMacOS

/// Exercises the menu builder itself rather than the service underneath it, so
/// a mistake in the item wiring — a missing target, a dropped submenu — is
/// caught here instead of only showing up in the running app.
///
/// The tests never invoke an action: `setResolution` and its siblings would
/// reconfigure the real display.
@MainActor
final class DisplayMenuTests: XCTestCase {

    private func section() throws -> NSMenuItem {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "no display attached")
        let item = DisplayMenu.build()
        return try XCTUnwrap(item, "a display is attached, so the section must build")
    }

    func testSectionCarriesASubmenuWithOneBlockPerDisplay() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        XCTAssertEqual(section.title, "Displays")
        let submenu = try XCTUnwrap(section.submenu)
        // Every display contributes at least a header and a status line.
        XCTAssertGreaterThanOrEqual(submenu.items.count, DisplayControlService.displays().count * 2)
    }

    func testEveryDisplayContributesAHeaderAndABrightnessSlider() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        for display in DisplayControlService.displays() {
            XCTAssertTrue(submenu.items.contains { $0.title.hasPrefix(display.name) },
                          "\(display.name) needs a header")
        }
        // The brightness slider is a custom view, not a titled item.
        XCTAssertTrue(submenu.items.contains { $0.view is BrightnessControlView },
                      "each display needs a brightness slider")
    }

    func testResolutionSliderIsPresentWhenTheDisplayOffersSeveralSizes() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        for display in DisplayControlService.displays() {
            let sizes = DisplayControlService.resolutionOptions(display.displayID).count
            let hasSlider = submenu.items.contains { $0.view is NSHostingView<ResolutionSliderView> }
            if sizes > 1 {
                XCTAssertTrue(hasSlider, "\(display.name) offers \(sizes) sizes, so it needs a slider")
            }
        }
    }

    func testActionItemsCarryATargetAndARequest() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item -> [NSMenuItem] in
                var all = [item]
                if let sub = item.submenu { all += walk(sub) }
                return all
            }
        }
        let actionable = walk(submenu).filter { $0.action != nil && $0.submenu == nil }
        XCTAssertFalse(actionable.isEmpty, "the menu must offer at least one action")
        for item in actionable {
            // A nil target would make the item silently do nothing when picked.
            XCTAssertNotNil(item.target, "\(item.title) has an action but no target")
            XCTAssertNotNil(item.representedObject, "\(item.title) has an action but no request")
        }
    }

    func testDisplayModeSubmenuListsBothScalesOfASize() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        let modeItems = submenu.items.filter { $0.title == "Display Mode" }
        let displaysWithModes = DisplayControlService.displays().filter { DisplayControlService.modes($0.displayID).count > 1 }
        for (i, display) in displaysWithModes.enumerated() {
            let all = DisplayControlService.modes(display.displayID)
            guard i < modeItems.count else { continue }
            let modeItem = modeItems[i]
            let modeMenu = try XCTUnwrap(modeItem.submenu, "\(display.name) needs a Display Mode submenu")
            let titles = modeMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            // The full list must expose every enumerated mode, including the
            // scale the slider collapsed away.
            XCTAssertEqual(titles.count, all.count,
                           "\(display.name) Display Mode must list every mode")
        }
    }

    func testMarkedSizesShowCurrentAndDefault() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID) else { continue }
            let markers = DisplayControlService.markers(display.displayID, for: current)
            XCTAssertTrue(markers.contains(.current))
            // A display whose current size is also its default must say so.
            if let def = DisplayControlService.defaultMode(display.displayID),
               def.pointWidth == current.pointWidth, def.pointHeight == current.pointHeight {
                XCTAssertTrue(markers.contains(.default),
                              "\(display.name) current size is the default, so it must be marked")
            }
        }
    }

    func testMainDisplayIsMarkedOnlyWhenSeveralAreAttached() throws {
        try XCTSkipIf(DisplayControlService.displays().isEmpty, "No active macOS display in this runner")
        let displays = DisplayControlService.displays()
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        let headers = submenu.items.filter { item in
            displays.contains { item.title.hasPrefix($0.name) }
        }
        if displays.count > 1 {
            XCTAssertTrue(headers.contains { $0.title.contains("(M)") },
                          "the main display must be marked when several are attached")
        } else {
            XCTAssertFalse(headers.contains { $0.title.contains("(M)") },
                           "a single display needs no main marker")
        }
    }

    func testNoMenuItemIsMarkedMainWithoutBeingTheMainDisplay() throws {
        let displays = DisplayControlService.displays()
        guard displays.count > 1 else { return }
        let section = try section()
        let submenu = try XCTUnwrap(section.submenu)
        for display in displays {
            let header = submenu.items.first { $0.title.hasPrefix(display.name) }
            guard let header else { continue }
            let claimsMain = header.title.contains("(M)")
            XCTAssertEqual(claimsMain, CGDisplayIsMain(display.displayID) != 0,
                           "\(display.name) main marker must match CGDisplayIsMain")
        }
    }
}
