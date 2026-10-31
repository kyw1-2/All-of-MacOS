import XCTest
@testable import AllOfMacOS

/// Per-app input sources (Input Source Pro parity): which source an app
/// gets, Remember mode, the suggestions, and the controller on a fake
/// Text Input Sources seam. The real input source is never changed.
@MainActor
final class FocusInputSourceTests: XCTestCase {
    private let abc = "com.apple.keylayout.ABC"
    private let korean = "com.apple.inputmethod.Korean.2SetKorean"

    private final class FakeInputSources: FocusInputSourceSystem {
        var sources: [FocusInputSource]
        var current: String?
        var selections: [String] = []
        var secure = false
        init(sources: [FocusInputSource], current: String?) { self.sources = sources; self.current = current }
        func enabledSources() -> [FocusInputSource] { sources }
        func currentSourceID() -> String? { current }
        func select(_ id: String) -> Bool { selections.append(id); current = id; return true }
        var isSecureInputOn: Bool { secure }
    }

    private var world: FocusTestWorld!
    override func setUp() async throws { world = FocusTestWorld() }
    override func tearDown() async throws { world.cleanUp(); world = nil }

    private var sources: [FocusInputSource] {
        [FocusInputSource(id: abc, name: "ABC", languages: ["en"]),
         FocusInputSource(id: korean, name: "2-Set Korean", languages: ["ko"])]
    }

