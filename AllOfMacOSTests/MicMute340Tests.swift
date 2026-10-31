import AppKit
import CoreAudio
import XCTest
@testable import AllOfMacOS

/// The microphone mute helper: the toggle / push-to-talk / auto-mute state
/// machine, the push-to-talk key tracker, and the controller on a fake
/// microphone and HUD. No real hardware, monitor or event tap is touched.
final class MicMute340Tests: XCTestCase {
    // MARK: - State machine

    func testToggleFlipsWhatPeopleHear() {
        var machine = MicMuteMachine(muted: false)
        XCTAssertEqual(machine.toggle(), .apply(muted: true, cause: .toggle))
        XCTAssertTrue(machine.muted)
        XCTAssertEqual(machine.toggle(), .apply(muted: false, cause: .toggle))
        XCTAssertFalse(machine.muted)
        XCTAssertEqual(machine.set(muted: false), .none, "Already open")
    }

    func testPushToTalkOpensOnlyAMutedMicrophoneWhileHeld() {
        var machine = MicMuteMachine(muted: true)
        XCTAssertEqual(machine.keyDown(), .apply(muted: false, cause: .talkStarted))
        XCTAssertTrue(machine.talking)
        XCTAssertFalse(machine.muted)
        XCTAssertEqual(machine.keyDown(), .none, "Key repeat changes nothing")
        XCTAssertEqual(machine.keyUp(), .apply(muted: true, cause: .talkEnded))
        XCTAssertTrue(machine.muted)
        XCTAssertEqual(machine.keyUp(), .none, "A second release changes nothing")

        var open = MicMuteMachine(muted: false)
        XCTAssertEqual(open.keyDown(), .none, "Push-to-talk never acts on an open microphone")
        XCTAssertEqual(open.keyUp(), .none, "…and its release never mutes it")
        XCTAssertFalse(open.muted)
    }

    func testToggleWhileTalkingMutesAndEndsTheTalk() {
        var machine = MicMuteMachine(muted: true)
        _ = machine.keyDown()
        XCTAssertEqual(machine.toggle(), .apply(muted: true, cause: .toggle), "Toggling flips what people hear: open → muted")
        XCTAssertFalse(machine.talking)
        XCTAssertEqual(machine.keyUp(), .none, "The release no longer changes anything")
        XCTAssertTrue(machine.muted)

        var unmute = MicMuteMachine(muted: true)
        _ = unmute.keyDown()
        _ = unmute.toggle()
        XCTAssertEqual(unmute.toggle(), .apply(muted: false, cause: .toggle))
        XCTAssertFalse(unmute.resting)
    }

    func testChangesMadeElsewhereAreAdoptedNotApplied() {
        var machine = MicMuteMachine(muted: true)
        XCTAssertEqual(machine.observe(hardwareMuted: true), .none, "Reading back what AOM wrote")
        XCTAssertEqual(machine.observe(hardwareMuted: false), .adopt(muted: false), "Unmuted in the Audio page or Control Center")
        XCTAssertFalse(machine.resting)
        XCTAssertEqual(machine.keyDown(), .none, "Now open: push-to-talk has nothing to do")

        var talking = MicMuteMachine(muted: true)
        _ = talking.keyDown()
        XCTAssertEqual(talking.observe(hardwareMuted: true), .adopt(muted: true), "Muted by another app mid-talk")
        XCTAssertFalse(talking.talking)
        XCTAssertEqual(talking.keyUp(), .none)
        XCTAssertTrue(talking.muted)
    }

    func testAutoMuteWhileTalkingWaitsForTheRelease() {
        var machine = MicMuteMachine(muted: false)
        XCTAssertEqual(machine.autoMute(app: "Zoom"), .apply(muted: true, cause: .autoMute("Zoom")))
        XCTAssertEqual(machine.autoMute(app: "Zoom"), .none, "Already muted")

        var talking = MicMuteMachine(muted: true)
        _ = talking.keyDown()
        XCTAssertEqual(talking.autoMute(app: "Teams"), .none, "The held key keeps it open for now")
        XCTAssertEqual(talking.keyUp(), .apply(muted: true, cause: .talkEnded))
    }

