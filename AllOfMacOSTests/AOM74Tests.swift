import XCTest
@testable import AllOfMacOS

/// 7.4: @screen / @window, system toggles, desktops, menu bar hider,
/// memory watch, meeting alerts, browser tabs, notch HUD.
@MainActor
final class AOM74Tests: XCTestCase {
    // MARK: Ask AI attachments

    func testScreenMentionsAreAttachmentsNotRecords() {
        let parsed = AOMAIRecordScope.parse("@window what does this error mean?")
        XCTAssertEqual(parsed.question, "what does this error mean?")
        XCTAssertEqual(parsed.scope.attachments, [.window])
        XCTAssertTrue(parsed.scope.isEmpty, "an attachment needs no record tools")
        XCTAssertTrue(parsed.scope.toolNames.isEmpty)
        let both = AOMAIRecordScope.parse("@clip @screen @wiki compare")
        XCTAssertEqual(both.scope.attachments, [.clip, .screen])
        XCTAssertEqual(both.scope.toolNames, ["search_records", "read_file"])
        XCTAssertEqual(AOMAIRecordScope.parse("@display hi").scope.attachments, [.screen])
    }

    func testRecordsOffStillSendsWhatWasAttached() {
        let asked = AOMAIRecordScope(sources: [.wiki, .window, .clip])
        let effective = AOMAIRecordsMode.effective(asked, egress: .external(host: "x"), mode: .never, onDeviceReadsMac: false)
        XCTAssertEqual(effective.sources, [.window, .clip])
    }

    func testScreenTextAttachmentRefusesSecretsAndEmptyText() {
        if case .success = AOMAIAttachment.screenText("  \n ", label: "Screen", heading: "h") { XCTFail("empty text attached") }
        if case .success = AOMAIAttachment.screenText("token sk-abcdefghijklmnopqrstuvwxyz123456", label: "Screen", heading: "h") {
            XCTFail("a key was attached")
        }
        guard case .success(let ok) = AOMAIAttachment.screenText(" error: file not found ", label: "Xcode window", heading: "Text read from Xcode") else {
            return XCTFail("plain text refused")
        }
        XCTAssertEqual(ok.text, "error: file not found")
        XCTAssertTrue(ok.sent.contains("Text read from Xcode:\n```\nerror: file not found\n```"))
        let long = String(repeating: "a", count: AOMAIAttachment.limit + 50)
        if case .success(let cut) = AOMAIAttachment.screenText(long, label: "Screen", heading: "h") { XCTAssertEqual(cut.text.count, AOMAIAttachment.limit) }
    }

    func testReceiptNamesEveryAttachment() {
        var receipt = AOMAIReceipt(destination: "api.anthropic.com", leavesMac: true, allowed: "Nothing")
        receipt.attached = ["Clipboard", "Safari window"]
        XCTAssertTrue(receipt.line.contains("Attached: Clipboard, Safari window"))
        receipt.attached = nil
        receipt.clipboardAttached = true
        XCTAssertTrue(receipt.line.contains("Clipboard attached"))
    }

    func testOldReceiptsDecodeWithoutAttachedField() throws {
        let old = #"{"destination":"x","leavesMac":true,"allowed":"Nothing","used":[],"earlierTurns":0,"clipboardAttached":true}"#
        let receipt = try JSONDecoder().decode(AOMAIReceipt.self, from: Data(old.utf8))
        XCTAssertNil(receipt.attached)
        XCTAssertTrue(receipt.clipboardAttached)
    }

    // MARK: System toggles

    func testNewActionsHaveCopyAndDefaults() {
        for type in [ActionType.moveWindowToDesktop, .setBluetoothPower, .setAirplaneMode, .dismissNotifications] {
            XCTAssertFalse(type.description.isEmpty, type.rawValue)
            XCTAssertTrue(ParityActions.handles(type) || ExtendedActions.handles(type), type.rawValue)
        }
        XCTAssertEqual(ActionType.moveWindowToDesktop.requiredHotKeyID(desktop: 3), SymbolicHotKeys.desktop(3))
    }

    func testAirplaneModeRestoresOnlyWhatWasOn() {
        XCTAssertEqual(AOMRadios.restore(from: .init(wifi: true, bluetooth: false)), .init(wifi: true, bluetooth: false))
        XCTAssertEqual(AOMRadios.restore(from: nil), .init(wifi: true, bluetooth: true))
    }

