import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ScrollChromePolicyTests: XCTestCase {
    func testLegacyTracksDoNotReserveSpaceAndDocumentStillScrolls() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let scroll = NSScrollView(frame: host.bounds)
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        host.addSubview(scroll)
        AOMScrollChromePolicy.shared.attach(in: host)
        scroll.tile()
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentSize.width, 320, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.origin, NSPoint(x: 100, y: 300))
    }

    func testFrameworkResetCannotRestoreTracks() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        AOMScrollChromePolicy.shared.attach(in: scroll)
        for _ in 0..<3 {
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.scrollerStyle = .legacy
            XCTAssertFalse(scroll.hasVerticalScroller)
            XCTAssertFalse(scroll.hasHorizontalScroller)
            XCTAssertEqual(scroll.scrollerStyle, .overlay)
        }
    }

    func testNewNestedEditorIsDiscoveredAndReleased() {
        let host = NSView()
        AOMScrollChromePolicy.shared.attach(in: host)
        weak var releasedScroll: NSScrollView?
        autoreleasepool {
            let wrapper = NSView()
            let scroll = NSScrollView()
            releasedScroll = scroll
            scroll.hasVerticalScroller = true
            host.addSubview(wrapper)
            wrapper.addSubview(scroll)
            AOMScrollChromePolicy.shared.attach(in: host)
            XCTAssertFalse(scroll.hasVerticalScroller)
            scroll.removeFromSuperview()
            wrapper.removeFromSuperview()
        }
        XCTAssertNil(releasedScroll)
    }
}
