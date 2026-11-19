import AppKit
import CoreAudio
import XCTest
@testable import AllOfMacOS

/// 6.5: the 6.4.0 integration report's merge order 1–3 (Keep Awake presets,
/// app row actions, uninstall review entry) and the HomePod readiness gate.
final class PaletteAppActionTests: XCTestCase {
    func testActionsKeepTheirOrderSoReturnAndCommandReturnNeverChangeMeaning() {
        let path = "/Applications/Tool.app"
        let idle = PaletteAppControl.commands(isRunning: false, bundleID: "com.example.tool", path: path)
        let live = PaletteAppControl.commands(isRunning: true, bundleID: "com.example.tool", path: path)
        XCTAssertEqual(idle, [.showInFinder, .uninstall])
        XCTAssertEqual(live, [.showInFinder, .hide, .quit, .forceQuit, .uninstall])
        XCTAssertEqual(idle.first, live.first, "⌘↩ is Show in Finder whether or not the app runs")
    }

    func testProtectedAppsAreNeverQuitFromASearchRow() {
        XCTAssertEqual(PaletteAppControl.commands(isRunning: true, bundleID: "com.apple.finder",
                                                  path: "/System/Library/CoreServices/Finder.app"),
                       [.showInFinder, .hide])
        XCTAssertEqual(PaletteAppControl.commands(isRunning: true, bundleID: "com.kyw.allofmacos",
                                                  path: "/Applications/All of MacOS.app"),
                       [.showInFinder], "AOM neither hides, quits nor uninstalls itself")
        XCTAssertEqual(PaletteAppControl.commands(isRunning: true, bundleID: "com.apple.dock",
                                                  path: "/System/Library/CoreServices/Dock.app"),
                       [.showInFinder, .hide])
    }

    func testAppsThatShipWithMacOSGetNoUninstallReview() {
        XCTAssertEqual(PaletteAppControl.commands(isRunning: true, bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
                       [.showInFinder, .hide, .quit, .forceQuit])
        XCTAssertFalse(PaletteAppControl.isUninstallable(bundleID: "com.example.tool", path: "/System/Applications/Tool.app"))
        XCTAssertFalse(PaletteAppControl.isUninstallable(bundleID: nil, path: "/Applications/Broken.app"))
    }

    func testOnlyTheSearchedCopyIsTargeted() {
        let running: [(key: String?, bundleID: String?)] = [
            ("/Applications/Same.app", "com.example.same"),
            ("/Volumes/Backup/Same.app", "com.example.same"),
            ("/Applications/Same.app", "com.example.replaced"),
            (nil, "com.example.same"),
        ]
        XCTAssertEqual(PaletteAppControl.matches(installedKey: "/Applications/Same.app", bundleID: "com.example.same",
                                                 running: running), [0],
                       "another copy, a different app now at the path and a bundle-less process are left alone")
        XCTAssertEqual(PaletteAppControl.matches(installedKey: "/Applications/Same.app", bundleID: nil, running: running), [0, 2])
    }

    func testRunningAppsOutsideTheScannedFoldersAreListedOnce() {
        let folders = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/Shared/Applications")]
        let installed = [PaletteApplications.App(name: "Tool", url: URL(fileURLWithPath: "/Applications/Tool.app"))]
        let running = [URL(fileURLWithPath: "/Applications/Tool.app"),
                       URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Simulator.app"),
                       URL(fileURLWithPath: "/Volumes/Work/Editor.app"),
                       URL(fileURLWithPath: "/Volumes/Work/Editor.app"),
                       URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                       URL(fileURLWithPath: "/usr/libexec/helper")]
        let merged = PaletteApplications.merged(installed, running: running, folders: folders)
        XCTAssertEqual(merged.map(\.url.path), ["/Applications/Tool.app", "/Volumes/Work/Editor.app"])
        XCTAssertEqual(merged.last?.name, "Editor")
    }

    func testAppRowsKeepEveryActionWhileOtherRowsStayAtThree() {
        let actions = (0..<5).map { index in QuickCommandPalette.PaletteAction(title: "A\(index)") {} }
        let row = QuickCommandPalette.PaletteItem(id: "x", title: "X", subtitle: "", icon: "app", section: .applications,
                                                  primary: .init(title: "Open") {}, secondaries: actions, secondaryLimit: .max)
        let other = QuickCommandPalette.PaletteItem(id: "y", title: "Y", subtitle: "", icon: "doc", section: .commands,
                                                    primary: .init(title: "Run") {}, secondaries: actions)
        XCTAssertEqual(row.actions.count, 6, "⌘K and the row menu reach the last action")
        XCTAssertEqual(other.actions.count, 4)
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.action(at: 5, of: row)?.title, "A4")
    }

