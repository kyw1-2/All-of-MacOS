import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.22.0 — DeepSeek's 2026-11-26 commercial-app report applied:
/// clipboard secret protection and lifetimes, Scene automation, layout
/// conversion, recording polish and System Tools instruments.
@MainActor
final class AOM7220ClipboardTests: XCTestCase {
    private func entry(_ text: String, copied: Date, pinned: Bool = false) -> ClipboardEntry {
        var value = ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]],
                                            sourceName: "Test", sourceBundleID: "com.test", at: copied)
        if pinned { value.pinboardIDs = [UUID()] }
        return value
    }

    func testExpiredItemsLeaveEvenWhenPinned() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var timed = entry("hello", copied: now)
        timed.expiresAt = now.addingTimeInterval(-1)
        var pinned = entry("pinned", copied: now, pinned: true)
        pinned.expiresAt = now.addingTimeInterval(-1)
        let fresh = entry("fresh", copied: now)
        var future = entry("later", copied: now)
        future.expiresAt = now.addingTimeInterval(60)
        let plan = Set(ClipboardStore.removalPlan([timed, pinned, fresh, future], limits: .init(), now: now))
        XCTAssertEqual(plan, [timed.id, pinned.id])
    }

    func testSecretLifetimeRemovesOnlyOldUnpinnedSecrets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = entry("sk-old", copied: now.addingTimeInterval(-25 * 3_600))
        let recent = entry("sk-new", copied: now.addingTimeInterval(-3_600))
        let pinned = entry("sk-pin", copied: now.addingTimeInterval(-48 * 3_600), pinned: true)
        let plain = entry("notes", copied: now.addingTimeInterval(-48 * 3_600))
        let isSecret: (ClipboardEntry) -> Bool = { $0.text?.hasPrefix("sk-") == true }
        let plan = Set(ClipboardStore.removalPlan([old, recent, pinned, plain], limits: .init(), now: now, isSecret: isSecret))
        XCTAssertEqual(plan, [old.id], "default lifetime is 24 hours, pinned and plain items stay")
        var off = ClipboardStore.Settings()
        off.secretLifetimeHours = 0
        XCTAssertTrue(ClipboardStore.removalPlan([old], limits: off, now: now, isSecret: isSecret).isEmpty)
    }

    func testOlderSettingsDecodeWithDefaultSecretLifetime() throws {
        let data = Data(#"{"enabled":true,"pasteDirectly":true,"plainText":false,"retentionDays":30,"ignoredApps":[],"maxEntries":1000,"maxBytes":1024}"#.utf8)
        let settings = try JSONDecoder().decode(ClipboardStore.Settings.self, from: data)
        XCTAssertEqual(settings.secretLifetimeHours, 24)
    }

    func testOlderEntriesDecodeWithoutLifetime() throws {
        let original = entry("hello", copied: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "expiresAt"); json.removeValue(forKey: "burnAfterPaste")
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.expiresAt)
        XCTAssertFalse(decoded.pastesOnce)
    }

    func testLifetimeDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22))!
        XCTAssertEqual(ClipboardStore.Lifetime.hour.expiry(from: now), now.addingTimeInterval(3_600))
        let tomorrow = ClipboardStore.Lifetime.tomorrow.expiry(from: now, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: tomorrow), DateComponents(day: 28, hour: 9))
        XCTAssertNil(ClipboardStore.Lifetime.pasteOnce.expiry(from: now))
        XCTAssertNil(ClipboardStore.Lifetime.never.expiry(from: now))
    }

    func testConcealedMaskNeverCarriesCharacters() {
        let mask = ClipboardConcealedContent.mask(length: 40, compact: false)
        XCTAssertEqual(mask.replacingOccurrences(of: " ", with: ""), String(repeating: "•", count: 24))
        XCTAssertEqual(ClipboardConcealedContent.mask(length: 3, compact: true).filter { $0 == "•" }.count, 8)
    }

    func testLifetimeSuffix() {
        let now = Date()
        var item = entry("x", copied: now)
        XCTAssertEqual(ClipboardPanelState.lifetimeStatus(.never, count: 1), "This item now follows the history limits.")
        item.burnAfterPaste = true
        XCTAssertEqual(ClipboardPanelState.lifetime(of: item), .pasteOnce)
        item.burnAfterPaste = nil
        item.expiresAt = now.addingTimeInterval(30 * 60)
        XCTAssertNil(ClipboardPanelState.lifetime(of: item))
    }
}