    func testANewMicrophoneStaysMutedButIsNeverOpenedAutomatically() {
        var muted = MicMuteMachine(muted: true)
        XCTAssertEqual(muted.deviceChanged(newDeviceMuted: false), .apply(muted: true, cause: .deviceChanged))
        XCTAssertEqual(muted.deviceChanged(newDeviceMuted: true), .none)

        var open = MicMuteMachine(muted: false)
        XCTAssertEqual(open.deviceChanged(newDeviceMuted: false), .none)
        XCTAssertEqual(open.deviceChanged(newDeviceMuted: true), .adopt(muted: true), "A muted new device stays muted")
        XCTAssertTrue(open.muted)
    }

    // MARK: - Key tracker

    func testTrackerSeesOnlyItsOwnKeyAndCatchesMissedReleases() {
        var tracker = PushToTalkTracker(key: .rightOption)
        let option = NSEvent.ModifierFlags.option.rawValue
        XCTAssertNil(tracker.handle(keyCode: 58, flags: option | 0x20), "Left Option isn't the key")
        XCTAssertEqual(tracker.handle(keyCode: 61, flags: option | 0x40), .pressed)
        XCTAssertNil(tracker.handle(keyCode: 61, flags: option | 0x40), "No second press")
        XCTAssertNil(tracker.handle(keyCode: 56, flags: option | 0x40 | NSEvent.ModifierFlags.shift.rawValue | 0x02),
                     "Shift going down while Right Option stays held")
        XCTAssertEqual(tracker.handle(keyCode: 56, flags: 0x02 | NSEvent.ModifierFlags.shift.rawValue), .released,
                       "Another key's event shows Right Option is up")
        XCTAssertNil(tracker.handle(keyCode: 61, flags: 0))

        XCTAssertEqual(tracker.handle(keyCode: 61, flags: option | 0x40), .pressed)
        XCTAssertNil(tracker.poll(flags: [.option]), "Still held")
        XCTAssertEqual(tracker.poll(flags: []), .released, "The hold watchdog catches a release the monitor missed")
        XCTAssertNil(tracker.reset())

        var fn = PushToTalkTracker(key: .fn)
        XCTAssertEqual(fn.handle(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue), .pressed)
        XCTAssertEqual(fn.handle(keyCode: 63, flags: 0), .released)
        XCTAssertEqual(MicPushToTalkKey.allCases.map(\.keyCode), [61, 54, 62, 60, 63])
    }

    // MARK: - Controller on a fake microphone

    @MainActor
    func testControllerToggleWritesTheHardwareAndShowsTheHUD() throws {
        let (controller, mic, hud, cleanup) = makeController(muted: false)
        defer { cleanup() }
        controller.toggle()
        XCTAssertTrue(mic.muted)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(hud.shown.last?.title, "Microphone Muted")
        XCTAssertEqual(hud.shown.last?.detail, "Fake Microphone")
        controller.toggle()
        XCTAssertFalse(mic.muted)
        XCTAssertEqual(hud.shown.last?.title, "Microphone On")

        // Changed elsewhere: the next toggle starts from the real state.
        mic.muted = true
        controller.toggle()
        XCTAssertFalse(mic.muted, "Read first, so the toggle unmutes")

        controller.showsHUD = false
        controller.toggle()
        XCTAssertEqual(hud.shown.count, 3, "No HUD when it is turned off")
    }

    @MainActor
    func testControllerReportsAMicrophoneThatCantBeMuted() {
        let (controller, mic, hud, cleanup) = makeController(muted: false)
        defer { cleanup() }
        mic.canChange = false
        controller.toggle()
        XCTAssertFalse(controller.isMuted, "Never claims a mute that didn't happen")
        XCTAssertEqual(hud.failures.first?.title, "Microphone Not Muted")
        XCTAssertNotNil(controller.lastFailure)
        mic.present = false
        controller.toggle()
        XCTAssertEqual(hud.failures.last?.title, "No Microphone")
    }