    func testNotificationCloseActionNames() {
        XCTAssertEqual(NotificationDismisser.actionTitle("Name:Close\nTarget:0x0\nSelector:(null)"), "close")
        XCTAssertEqual(NotificationDismisser.actionTitle("AXPress"), "axpress")
        XCTAssertEqual(NotificationDismisser.closeAction(in: ["AXPress", "Name:Show\nTarget:0x0", "Name:Close\nTarget:0x0"]), "Name:Close\nTarget:0x0")
        XCTAssertEqual(NotificationDismisser.closeAction(in: ["Name:Close\nTarget:0x0", "Name:Clear All\nTarget:0x0"]), "Name:Clear All\nTarget:0x0")
        XCTAssertEqual(NotificationDismisser.closeAction(in: ["Name:닫기\nTarget:0x0"]), "Name:닫기\nTarget:0x0")
        XCTAssertNil(NotificationDismisser.closeAction(in: ["AXPress", "Name:Options\nTarget:0x0"]))
    }

    func testDesktopRowsUseNamesAndStayUnique() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AOM74Desktops"))
        defaults.removePersistentDomain(forName: "AOM74Desktops")
        AOMDesktopNames.setName("  Mail  ", for: 2, defaults: defaults)
        XCTAssertEqual(AOMDesktopNames.name(2, defaults: defaults), "Mail")
        AOMDesktopNames.setName("", for: 2, defaults: defaults)
        XCTAssertNil(AOMDesktopNames.name(2, defaults: defaults))
        AOMDesktopNames.setName("x", for: 10, defaults: defaults)
        XCTAssertNil(AOMDesktopNames.name(10, defaults: defaults))
        let ids = PaletteSystemCommand.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(PaletteSystemCommand.desktops.count, 9)
    }

    // MARK: Modules

    func testOptInModulesStartOffAndTurnOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AOM74Modules"))
        defaults.removePersistentDomain(forName: "AOM74Modules")
        // An old "off" list naming an opt-in module doesn't turn it on or off.
        defaults.set(["files", "memoryWatch"], forKey: AOMModuleSwitches.key)
        let switches = AOMModuleSwitches(defaults: defaults)
        XCTAssertFalse(switches.isOn(.files))
        XCTAssertFalse(switches.isOn(.memoryWatch))
        XCTAssertNil(switches.set(.memoryWatch, on: true))
        XCTAssertTrue(switches.isOn(.memoryWatch))
        XCTAssertEqual(AOMModuleSwitches(defaults: defaults).optedIn, [.memoryWatch])
        XCTAssertFalse(AOMModuleSwitches(defaults: defaults).off.contains(.memoryWatch))
    }

    func testMenuBarHiderCollapsesOnlyLeftOfTheChevron() {
        XCTAssertTrue(MenuBarHider.canCollapse(dividerMinX: 900, toggleMinX: 930))
        XCTAssertFalse(MenuBarHider.canCollapse(dividerMinX: 960, toggleMinX: 930))
        XCTAssertFalse(MenuBarHider.canCollapse(dividerMinX: nil, toggleMinX: 930))
    }

    func testMemoryWatchAlertsAndQuietPeriod() {
        let gb: UInt64 = 1_073_741_824
        XCTAssertEqual(MemoryWatch.alerts(pressureLevel: 1, swapUsed: 2 * gb, swapLimit: 8 * gb), [])
        XCTAssertEqual(MemoryWatch.alerts(pressureLevel: 4, swapUsed: 9 * gb, swapLimit: 8 * gb), [.pressure(4), .swap(9 * gb)])
        let now = Date()
        XCTAssertTrue(MemoryWatch.shouldPost("swap", now: now, last: [:]))
        XCTAssertFalse(MemoryWatch.shouldPost("swap", now: now, last: ["swap": now.addingTimeInterval(-600)]))
        XCTAssertTrue(MemoryWatch.shouldPost("swap", now: now, last: ["swap": now.addingTimeInterval(-1_900)]))
        XCTAssertEqual(MemoryWatch.appBundle(of: "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
                       "/Applications/Google Chrome.app")
        XCTAssertNil(MemoryWatch.appBundle(of: "/usr/libexec/trustd"))
        XCTAssertEqual(MemoryWatch.group(of: "/opt/homebrew/bin/ollama"), "ollama")
        XCTAssertEqual(MemoryWatch.group(of: "/Applications/Slack.app/Contents/MacOS/Slack"), "/Applications/Slack.app")
    }

    // MARK: Meetings

    private func event(_ title: String, start: TimeInterval, length: TimeInterval = 1_800, allDay: Bool = false, now: Date) -> PaletteSchedule.Event {
        PaletteSchedule.Event(id: title, title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + length),
                              isAllDay: allDay, calendar: "Work", location: nil, meetingLink: nil)
    }

    func testMeetingCountdownPicksTheNextTimedEvent() {
        let now = Date()
        let events = [event("Holiday", start: -3_600, length: 86_400, allDay: true, now: now),
                      event("Later", start: 3_600, now: now), event("Standup with the whole team", start: 600, now: now)]
        let next = MeetingAlerts.next(events, now: now, window: 1_800)
        XCTAssertEqual(next?.title, "Standup with the whole team")
        XCTAssertEqual(next.map { MeetingAlerts.countdown($0, now: now) }, "10m Standup with the…")
        XCTAssertNil(MeetingAlerts.next([event("Later", start: 3_600, now: now)], now: now, window: 1_800))
    }

    func testMeetingAlertFiresOnceAndAfterSnooze() {
        let now = Date()
        let soon = event("Sync", start: 45, now: now)
        XCTAssertTrue(MeetingAlerts.alertDue(soon, now: now, lead: 60, alerted: [], snoozedUntil: nil))
        XCTAssertFalse(MeetingAlerts.alertDue(soon, now: now, lead: 60, alerted: [MeetingAlerts.key(soon)], snoozedUntil: nil))
        XCTAssertFalse(MeetingAlerts.alertDue(soon, now: now, lead: 60, alerted: [MeetingAlerts.key(soon)], snoozedUntil: now.addingTimeInterval(30)))
        XCTAssertTrue(MeetingAlerts.alertDue(soon, now: now.addingTimeInterval(31), lead: 60, alerted: [MeetingAlerts.key(soon)], snoozedUntil: now.addingTimeInterval(30)))
        XCTAssertFalse(MeetingAlerts.alertDue(event("Far", start: 600, now: now), now: now, lead: 60, alerted: [], snoozedUntil: nil))
    }

    // MARK: Browser tabs

    func testBrowserTabsParseAndScripts() {
        let chrome = PaletteBrowserTabs.browsers[1]
        let json = #"{"windows":[{"index":1,"id":"7","titles":["GitHub",""],"urls":["https://github.com/","https://example.com/a"],"ids":["11","12"]},{"index":2,"id":"8","titles":["Docs"],"urls":["https://developer.apple.com/"],"ids":["21"]}]}"#
        let tabs = PaletteBrowserTabs.parse(json, browser: chrome).tabs
        XCTAssertEqual(tabs.map(\.title), ["GitHub", "https://example.com/a", "Docs"])
        XCTAssertEqual(tabs.map(\.window), [1, 1, 2])
        XCTAssertEqual(tabs[2].index, 1)
        XCTAssertEqual(tabs[0].host, "github.com")
        XCTAssertEqual(tabs.map(\.tabID), ["11", "12", "21"])
        XCTAssertTrue(PaletteBrowserTabs.parse("not json", browser: chrome).tabs.isEmpty)
        XCTAssertTrue(PaletteBrowserTabs.activateScript(tabs[1]).contains("w.activeTabIndex = k + 1"))
        let safari = PaletteBrowserTabs.Tab(browser: PaletteBrowserTabs.browsers[0], window: 2, index: 3, title: "t", url: "u")
        XCTAssertTrue(PaletteBrowserTabs.activateScript(safari).contains("w.currentTab = w.tabs[k]"))
        XCTAssertTrue(PaletteBrowserTabs.readScript(PaletteBrowserTabs.browsers[0]).contains("w.tabs.name()"))
        XCTAssertEqual(PaletteBrowserTabs.jsString("a\"b"), #""a\"b""#)
    }

    // MARK: Notch

    func testNotchRectIsTheGapBetweenTheTopAreas() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rect = GestureHUD.notchRect(frame: frame, left: CGRect(x: 0, y: 950, width: 660, height: 32),
                                        right: CGRect(x: 852, y: 950, width: 660, height: 32), top: 32)
        XCTAssertEqual(rect, CGRect(x: 660, y: 950, width: 192, height: 32))
        XCTAssertNil(GestureHUD.notchRect(frame: frame, left: CGRect(x: 0, y: 950, width: 756, height: 32),
                                          right: CGRect(x: 756, y: 950, width: 756, height: 32), top: 32))
    }
}
