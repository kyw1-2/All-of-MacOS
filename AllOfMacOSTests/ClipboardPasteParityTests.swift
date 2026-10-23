import AppKit
import XCTest
@testable import AllOfMacOS

/// Pure-logic checks for the Paste 6.5.2 UI/UX parity pass.
/// Reference: PASTE-UIUX-SPEC.md (REA evidence ledger, not committed).
@MainActor
final class ClipboardPasteParityTests: XCTestCase {

    func testDateFiltersFollowPasteOrderAndBoundaries() {
        XCTAssertEqual(ClipboardPanelState.dateFilters.map(\.title),
                       ["Today", "Yesterday", "This Week", "Last Week", "Last 30 Days"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 2 // Monday
        // Friday 2026-10-16 15:00 KST
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15))!
        let today = calendar.startOfDay(for: now)
        let yesterday = ClipboardPanelState.dateRange(for: -1, now: now, calendar: calendar)
        XCTAssertEqual(yesterday.since, calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertEqual(yesterday.before, today)
        let thisWeek = ClipboardPanelState.dateRange(for: -7, now: now, calendar: calendar)
        XCTAssertEqual(thisWeek.since, calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        XCTAssertNil(thisWeek.before)
        let lastWeek = ClipboardPanelState.dateRange(for: -14, now: now, calendar: calendar)
        XCTAssertEqual(lastWeek.since, calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        XCTAssertEqual(lastWeek.before, thisWeek.since)
        XCTAssertEqual(ClipboardPanelState.dateRange(for: 1, now: now, calendar: calendar).since, today)
        XCTAssertNil(ClipboardPanelState.dateRange(for: 0, now: now, calendar: calendar).since)
        XCTAssertEqual(ClipboardPanelState.dateRange(for: 30, now: now, calendar: calendar).since,
                       calendar.date(byAdding: .day, value: -29, to: today))
    }

    func testPasteStackDirectionTogglesNextItem() {
        let state = ClipboardPanelState()
        let saved = state.stackReversed
        defer { state.stackReversed = saved }
        let a = UUID(), b = UUID(), c = UUID()
        state.stack = [a, b, a, c]
        state.stackReversed = false
        XCTAssertEqual(state.nextStackID, a)
        state.removeStackItem(a)
        XCTAssertEqual(state.stack, [b, a, c], "Oldest-first removes the first occurrence")
        state.stackReversed = true
        XCTAssertEqual(state.nextStackID, c)
        state.removeStackItem(a)
        XCTAssertEqual(state.stack, [b, c], "Newest-first removes the last occurrence")
    }

    func testPinboardColorsMatchPastePicker() throws {
        XCTAssertEqual(ClipboardStore.boardColors,
                       ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"])
        let store = ClipboardStore()
        let board = store.createBoard(name: "Work")
        store.setBoardColor(id: board.id, color: "gray")
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.color, "gray")
        store.setBoardColor(id: board.id, color: "chartreuse")
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.color, "gray", "Unknown colours are rejected")
    }

    func testRelativeDatesReadLikePaste() {
        let now = Date()
        XCTAssertEqual(ClipboardRelativeDate.string(now.addingTimeInterval(-5), now: now), "Just now")
        let minutes = ClipboardRelativeDate.string(now.addingTimeInterval(-16 * 60), now: now)
        XCTAssertTrue(minutes.contains("16"), minutes)
        XCTAssertFalse(ClipboardRelativeDate.string(now.addingTimeInterval(60), now: now).isEmpty,
                       "Clock skew must not produce future phrasing errors")
    }

    func testFormattedTextKeepsRTFAndPlainTextDropsIt() throws {
        let bold = NSAttributedString(string: "Hi", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try bold.data(from: NSRange(location: 0, length: bold.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let formatted = ClipboardStore.textRepresentations("Hi", rtfData: rtf)
        XCTAssertNotNil(formatted[NSPasteboard.PasteboardType.rtf.rawValue])
        XCTAssertEqual(formatted[NSPasteboard.PasteboardType.string.rawValue], Data("Hi".utf8))

        let plain = NSAttributedString(string: "Hi", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let plainRTF = try plain.data(from: NSRange(location: 0, length: plain.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertNil(ClipboardStore.textRepresentations("Hi", rtfData: plainRTF)[NSPasteboard.PasteboardType.rtf.rawValue],
                     "Unformatted text stays a plain-text clip")
    }

    func testRichTextEditRoundTripsThroughStore() async throws {
        let store = ClipboardStore()
        await store.ready()
        let entry = try XCTUnwrap(store.createTextItem("draft"))
        let bold = NSAttributedString(string: "final", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try bold.data(from: NSRange(location: 0, length: bold.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        store.editText(entryID: entry.id, text: "final", rtfData: rtf)
        let edited = try XCTUnwrap(store.entries.first { $0.id == entry.id })
        XCTAssertEqual(edited.text, "final")
        XCTAssertEqual(edited.kind, .text)
        XCTAssertNotNil(edited.items.first?[NSPasteboard.PasteboardType.rtf.rawValue])
    }

    func testDominantIconColorIsReadableUnderWhiteText() throws {
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        let color = try XCTUnwrap(AppMetadataCache.dominantColor(of: icon))
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(ns.redComponent, ns.blueComponent, "Orange icon gives an orange header")
        XCTAssertLessThanOrEqual(ns.brightnessComponent, 0.83)

        let grayIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(white: 0.9, alpha: 1).setFill(); rect.fill(); return true
        }
        let gray = try XCTUnwrap(NSColor(try XCTUnwrap(AppMetadataCache.dominantColor(of: grayIcon))).usingColorSpace(.deviceRGB))
        XCTAssertLessThanOrEqual(gray.brightnessComponent, 0.43, "Light neutral icons still get a dark header")
    }

    func testPanelHeightClamp() {
        XCTAssertEqual(ClipboardPanelController.defaultHeight, 280)
        XCTAssertEqual(ClipboardPanelController.clampedHeight(50, visibleHeight: 1000), 175)
        XCTAssertEqual(ClipboardPanelController.clampedHeight(900, visibleHeight: 1000), 482)
    }
}