    @MainActor
    func testUninstallRequestIsTakenOnce() {
        let requests = SystemToolsRequests()
        let app = URL(fileURLWithPath: "/Applications/Tool.app")
        requests.requestUninstall(app)
        XCTAssertEqual(requests.takeUninstall(), app)
        XCTAssertNil(requests.takeUninstall(), "reopening System Tools does not start a second review")
    }
}

final class PaletteCommandSearchTests: XCTestCase {
    private func command(_ id: String, _ title: String, keywords: String) -> QuickCommandPalette.PaletteItem {
        var item = QuickCommandPalette.PaletteItem(id: id, title: title, subtitle: "", icon: "timer", section: .commands,
                                                   primary: .init(title: "Run") {})
        item.keywords = keywords
        return item
    }

    func testKeepAwakePresetsAreFoundByTheirKoreanNames() {
        let items = [command("system.keepAwake.30", "Keep Awake for 30 Minutes", keywords: "30분 30 minutes caffeine 잠자기"),
                     command("system.keepAwake.display", "Keep Display On", keywords: "화면 켜기 화면 유지"),
                     command("capture.area", "Capture Area", keywords: "")]
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: items, query: "30분").map(\.id), ["system.keepAwake.30"])
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: items, query: "화면 켜기").map(\.id), ["system.keepAwake.display"])
    }

    @MainActor
    func testWindowLayoutsUseDistinctExistingActions() {
        let layouts = QuickCommandPalette.windowLayouts
        XCTAssertEqual(Set(layouts.map(\.id)).count, layouts.count)
        XCTAssertEqual(Set(layouts.map(\.type)).count, layouts.count)
        XCTAssertFalse(layouts.contains { [.snapWindowLeft, .snapWindowRight, .maximizeWindow].contains($0.type) },
                       "left, right and maximize already have rows")
    }
}

final class KeepAwakePresetTests: XCTestCase {
    @MainActor
    func testSwitchingThirtyToSixtyMinutesAcquiresBeforeReleasing() {
        let service = KeepAwakeService()
        service.blockedBatteryPercent = { nil }
        var next: UInt32 = 1
        var log: [String] = []
        service.createAssertion = { minutes, display in
            defer { next += 1 }
            log.append("create \(next)")
            return .init(id: next, minutes: minutes, keepDisplay: display, endsAt: nil)
        }
        service.releaseAssertion = { log.append("release \($0)") }
        XCTAssertTrue(service.start(minutes: 30, keepDisplay: false))
        XCTAssertTrue(service.start(minutes: 60, keepDisplay: false))
        XCTAssertEqual(log, ["create 1", "create 2", "release 1"])
        XCTAssertEqual(service.currentMinutes, 60)
        XCTAssertTrue(service.start(minutes: nil, keepDisplay: true))
        XCTAssertEqual(service.current?.keepDisplay, true)
        service.stop()
        XCTAssertFalse(service.hasAssertion)
    }
}

final class AirPlayReadinessTests: XCTestCase {
    func testOnlyExplicitEvidenceHoldsAnAttachBack() {
        XCTAssertTrue(AirPlayDeviceReadiness.isReady(alive: 1, nominalRate: 44_100))
        XCTAssertTrue(AirPlayDeviceReadiness.isReady(alive: nil, nominalRate: nil), "unanswered reads keep 6.4's behaviour")
        XCTAssertFalse(AirPlayDeviceReadiness.isReady(alive: 0, nominalRate: 44_100), "a receiver that is not alive")
        XCTAssertFalse(AirPlayDeviceReadiness.isReady(alive: 1, nominalRate: 0), "a zombie stream with no clock")
        XCTAssertFalse(AirPlayDeviceReadiness.isReady(alive: 1, nominalRate: .nan))
    }

    func testSnapshotCarriesTheGatheredReadiness() {
        var snapshot = AudioControlSnapshot()
        let homePod = AudioOutputDevice(id: 77, uid: "HomePod-UID", name: "HomePod")
        snapshot.devices = [homePod]
        snapshot.transport[77] = kAudioDeviceTransportTypeAirPlay
        XCTAssertTrue(snapshot.isReadyAirPlay(homePod))
        snapshot.unreadyAirPlay.insert(77)
        XCTAssertFalse(snapshot.isReadyAirPlay(homePod))
        XCTAssertTrue(snapshot.isAirPlay(homePod))
    }

    func testReconnectLink() {
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://audio-reconnect")!), .reconnectAudio)
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://audio-reconnect?force=1")!), "unknown flags fail closed")
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://audio-restart-coreaudio")!),
                     "restarting Core Audio is never a link: it asks for a password")
    }

    @MainActor
    func testRestartCommandIsTheFixedKillall() {
        XCTAssertEqual(SystemToolsCommand.administratorScript([AudioRecovery.restartCommand]),
                       "do shell script \"'/usr/bin/killall' 'coreaudiod'\" with administrator privileges")
    }
}