    func testARuleWinsThenTheRememberedSourceThenNothing() {
        let rules = [FocusInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: abc),
                     FocusInputSourceRule(bundleID: "com.kakao.KakaoTalkMac", appName: "KakaoTalk", sourceID: korean)]
        let available: Set<String> = [abc, korean]
        XCTAssertEqual(FocusInputSourcePolicy.target(for: "com.apple.Terminal", rules: rules, remembered: [:], remembers: false,
                                                     available: available), abc)
        XCTAssertEqual(FocusInputSourcePolicy.target(for: "com.kakao.KakaoTalkMac", rules: rules,
                                                     remembered: ["com.kakao.KakaoTalkMac": abc], remembers: true,
                                                     available: available), korean, "the rule beats what was remembered")
        XCTAssertEqual(FocusInputSourcePolicy.target(for: "com.apple.Notes", rules: rules, remembered: ["com.apple.Notes": korean],
                                                     remembers: true, available: available), korean)
        XCTAssertNil(FocusInputSourcePolicy.target(for: "com.apple.Notes", rules: rules, remembered: ["com.apple.Notes": korean],
                                                   remembers: false, available: available), "Remember mode off")
        XCTAssertNil(FocusInputSourcePolicy.target(for: "com.apple.Terminal", rules: rules, remembered: [:], remembers: false,
                                                   available: [korean]), "a source no longer enabled is ignored")
        var off = rules
        off[0].isEnabled = false
        XCTAssertNil(FocusInputSourcePolicy.target(for: "com.apple.Terminal", rules: off, remembered: [:], remembers: true,
                                                   available: available))
        XCTAssertFalse(FocusInputSourcePolicy.remembers("com.apple.Terminal", rules: rules, remembers: true),
                       "an app with a rule is never overwritten by Remember mode")
        XCTAssertTrue(FocusInputSourcePolicy.remembers("com.apple.Notes", rules: rules, remembers: true))
    }

    func testSuggestionsCoverInstalledTerminalsAndKakaoTalk() {
        let installed: Set<String> = ["com.apple.Terminal", "com.microsoft.VSCode", "com.kakao.KakaoTalkMac"]
        let suggestions = FocusInputSourcePolicy.suggestions(sources: sources, isInstalled: { installed.contains($0) }, existing: [])
        XCTAssertEqual(Set(suggestions.map(\.bundleID)), installed)
        XCTAssertEqual(suggestions.first { $0.bundleID == "com.apple.Terminal" }?.sourceID, abc)
        XCTAssertEqual(suggestions.first { $0.bundleID == "com.kakao.KakaoTalkMac" }?.sourceID, korean)
        let existing = [FocusInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: korean)]
        XCTAssertFalse(FocusInputSourcePolicy.suggestions(sources: sources, isInstalled: { installed.contains($0) },
                                                          existing: existing).contains { $0.bundleID == "com.apple.Terminal" },
                       "an app already listed keeps its choice")
        XCTAssertTrue(FocusInputSourcePolicy.suggestions(sources: [sources[0]], isInstalled: { installed.contains($0) },
                                                         existing: []).allSatisfy { $0.sourceID == abc },
                      "no Korean source enabled: no KakaoTalk suggestion")
        XCTAssertTrue(sources[1].isCJKV)
        XCTAssertFalse(sources[0].isCJKV)
        XCTAssertTrue(sources[0].isLatinLayout)
    }

    private func makeController(_ fake: FakeInputSources, remember: Bool = false) -> FocusInputSourceController {
        world.settings.settings.inputSourcesEnabled = true
        world.settings.settings.remembersInputSources = remember
        world.system.apps = [FocusRunningApp(pid: 1, bundleID: "com.apple.Safari", name: "Safari", isActive: true)]
        let controller = FocusInputSourceController(inputSources: fake, system: world.system, settings: world.settings,
                                                    lists: world.lists, schedules: false)
        controller.refresh()
        return controller
    }

    func testSwitchingAppsSelectsTheirSourceAndOnlyWhenItDiffers() {
        world.lists.setInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: abc)
        world.lists.setInputSourceRule(bundleID: "com.kakao.KakaoTalkMac", appName: "KakaoTalk", sourceID: korean)
        let fake = FakeInputSources(sources: sources, current: korean)
        let controller = makeController(fake)
        XCTAssertTrue(controller.isActive)
        controller.appActivated("com.apple.Terminal")
        XCTAssertEqual(fake.selections, [abc])
        XCTAssertEqual(controller.lastSwitch?.source, "ABC")
        controller.appActivated("com.apple.Terminal")
        XCTAssertEqual(fake.selections, [abc], "already ABC: nothing to do")
        controller.appActivated("com.kakao.KakaoTalkMac")
        XCTAssertEqual(fake.selections, [abc, korean])
        controller.appActivated("com.apple.Notes")
        XCTAssertEqual(fake.selections, [abc, korean], "no rule and Remember off: the source stays")
    }

    func testRememberModeGivesEachAppBackItsLastSource() {
        let fake = FakeInputSources(sources: sources, current: abc)
        let controller = makeController(fake, remember: true)
        controller.appActivated("com.apple.Notes")      // Safari was left with ABC
        fake.current = korean                            // the person types Korean in Notes
        controller.selectedSourceChanged()
        controller.appActivated("com.apple.Safari")
        XCTAssertEqual(fake.selections.last, abc, "Safari gets ABC back")
        controller.appActivated("com.apple.Notes")
        XCTAssertEqual(fake.selections.last, korean, "Notes gets Korean back")
        XCTAssertEqual(world.lists.lists.rememberedInputSources["com.apple.Notes"], korean)
        XCTAssertEqual(world.lists.lists.rememberedInputSources["com.apple.Safari"], abc)
        controller.appActivated("com.kyw.allofmacos")
        controller.appActivated("com.apple.Safari")
        XCTAssertNil(world.lists.lists.rememberedInputSources["com.kyw.allofmacos"], "AOM itself is never remembered")
    }

    func testNeverSwitchesDuringSecureInputWhilePausedOrForAPausedApp() {
        world.lists.setInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: abc)
        let fake = FakeInputSources(sources: sources, current: korean)
        let controller = makeController(fake)
        fake.secure = true
        controller.appActivated("com.apple.Terminal")
        XCTAssertTrue(fake.selections.isEmpty, "a password field has the keyboard")
        fake.secure = false
        world.system.paused = true
        controller.appActivated("com.apple.Terminal")
        XCTAssertTrue(fake.selections.isEmpty, "Pause AOM")
        world.system.paused = false
        world.system.pausedAppIDs = ["com.apple.Terminal"]
        controller.appActivated("com.apple.Terminal")
        XCTAssertTrue(fake.selections.isEmpty, "AOM is paused for Terminal")
        world.system.pausedAppIDs = []
        controller.appActivated("com.apple.Terminal")
        XCTAssertEqual(fake.selections, [abc])
    }

    func testOffMeansNoObserversAndNoSwitching() {
        world.lists.setInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: abc)
        let fake = FakeInputSources(sources: sources, current: korean)
        let controller = FocusInputSourceController(inputSources: fake, system: world.system, settings: world.settings,
                                                    lists: world.lists, schedules: false)
        controller.refresh()
        XCTAssertFalse(controller.isActive, "off by default")
        controller.appActivated("com.apple.Terminal")
        XCTAssertTrue(fake.selections.isEmpty)
    }

    func testTheRealInputSourcesCanBeReadWithoutChangingThem() {
        let live = FocusTISInputSources(isolated: true)
        let before = live.currentSourceID()
        let enabled = live.enabledSources()
        XCTAssertFalse(enabled.isEmpty, "this Mac has at least one keyboard input source")
        XCTAssertNotNil(before)
        XCTAssertFalse(live.select(enabled.first?.id ?? abc), "the isolated seam never selects")
        XCTAssertEqual(live.currentSourceID(), before)
    }
}