    @MainActor
    func testControllerPushToTalkOpensWhileTheKeyIsHeld() {
        let (controller, mic, hud, cleanup) = makeController(muted: true)
        defer { cleanup() }
        let option = NSEvent.ModifierFlags.option.rawValue
        controller.handleFlagsChanged(keyCode: 61, flags: option | 0x40)
        XCTAssertFalse(mic.muted, "Open while held")
        XCTAssertTrue(controller.isTalking)
        XCTAssertEqual(hud.shown.last?.detail, "Release Right Option to mute")
        controller.handleFlagsChanged(keyCode: 61, flags: 0)
        XCTAssertTrue(mic.muted, "Muted again on release")
        XCTAssertFalse(controller.isTalking)
        XCTAssertEqual(hud.shown.last?.detail, "Hold Right Option to talk")

        // An auto-mute app opening mutes; one not on the list doesn't.
        controller.setMuted(false)
        XCTAssertFalse(mic.muted)
        controller.autoMuteEnabled = true
        XCTAssertTrue(controller.addAutoMuteApp(url: try! makeApp(id: "us.zoom.xos", name: "zoom.us")))
        controller.appLaunched(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertFalse(mic.muted)
        controller.appLaunched(bundleID: "us.zoom.xos", name: "zoom.us")
        XCTAssertTrue(mic.muted)
        XCTAssertEqual(hud.shown.last?.detail, "zoom.us opened")
    }

    @MainActor
    func testStatusMenuItemShowsTheState() {
        let (controller, mic, _, cleanup) = makeController(muted: true)
        defer { cleanup() }
        var item = controller.statusMenuItem()
        XCTAssertEqual(item.title, "Mute Microphone")
        XCTAssertEqual(item.state, .on, "Checked while muted")
        mic.muted = false
        item = controller.statusMenuItem()
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(item.isEnabled)
        mic.present = false
        XCTAssertFalse(controller.statusMenuItem().isEnabled, "No microphone, nothing to mute")
        XCTAssertTrue(MicMuteController.Keys.pushToTalk.hasPrefix("AOMMicMute"))
    }

    // MARK: - Helpers

    private var appFolder: URL?

    private func makeApp(id: String, name: String) throws -> URL {
        let base = appFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("MicMute340Tests-\(UUID().uuidString)")
        appFolder = base
        let app = base.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @MainActor
    private func makeController(muted: Bool) -> (MicMuteController, FakeMicrophone, FakeHUD, () -> Void) {
        let suite = "MicMute340Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: MicMuteController.Keys.pushToTalk)
        let mic = FakeMicrophone(muted: muted)
        let hud = FakeHUD()
        let controller = MicMuteController(hardware: mic, defaults: defaults, hud: hud)
        return (controller, mic, hud, { [weak self] in
            defaults.removePersistentDomain(forName: suite)
            if let folder = self?.appFolder { try? FileManager.default.removeItem(at: folder) }
        })
    }
}

private final class FakeMicrophone: MicMuteHardware {
    var muted: Bool
    var canChange = true
    var present = true
    init(muted: Bool) { self.muted = muted }
    func deviceID() -> AudioDeviceID? { present ? 42 : nil }
    func deviceName() -> String? { present ? "Fake Microphone" : nil }
    func isMuted() -> Bool { muted }
    func setMuted(_ value: Bool) -> Bool {
        guard canChange, present else { return false }
        muted = value
        return true
    }
    func canMute() -> Bool { canChange && present }
}

@MainActor
private final class FakeHUD: MicMuteHUDPresenting {
    var shown: [(muted: Bool, title: String, detail: String?)] = []
    var failures: [(title: String, detail: String)] = []
    func show(muted: Bool, title: String, detail: String?) { shown.append((muted, title, detail)) }
    func showFailure(title: String, detail: String) { failures.append((title, detail)) }
}
