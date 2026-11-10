import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

@MainActor
final class MainWindowMaterialTests: XCTestCase {
    func testMainChromeOnlyMirrorsTheAppearanceChoice() {
        let host = NSHostingView(rootView: Color.clear.background(AOMMainWindowChrome(appearance: "dark")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        host.rootView = Color.clear.background(AOMMainWindowChrome(appearance: "light"))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.appearance?.name, .aqua)
        host.rootView = Color.clear.background(AOMMainWindowChrome(appearance: "system"))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(window.appearance)
        // The title bar and toolbar stay the system's: SwiftUI owns the
        // toolbar (page tools) and the sidebar draws its own material.
        XCTAssertNil(window.toolbar, "The chrome must not install a toolbar of its own")
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .visible)
    }

}
