import XCTest
import AppKit
@testable import AllOfMacOS

/// Actions added for BetterTouchTool parity. None of these tests performs a real
/// system effect: window/Space/mouse/keyboard/system actions are reached only
/// through the `onActionExecuted` hook, pure planners are tested as values, and
/// anything that could touch the clipboard uses a private named pasteboard.
final class BTTActionParityTests: XCTestCase {
    private var previousHook: ((TriggerAction) -> Void)?

    override func setUp() {
        super.setUp()
        previousHook = ActionExecutor.onActionExecuted
        ActionFlowState.reset()
        AskForInput.provider = nil
    }
    override func tearDown() {
        ActionExecutor.onActionExecuted = previousHook
        AskForInput.provider = nil
        ActionConfirmation.presenter = ActionConfirmation.defaultPresenter
        ActionFlowState.reset()
        super.tearDown()
    }

    private func unique(_ prefix: String = "bttp") -> String { prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func marker(_ name: String) -> TriggerAction {
        var a = TriggerAction(actionType: .showHUD); a.parameters.label = name; return a
    }
    /// Runs actions with the hook installed; returns the labels/types the hook saw.
    @discardableResult
    private func run(_ actions: [TriggerAction], timeout: TimeInterval = 5) -> (fired: [String], ok: Bool) {
        var fired: [String] = []
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.label ?? $0.actionType.rawValue) }
        let done = expectation(description: "sequence")
        var result = false
        ActionExecutor.executeActions(actions) { result = $0; done.fulfill() }
        wait(for: [done], timeout: timeout)
        return (fired, result)
    }

    // MARK: - Catalog, persistence

    func testEveryActionHasDescriptionIconCategoryAndUniqueRawValue() {
        var seen = Set<String>()
        for type in ActionType.allCases {
            XCTAssertTrue(seen.insert(type.rawValue).inserted, "duplicate raw value \(type.rawValue)")
            XCTAssertFalse(type.description.isEmpty, "\(type.rawValue) lacks a description")
            XCTAssertFalse(type.iconName.isEmpty)
            XCTAssertTrue(ActionType.actionsForCategory(type.category).contains(type))
            XCTAssertEqual(ActionType(rawValue: type.rawValue), type)
        }
        XCTAssertGreaterThanOrEqual(ActionType.allCases.count, 175)
    }

    func testNewCategoriesAreAppendedAndPopulated() {
        XCTAssertEqual(Array(ActionCategory.allCases.prefix(10)).map(\.rawValue),
                       ["Workflow", "Window Management", "Keyboard", "Application Control", "System Actions",
                        "Script Execution", "Media Controls", "Mouse & Trackpad", "Screen Capture", "Clipboard"])
        for category in [ActionCategory.spacesMissionControl, .controlFlow, .utilityActions] {
            XCTAssertFalse(ActionType.actionsForCategory(category).isEmpty)
            XCTAssertFalse(category.iconName.isEmpty)
        }
    }

    func testOldPresetJSONStillDecodesAndNewFieldsDefaultToNil() throws {
        let old = """
        {"id":"\(UUID().uuidString)","actionType":"Snap Window Left Half","isEnabled":true,
         "parameters":{"snapDisplay":"next","delayBeforeMs":5,"scrollAmount":4}}
        """
        let action = try JSONDecoder().decode(TriggerAction.self, from: Data(old.utf8))
        XCTAssertEqual(action.actionType, .snapWindowLeft)
        let p = action.parameters
        XCTAssertEqual(p.snapDisplay, "next"); XCTAssertEqual(p.scrollAmount, 4)
        XCTAssertNil(p.windowTarget); XCTAssertNil(p.moveResizeUnit); XCTAssertNil(p.desktopNumber)
        XCTAssertNil(p.clickButton); XCTAssertNil(p.requiresConfirmation); XCTAssertNil(p.levelPercent)
        XCTAssertNil(p.loopCount); XCTAssertNil(p.waitCondition); XCTAssertNil(p.pauseSeconds)
        let empty = try JSONDecoder().decode(ActionParameters.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ActionParameters())
    }

    func testNewParametersRoundTrip() throws {
        var a = TriggerAction(actionType: .moveResizeWindow)
        a.parameters.moveResizeUnit = "pixels"; a.parameters.moveResizeAnchor = "bottomRight"
        a.parameters.moveResizeX = 20; a.parameters.moveResizeY = 30
        a.parameters.moveResizeWidth = 800; a.parameters.moveResizeHeight = 600; a.parameters.windowTarget = "underCursor"
        a.parameters.clickModifiers = NSEvent.ModifierFlags.command.rawValue; a.parameters.waitCondition = "fileExists"
        a.parameters.requiresConfirmation = false; a.parameters.levelPercent = 42.5; a.parameters.pauseSeconds = 3
        let decoded = try JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
    }

    // MARK: - Group 1: window management

    func testTopAndBottomHalvesTileTheVisibleArea() {
        let visible = CGRect(x: 100, y: 50, width: 1200, height: 801)
        let top = WindowGeometry.topHalf(of: visible), bottom = WindowGeometry.bottomHalf(of: visible)
        XCTAssertEqual(top.width, visible.width); XCTAssertEqual(top.minY, visible.minY)
        XCTAssertEqual(top.maxY, bottom.minY, accuracy: 0.001)
        XCTAssertEqual(bottom.maxY, visible.maxY, accuracy: 0.001)
        XCTAssertEqual(top.height, visible.height / 2, accuracy: 0.001)
        XCTAssertEqual(ActionType.snapWindowTopHalf.category, .windowManagement)
        XCTAssertEqual(ActionType.snapWindowBottomHalf.category, .windowManagement)
    }

    func testCustomFramePercentAnchoredTopLeft() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = WindowGeometry.customFrame(current: CGRect(x: 10, y: 10, width: 300, height: 200), visible: visible,
            unit: "percent", anchor: "topLeft", x: 10, y: 20, width: 50, height: 40)
        XCTAssertEqual(frame, CGRect(x: 144, y: 25 + 175, width: 720, height: 350))
    }

    func testCustomFrameBottomRightOffsetsAreInwardAndPixelsWork() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = WindowGeometry.customFrame(current: CGRect(x: 0, y: 0, width: 100, height: 100), visible: visible,
            unit: "pixels", anchor: "bottomRight", x: 20, y: 30, width: 400, height: 300)
        XCTAssertEqual(frame, CGRect(x: 580, y: 470, width: 400, height: 300))
    }

    func testCustomFrameCenterKeepsCurrentSizeWhenNoSizeGivenAndClamps() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let current = CGRect(x: 5, y: 5, width: 200, height: 100)
        XCTAssertEqual(WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "center",
            x: 0, y: 0, width: nil, height: nil), CGRect(x: 400, y: 350, width: 200, height: 100))
        // An offset that would push the window off screen is clamped back inside.
        let clamped = WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "center",
            x: 5000, y: -5000, width: nil, height: nil)!
        XCTAssertEqual(clamped.maxX, 1000); XCTAssertEqual(clamped.minY, 0)
        // Larger-than-screen sizes shrink to the display.
        XCTAssertEqual(WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "topLeft",
            x: 0, y: 0, width: 5000, height: 5000)?.size, visible.size)
    }

    func testCustomFrameRejectsBadInput() {
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100), current = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertNil(WindowGeometry.customFrame(current: current, visible: visible, unit: "furlongs", anchor: "center", x: 0, y: 0, width: nil, height: nil))
        XCTAssertNil(WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "middle", x: 0, y: 0, width: nil, height: nil))
        XCTAssertNil(WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "center", x: .nan, y: 0, width: nil, height: nil))
        XCTAssertNil(WindowGeometry.customFrame(current: current, visible: visible, unit: "pixels", anchor: "center", x: 0, y: 0, width: 0, height: 10))
    }

    func testEveryAnchorLandsInsideTheDisplay() {
        let visible = CGRect(x: 50, y: 40, width: 1000, height: 700)
        for anchor in ActionParameterValidation.anchors {
            let f = WindowGeometry.customFrame(current: CGRect(x: 0, y: 0, width: 300, height: 200), visible: visible,
                unit: "percent", anchor: anchor, x: 5, y: 5, width: 30, height: 30)!
            XCTAssertTrue(visible.contains(f), anchor)
        }
    }

    func testDragMathMoveAndResizeFollowThePointer() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(WindowDragMath.moved(start: start, pointerStart: CGPoint(x: 10, y: 10), pointer: CGPoint(x: 40, y: -5)),
                       CGRect(x: 130, y: 85, width: 400, height: 300))
        // Grab the bottom-right: size grows, origin stays.
        XCTAssertEqual(WindowDragMath.resized(start: start, pointerStart: CGPoint(x: 480, y: 380), pointer: CGPoint(x: 530, y: 400)),
                       CGRect(x: 100, y: 100, width: 450, height: 320))
        // Grab the top-left: the far (bottom-right) edge stays put.
        let r = WindowDragMath.resized(start: start, pointerStart: CGPoint(x: 110, y: 110), pointer: CGPoint(x: 60, y: 90))
        XCTAssertEqual(r.maxX, start.maxX); XCTAssertEqual(r.maxY, start.maxY)
        XCTAssertEqual(r.width, 450)
        // Never collapses below the minimum.
        let tiny = WindowDragMath.resized(start: start, pointerStart: CGPoint(x: 480, y: 380), pointer: CGPoint(x: -900, y: -900))
        XCTAssertEqual(tiny.size, WindowDragMath.minimumSize)
    }

    func testDragStartStopToggleOutcomes() {
        XCTAssertEqual(WindowDragMath.outcome(active: nil, requested: .moving, verb: "toggle"), .start(.moving))
        XCTAssertEqual(WindowDragMath.outcome(active: .moving, requested: .moving, verb: "toggle"), .stop)
        XCTAssertEqual(WindowDragMath.outcome(active: .moving, requested: .resizing, verb: "toggle"), .start(.resizing))
        XCTAssertEqual(WindowDragMath.outcome(active: nil, requested: .moving, verb: "stop"), .none)
        XCTAssertEqual(WindowDragMath.outcome(active: .resizing, requested: .moving, verb: "stop"), .none)
        XCTAssertEqual(WindowDragMath.outcome(active: .resizing, requested: .resizing, verb: "stop"), .stop)
        XCTAssertEqual(WindowDragMath.outcome(active: .moving, requested: .moving, verb: "start"), .start(.moving))
        XCTAssertNil(WindowDragMath.verb(for: .maximizeWindow))
        XCTAssertFalse(WindowDragController.shared.isActive)
    }

    func testFocusedWindowRequirement() {
        XCTAssertTrue(ActionType.zoomWindow.needsFocusedWindow)
        XCTAssertTrue(ActionType.snapWindowTopHalf.needsFocusedWindow)
        XCTAssertFalse(ActionType.startMovingWindow.needsFocusedWindow)
        XCTAssertFalse(ActionType.saveWindowLayout.needsFocusedWindow)
        XCTAssertFalse(ActionType.switchSpaceLeft.needsFocusedWindow) // not a window-management action
    }

    // MARK: Spaces and Mission Control shortcuts

    private func table(_ entries: [Int: (code: Int, flags: UInt64, enabled: Bool)]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: entries.map { id, e in
            (String(id), ["enabled": e.enabled, "value": ["type": "standard", "parameters": [65535, e.code, NSNumber(value: e.flags)]]] as [String: Any])
        })
    }

    func testSymbolicHotKeysReadConfiguredAndDefaultValues() {
        let t = table([118: (18, 262144, false), 79: (123, 8650752, true)])
        let desktop1 = SymbolicHotKeys.hotKey(id: 118, in: t)!
        XCTAssertFalse(desktop1.isEnabled); XCTAssertTrue(desktop1.isConfigured)
        XCTAssertEqual(desktop1.keyCode, 18); XCTAssertEqual(desktop1.flags.rawValue, 262144)
        // Not in the file: macOS defaults. Left/right Space are on, Desktop N is off.
        XCTAssertTrue(SymbolicHotKeys.hotKey(id: SymbolicHotKeys.spaceRight, in: t)!.isEnabled)
        XCTAssertFalse(SymbolicHotKeys.hotKey(id: SymbolicHotKeys.desktop(3), in: t)!.isEnabled)
        XCTAssertEqual(SymbolicHotKeys.hotKey(id: SymbolicHotKeys.desktop(3), in: nil)!.keyCode, 20)
        XCTAssertEqual(SymbolicHotKeys.desktop(1), 118); XCTAssertEqual(SymbolicHotKeys.desktop(9), 126)
        XCTAssertNil(SymbolicHotKeys.hotKey(id: 9999, in: t))
    }

    func testDisabledSpaceShortcutFailsWithOneTimeHintAndPostsNothing() {
        let defaults = UserDefaults(suiteName: unique("aomtest"))!
        var posted = 0
        let t = table([118: (18, 262144, false)])
        let first = expectation(description: "first"), second = expectation(description: "second")
        var firstResult: Bool?, secondResult: Bool?
        ExtendedActions.postHotKey(118, table: t, defaults: defaults, post: { _, _ in posted += 1; return true }) { firstResult = $0; first.fulfill() }
        XCTAssertTrue(defaults.bool(forKey: SymbolicHotKeys.hintShownKey))
        ExtendedActions.postHotKey(118, table: t, defaults: defaults, post: { _, _ in posted += 1; return true }) { secondResult = $0; second.fulfill() }
        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(firstResult, false); XCTAssertEqual(secondResult, false); XCTAssertEqual(posted, 0)
    }

    func testEnabledSpaceShortcutPostsTheUsersOwnKey() {
        var posted: [(UInt16, UInt64)] = []
        let t = table([79: (123, 8650752, true)])
        let done = expectation(description: "done"); var ok = false
        ExtendedActions.postHotKey(SymbolicHotKeys.spaceLeft, table: t, defaults: UserDefaults(suiteName: unique("aomtest"))!,
            post: { posted.append(($0, $1.rawValue)); return true }) { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(ok); XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].0, 123); XCTAssertEqual(posted[0].1, 8650752)
    }

    func testRealMachineHotKeyTableParses() {
        // Read-only: whatever this Mac has configured must parse without trapping.
        let live = SymbolicHotKeys.load()
        for id in [32, 33, 36, 79, 81] + (118...126) { XCTAssertNotNil(SymbolicHotKeys.hotKey(id: id, in: live)) }
    }

    // MARK: - Group 2: mouse and keyboard

    func testFunctionKeysCoverF1ToF20Only() {
        XCTAssertEqual(KeyCodes.functionKey(1), 122); XCTAssertEqual(KeyCodes.functionKey(12), 111)
        XCTAssertEqual(KeyCodes.functionKey(13), 105); XCTAssertEqual(KeyCodes.functionKey(20), 90)
        XCTAssertNil(KeyCodes.functionKey(21)); XCTAssertNil(KeyCodes.functionKey(0))
        XCTAssertEqual(Set((1...20).compactMap(KeyCodes.functionKey)).count, 20)
        XCTAssertNotNil(ActionParameterValidation.problem(for: with(.pressFunctionKey) { $0.functionKeyNumber = 21 }))
    }

    func testNavigationAndArrowKeyCodes() {
        XCTAssertEqual(KeyCodes.pageUp, 116); XCTAssertEqual(KeyCodes.pageDown, 121)
        XCTAssertEqual(KeyCodes.home, 115); XCTAssertEqual(KeyCodes.end, 119)
        XCTAssertEqual(KeyCodes.arrows, ["left": 123, "right": 124, "down": 125, "up": 126])
        XCTAssertNotNil(ActionParameterValidation.problem(for: with(.pressArrowKey) { $0.keyRepeatCount = 101 }))
        XCTAssertNotNil(ActionParameterValidation.problem(for: with(.pressArrowKey) { $0.arrowDirection = "sideways" }))
        XCTAssertNil(ActionParameterValidation.problem(for: with(.pressArrowKey) { $0.keyRepeatCount = 5; $0.arrowDirection = "up" }))
    }

    func testModifierFlagsAccumulateAndRelease() {
        XCTAssertEqual(ModifierKeys.flags(held: []), [])
        XCTAssertEqual(ModifierKeys.flags(held: ["command", "shift"]), [.maskCommand, .maskShift])
        XCTAssertEqual(ModifierKeys.flags(held: ["command", "rightCommand"]), [.maskCommand])
        XCTAssertEqual(ModifierKeys.table["fn"]?.keyCode, 63)
        XCTAssertNotEqual(ModifierKeys.table["command"]?.keyCode, ModifierKeys.table["rightCommand"]?.keyCode)
    }

    func testClickPresetsAndCustomButtons() {
        XCTAssertEqual(ClickPlan.presetClick(.ctrlLeftClick)?.flags, .maskControl)
        XCTAssertEqual(ClickPlan.presetClick(.optionLeftClick)?.flags, .maskAlternate)
        XCTAssertEqual(ClickPlan.presetClick(.shiftLeftClick)?.flags, .maskShift)
        XCTAssertEqual(ClickPlan.presetClick(.cmdDoubleClick)?.count, 2)
        XCTAssertNil(ClickPlan.presetClick(.leftClick))
        XCTAssertEqual(ClickPlan.spec(button: 0)?.downType, .leftMouseDown)
        XCTAssertEqual(ClickPlan.spec(button: 1)?.downType, .rightMouseDown)
        XCTAssertEqual(ClickPlan.spec(button: 4)?.downType, .otherMouseDown)
        XCTAssertEqual(ClickPlan.spec(button: 4)?.buttonNumber, 4)
        XCTAssertNil(ClickPlan.spec(button: 32)); XCTAssertNil(ClickPlan.spec(button: -1))
        let flags = ClickPlan.flags(from: NSEvent.ModifierFlags([.command, .option]).rawValue)
        XCTAssertEqual(flags, [.maskCommand, .maskAlternate])
    }

    func testScrollPlanDistributesAmountExactly() {
        let burst = ScrollPlan.steps(direction: "down", amount: 7, durationMs: 0)!
        XCTAssertEqual(burst, [ScrollPlan.Step(vertical: -7, horizontal: 0, delayMs: 0)])
        let smooth = ScrollPlan.steps(direction: "right", amount: 100, durationMs: 160)!
        XCTAssertEqual(smooth.count, 10)
        XCTAssertEqual(smooth.reduce(0) { $0 + Int($1.horizontal) }, 100)
        XCTAssertTrue(smooth.allSatisfy { $0.vertical == 0 })
        let odd = ScrollPlan.steps(direction: "up", amount: 3, durationMs: 1600)!
        XCTAssertEqual(odd.reduce(0) { $0 + Int($1.vertical) }, 3)
        XCTAssertEqual(ScrollPlan.steps(direction: "left", amount: 5, durationMs: 100)!.reduce(0) { $0 + Int($1.horizontal) }, -5)
        XCTAssertNil(ScrollPlan.steps(direction: "diagonal", amount: 5, durationMs: 0))
        XCTAssertNil(ScrollPlan.steps(direction: "up", amount: 0, durationMs: 0))
        XCTAssertLessThanOrEqual(ScrollPlan.steps(direction: "up", amount: 10_000, durationMs: 10_000)!.count, ScrollPlan.maxSteps)
    }

    func testPasteboardSnapshotRoundTripsEveryType() {
        let board = NSPasteboard(name: NSPasteboard.Name(unique("aomtest")))
        defer { board.releaseGlobally() }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.blob"))
        board.writeObjects([item])
        let snapshot = PasteboardSnapshot.capture(board)
        board.clearContents(); board.setString("other", forType: .string)
        XCTAssertTrue(snapshot.restore(to: board))
        XCTAssertEqual(board.string(forType: .string), "hello")
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType("com.example.blob")), Data([1, 2, 3]))
        // Restoring an empty clipboard leaves it empty.
        board.clearContents()
        let empty = PasteboardSnapshot.capture(board)
        board.setString("x", forType: .string); empty.restore(to: board)
        XCTAssertNil(board.string(forType: .string))
    }

    func testPasteStringPastesThroughClipboardThenRestoresPreviousContents() {
        let board = NSPasteboard(name: NSPasteboard.Name(unique("aomtest")))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("precious", forType: .string)
        var seenDuringPaste: String?
        var seenTransientMarker = false
        let done = expectation(description: "paste"); var ok = false
        ExtendedActions.pasteString("pasted text", pasteboard: board, press: {
            seenDuringPaste = board.string(forType: .string)
            seenTransientMarker = board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true
            return true
        }, restoreDelay: 0.05) { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(ok); XCTAssertEqual(seenDuringPaste, "pasted text"); XCTAssertTrue(seenTransientMarker)
        XCTAssertEqual(board.string(forType: .string), "precious")
    }

    func testPasteStringDoesNotClobberAClipboardChangedMeanwhile() {
        let board = NSPasteboard(name: NSPasteboard.Name(unique("aomtest")))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("old", forType: .string)
        let done = expectation(description: "paste")
        ExtendedActions.pasteString("temp", pasteboard: board, press: {
            board.clearContents(); board.setString("user copied this", forType: .string); return true
        }, restoreDelay: 0.05) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(board.string(forType: .string), "user copied this")
    }

    // MARK: - Group 3: system and utility

    func testScriptRunnerKindsIncludeJavaScriptForAutomation() {
        XCTAssertTrue(ScriptRunnerKinds.allowed.isSuperset(of: ["shell", "applescript", "javascript"]))
        XCTAssertEqual(ScriptRunnerKinds.command(for: "javascript")?.executable, "/usr/bin/osascript")
        XCTAssertEqual(ScriptRunnerKinds.command(for: "javascript")?.arguments, ["-l", "JavaScript"])
        XCTAssertEqual(ScriptRunnerKinds.command(for: "shell")?.executable, "/bin/zsh")
        XCTAssertEqual(ScriptRunnerKinds.command(for: "applescript")?.arguments, [])
        XCTAssertNil(ScriptRunnerKinds.command(for: "python"))
    }

    func testShellQuotingNeutralisesInjection() {
        XCTAssertEqual(ShellQuote.single("Morning Routine"), "'Morning Routine'")
        XCTAssertEqual(ShellQuote.single("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.single("$(rm -rf ~); `x`"), "'$(rm -rf ~); `x`'")
    }

    func testVolumeDeltaAndBrightnessPlanning() {
        XCTAssertEqual(AudioOutputService.volumeDelta(current: 0.25, targetPercent: 80)!, 55, accuracy: 0.001)
        XCTAssertEqual(AudioOutputService.volumeDelta(current: 0.9, targetPercent: 0)!, -90, accuracy: 0.001)
        XCTAssertNil(AudioOutputService.volumeDelta(current: 0.5, targetPercent: 101))
        XCTAssertNil(AudioOutputService.volumeDelta(current: 0.5, targetPercent: .nan))
        XCTAssertEqual(ExtendedActions.brightnessValue(percent: 0, hardware: true), 0)
        XCTAssertEqual(ExtendedActions.brightnessValue(percent: 0, hardware: false), 0.1, "software dim never goes fully black")
        XCTAssertEqual(ExtendedActions.brightnessValue(percent: 50, hardware: false), 0.5)
        XCTAssertEqual(ExtendedActions.brightnessValue(percent: 150, hardware: true), 1)
    }

    func testFileURLResolvesOnlyExistingPaths() {
        XCTAssertNotNil(ExtendedActions.fileURL("/System/Library"))
        XCTAssertNotNil(ExtendedActions.fileURL("~"))
        XCTAssertNil(ExtendedActions.fileURL("/definitely/not/here/\(UUID().uuidString)"))
        XCTAssertNil(ExtendedActions.fileURL("  ")); XCTAssertNil(ExtendedActions.fileURL(nil))
    }

    func testDestructiveActionsAreMarkedAndAskBeforeRunning() {
        XCTAssertEqual(Set(ActionType.allCases.filter(\.isDestructive)), [.emptyTrash, .logOut, .forceQuitApplication])
        ActionExecutor.onActionExecuted = nil
        var asked: [String] = []
        ActionConfirmation.presenter = { title, _, _, answer in asked.append(title); answer(false) }
        for type in [ActionType.emptyTrash, .logOut, .forceQuitApplication] {
            let done = expectation(description: type.rawValue); var result: Bool?
            ActionExecutor.executeActions([TriggerAction(actionType: type)]) { result = $0; done.fulfill() }
            wait(for: [done], timeout: 3)
            XCTAssertEqual(result, false, "declining the confirmation must stop \(type.rawValue)")
        }
        XCTAssertEqual(asked, ["Empty the Trash?", "Log out now?", "Force quit?"])
    }

    func testConfirmationDefaultsOnAndWordingIsPerAction() {
        XCTAssertNil(ActionParameters().requiresConfirmation, "nil means ask")
        for type in [ActionType.emptyTrash, .logOut, .forceQuitApplication] {
            let words = ActionConfirmation.wording(for: type)
            XCTAssertFalse(words.title.isEmpty); XCTAssertFalse(words.confirm.isEmpty)
        }
    }

    // MARK: - Every new action runs through the executor without touching the system

    func testEveryActionIsReportedToTheHookExactlyOnce() {
        let skipped: Set<ActionType> = [.actionGroup, .ifElse, .wait, .triggerNamedTrigger, .repeatLoop, .cycleActions, .toggleOnOff]
        var count = 0
        for type in ActionType.allCases where !skipped.contains(type) {
            var action = TriggerAction(actionType: type)
            action.parameters.variableName = unique(); action.parameters.variableValue = "1"
            action.parameters.triggerSelector = "no such trigger"; action.parameters.waitMs = 1
            action.parameters.filePath = "/tmp/nothing"; action.parameters.shortcutKeyCode = 0
            action.parameters.uiElementTitle = "Fixture element"
            action.parameters.imageTemplatePath = "/tmp/fixture-template.png"
            let (fired, ok) = run([action])
            XCTAssertTrue(ok, type.rawValue)
            XCTAssertEqual(fired.count, 1, "\(type.rawValue) reached the hook \(fired.count) times")
            count += 1
        }
        XCTAssertGreaterThan(count, 150)
    }

    func testHookedEnableDisableAndPauseDoNotPostRealRequests() {
        var requests = 0
        let observer = NotificationCenter.default.addObserver(forName: .aomSetTriggerEnabled, object: nil, queue: nil) { _ in requests += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let pausedBefore = TriggerSuppression.shared.pause.isGloballyPaused
        var enable = TriggerAction(actionType: .enableTrigger); enable.parameters.triggerSelector = "Anything"
        var disable = TriggerAction(actionType: .disableTrigger); disable.parameters.triggerSelector = UUID().uuidString
        var pause = TriggerAction(actionType: .disableTriggersForSeconds); pause.parameters.pauseSeconds = 30
        let result = run([enable, disable, pause, TriggerAction(actionType: .resumeTriggers), TriggerAction(actionType: .stopAllSequences)])
        XCTAssertTrue(result.ok); XCTAssertEqual(result.fired.count, 5)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(TriggerSuppression.shared.pause.isGloballyPaused, pausedBefore)
    }

    func testEnableDisableNeedsASelector() {
        let result = run([TriggerAction(actionType: .enableTrigger)])
        XCTAssertFalse(result.ok); XCTAssertTrue(result.fired.isEmpty)
    }

    // MARK: - Group 4: control flow

    func testRepeatLoopRunsNTimesAndExpandsInTheStepBudget() {
        var loop = TriggerAction(actionType: .repeatLoop)
        loop.parameters.loopCount = 4; loop.parameters.children = [marker("a"), marker("b")]
        let result = run([loop, marker("after")])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.fired, ["a", "b", "a", "b", "a", "b", "a", "b", "after"])
        // 100 × 100 inner steps exceeds the 1,000-step budget and is rejected up front.
        var big = TriggerAction(actionType: .repeatLoop); big.parameters.loopCount = 100
        big.parameters.children = (0..<20).map { _ in marker("x") }
        XCTAssertNotNil(ActionTree.problem([big]))
        big.parameters.loopCount = 0
        XCTAssertEqual(ActionTree.problem([big]), "Loop count must be 1–100.")
    }

    func testBreakLoopLeavesOnlyTheNearestLoopEvenFromInsideAGroup() {
        var group = TriggerAction(actionType: .actionGroup)
        group.parameters.children = [marker("g1"), TriggerAction(actionType: .breakLoop), marker("g2")]
        var loop = TriggerAction(actionType: .repeatLoop)
        loop.parameters.loopCount = 5; loop.parameters.children = [marker("l1"), group, marker("l2")]
        let result = run([marker("before"), loop, marker("after")])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.fired, ["before", "l1", "g1", "Break Loop", "after"])
    }

    func testBreakOutsideALoopEndsTheSequenceCleanly() {
        let result = run([marker("a"), TriggerAction(actionType: .breakLoop), marker("never")])
        XCTAssertTrue(result.ok); XCTAssertEqual(result.fired, ["a", "Break Loop"])
    }

    func testNestedLoopsOnlyBreakTheInnerOne() {
        var inner = TriggerAction(actionType: .repeatLoop)
        inner.parameters.loopCount = 3; inner.parameters.children = [marker("i"), TriggerAction(actionType: .breakLoop)]
        var outer = TriggerAction(actionType: .repeatLoop)
        outer.parameters.loopCount = 2; outer.parameters.children = [inner, marker("o")]
        let result = run([outer])
        XCTAssertEqual(result.fired.filter { $0 == "i" }.count, 2)
        XCTAssertEqual(result.fired.filter { $0 == "o" }.count, 2)
    }

    func testCycleAdvancesPerRunAndWraps() {
        var cycle = TriggerAction(actionType: .cycleActions)
        cycle.parameters.children = [marker("one"), marker("two"), marker("three")]
        var seen: [String] = []
        for _ in 0..<5 { seen += run([cycle]).fired }
        XCTAssertEqual(seen, ["one", "two", "three", "one", "two"])
        // A duplicate keeps its own position.
        let copy = ActionTree.duplicate(cycle)
        XCTAssertEqual(run([copy]).fired, ["one"])
    }

    func testCycleResetsAfterIdleTime() {
        let id = UUID(); var clock: TimeInterval = 100
        ActionFlowState.now = { clock }
        XCTAssertEqual(ActionFlowState.nextCycleIndex(id: id, count: 3, resetAfter: 5), 0)
        clock += 2; XCTAssertEqual(ActionFlowState.nextCycleIndex(id: id, count: 3, resetAfter: 5), 1)
        clock += 10; XCTAssertEqual(ActionFlowState.nextCycleIndex(id: id, count: 3, resetAfter: 5), 0, "idle past the reset time")
        clock += 1000; XCTAssertEqual(ActionFlowState.nextCycleIndex(id: id, count: 3, resetAfter: nil), 1, "no reset configured")
        XCTAssertEqual(ActionFlowState.nextCycleIndex(id: UUID(), count: 0, resetAfter: nil), 0)
        // Shrinking the list never indexes past the end.
        XCTAssertEqual(ActionFlowState.nextCycleIndex(id: id, count: 2, resetAfter: nil), 0)
    }

    func testToggleOnOffAlternatesTwoActionLists() {
        var toggle = TriggerAction(actionType: .toggleOnOff)
        toggle.parameters.children = [marker("ON")]; toggle.parameters.elseChildren = [marker("OFF")]
        var seen: [String] = []
        for _ in 0..<4 { seen += run([toggle]).fired }
        XCTAssertEqual(seen, ["ON", "OFF", "ON", "OFF"])
        var onlyOn = TriggerAction(actionType: .toggleOnOff); onlyOn.parameters.children = [marker("ON")]
        XCTAssertEqual(run([onlyOn]).fired, ["ON"]); XCTAssertEqual(run([onlyOn]).fired, [])
    }

    func testContainerChildRules() {
        for type in [ActionType.actionGroup, .ifElse, .repeatLoop, .cycleActions, .toggleOnOff] { XCTAssertTrue(type.canContainChildren) }
        XCTAssertFalse(ActionType.showHUD.canContainChildren)
        var wrong = TriggerAction(actionType: .showHUD); wrong.parameters.children = [marker("x")]
        XCTAssertNotNil(ActionTree.problem([wrong]))
        var elseOnLoop = TriggerAction(actionType: .repeatLoop); elseOnLoop.parameters.elseChildren = [marker("x")]
        XCTAssertNotNil(ActionTree.problem([elseOnLoop]))
        var toggle = TriggerAction(actionType: .toggleOnOff); toggle.parameters.elseChildren = [marker("x")]
        XCTAssertNil(ActionTree.problem([toggle]))
    }

    func testIncreaseAndDecreaseVariable() {
        let name = unique()
        func inc() -> TriggerAction { var a = TriggerAction(actionType: .increaseVariable); a.parameters.variableName = name; return a }
        var dec = TriggerAction(actionType: .decreaseVariable); dec.parameters.variableName = name; dec.parameters.variableStep = 0.5
        XCTAssertTrue(run([inc(), inc(), inc()]).ok)
        XCTAssertEqual(WorkflowVariables.value(name), "3")
        XCTAssertTrue(run([dec]).ok)
        XCTAssertEqual(WorkflowVariables.value(name), "2.5")
        XCTAssertEqual(ControlFlowActions.format(4), "4"); XCTAssertEqual(ControlFlowActions.format(-1.25), "-1.25")
        WorkflowVariables.set(name, value: "not a number")
        XCTAssertTrue(run([inc()]).ok); XCTAssertEqual(WorkflowVariables.value(name), "1", "non-numeric counts as 0")
        var bad = TriggerAction(actionType: .increaseVariable); bad.parameters.variableName = "has space"
        XCTAssertFalse(run([bad]).ok)
        var nameless = TriggerAction(actionType: .increaseVariable)
        nameless.parameters.variableName = ""
        XCTAssertFalse(run([nameless]).ok)
    }

    func testAskForInputStoresAnswerAndCancelStopsTheSequence() {
        let name = unique()
        var ask = TriggerAction(actionType: .askForInput)
        ask.parameters.variableName = name; ask.parameters.inputPrompt = "Name?"; ask.parameters.variableValue = "default"
        var prompts: [(String, String)] = []
        AskForInput.provider = { prompt, initial, answer in prompts.append((prompt, initial)); answer("Ada") }
        let ok = run([ask, marker("after")])
        XCTAssertTrue(ok.ok); XCTAssertEqual(WorkflowVariables.value(name), "Ada")
        XCTAssertEqual(prompts.first?.0, "Name?"); XCTAssertEqual(prompts.first?.1, "default")
        XCTAssertEqual(ok.fired, ["Ask For Input", "after"])

        AskForInput.provider = { _, _, answer in answer(nil) }
        WorkflowVariables.set(name, value: "kept")
        let cancelled = run([ask, marker("never")])
        XCTAssertFalse(cancelled.ok); XCTAssertEqual(cancelled.fired, [])
        XCTAssertEqual(WorkflowVariables.value(name), "kept")
    }

    func testAskForInputNeverShowsAlertWhenHookedWithoutProvider() {
        var ask = TriggerAction(actionType: .askForInput); ask.parameters.variableName = unique()
        let result = run([ask])
        XCTAssertTrue(result.ok); XCTAssertEqual(result.fired, ["Ask For Input"])
    }

    func testDebounceOnlyLetsTheLatestRunContinue() {
        var debounce = TriggerAction(actionType: .debounce); debounce.parameters.waitMs = 80
        var fired: [String] = []
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.label ?? "debounce") }
        let doneA = expectation(description: "a"), doneB = expectation(description: "b")
        var resultA: Bool?, resultB: Bool?
        let perform: ActionSequenceRunner.Perform = { action, done in ActionExecutor.onActionExecuted?(action); done(true) }
        let a = ActionSequenceRunner(perform: perform), b = ActionSequenceRunner(perform: perform)
        a.run([debounce, marker("first")]) { resultA = $0; doneA.fulfill() }
        let second = marker("second")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            b.run([debounce, second]) { resultB = $0; doneB.fulfill() }
        }
        wait(for: [doneA, doneB], timeout: 3)
        XCTAssertEqual(resultA, false); XCTAssertEqual(resultB, true)
        XCTAssertEqual(fired.filter { $0 == "first" || $0 == "second" }, ["second"])
    }

    func testStopAllSequencesCancelsRunningWork() {
        var wait = TriggerAction(actionType: .wait); wait.parameters.waitMs = 5000
        let started = expectation(description: "ended")
        var finished: Bool?
        ActionExecutor.onActionExecuted = { _ in }
        ActionExecutor.executeActions([wait, marker("never")]) { finished = $0; started.fulfill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ActionExecutor.cancelAllSequences() }
        self.wait(for: [started], timeout: 3)
        XCTAssertEqual(finished, false)
    }

    func testWaitForConditionsWithFakeEnvironment() {
        var clock: TimeInterval = 0
        var running: Set<String> = []
        var front: String?
        var files = Set<String>()
        var clipboard = 0
        let probe = WaitProbe(runningBundleIDs: { running }, frontmostBundleID: { front },
                              fileExists: { files.contains($0) }, clipboardChangeCount: { clipboard }, now: { clock })
        XCTAssertFalse(WaitFor.isSatisfied(condition: "appRunning", target: "com.x", baselineClipboard: 0, probe: probe))
        running = ["com.x"]
        XCTAssertTrue(WaitFor.isSatisfied(condition: "appRunning", target: "com.x", baselineClipboard: 0, probe: probe))
        front = "com.y"
        XCTAssertFalse(WaitFor.isSatisfied(condition: "appFrontmost", target: "com.x", baselineClipboard: 0, probe: probe))
        front = "com.x"
        XCTAssertTrue(WaitFor.isSatisfied(condition: "appFrontmost", target: "com.x", baselineClipboard: 0, probe: probe))
        files = ["/tmp/a"]
        XCTAssertTrue(WaitFor.isSatisfied(condition: "fileExists", target: "/tmp/a", baselineClipboard: 0, probe: probe))
        XCTAssertFalse(WaitFor.isSatisfied(condition: "fileExists", target: "", baselineClipboard: 0, probe: probe))
        clipboard = 3
        XCTAssertTrue(WaitFor.isSatisfied(condition: "clipboardChange", target: "", baselineClipboard: 2, probe: probe))
        XCTAssertFalse(WaitFor.isSatisfied(condition: "clipboardChange", target: "", baselineClipboard: 3, probe: probe))
        XCTAssertFalse(WaitFor.isSatisfied(condition: "mystery", target: "x", baselineClipboard: 0, probe: probe))

        // The file appears on the third poll.
        var polls = 0
        files = []
        let appears = WaitProbe(runningBundleIDs: { [] }, frontmostBundleID: { nil },
            fileExists: { _ in polls += 1; return polls >= 3 }, clipboardChangeCount: { 0 }, now: { clock })
        var p = ActionParameters(); p.waitCondition = "fileExists"; p.waitTarget = "/tmp/x"; p.waitTimeoutMs = 10_000
        let found = expectation(description: "found"); var foundResult: Bool?
        WaitFor.run(p, probe: appears, interval: 0.01) { foundResult = $0; found.fulfill() }
        wait(for: [found], timeout: 3)
        XCTAssertEqual(foundResult, true); XCTAssertEqual(polls, 3)
    }

    func testWaitForTimeoutFailsUnlessContinueOnTimeout() {
        var clock: TimeInterval = 0
        let never = WaitProbe(runningBundleIDs: { [] }, frontmostBundleID: { nil }, fileExists: { _ in false },
                              clipboardChangeCount: { 0 }, now: { clock += 1; return clock })
        var p = ActionParameters(); p.waitCondition = "appRunning"; p.waitTarget = "com.never"; p.waitTimeoutMs = 3000
        let failed = expectation(description: "timeout"); var failResult: Bool?
        WaitFor.run(p, probe: never, interval: 0.001) { failResult = $0; failed.fulfill() }
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(failResult, false)
        p.waitContinueOnTimeout = true; clock = 0
        let passed = expectation(description: "continue"); var passResult: Bool?
        WaitFor.run(p, probe: never, interval: 0.001) { passResult = $0; passed.fulfill() }
        wait(for: [passed], timeout: 3)
        XCTAssertEqual(passResult, true)
        // Cancellation ends the poll without waiting for the timeout.
        let cancelled = expectation(description: "cancelled"); var cancelResult: Bool?
        WaitFor.run(p, probe: never, interval: 0.001, isCancelled: { true }) { cancelResult = $0; cancelled.fulfill() }
        wait(for: [cancelled], timeout: 3)
        XCTAssertEqual(cancelResult, false)
        // Missing targets are rejected immediately.
        var empty = ActionParameters(); empty.waitCondition = "fileExists"
        let rejected = expectation(description: "rejected"); var rejectResult: Bool?
        WaitFor.run(empty, probe: never) { rejectResult = $0; rejected.fulfill() }
        wait(for: [rejected], timeout: 1)
        XCTAssertEqual(rejectResult, false)
    }

    // MARK: Trigger selection

    func testTriggerSelectorMatchesUUIDOrNameCaseInsensitively() {
        var named = Trigger(name: "Quick Look", input: .namedTrigger("q"))
        named.name = "Quick Look"
        let other = Trigger(name: "", input: .namedTrigger("other"))
        XCTAssertTrue(TriggerSelector.matches("quick look", trigger: named))
        XCTAssertTrue(TriggerSelector.matches("  Quick Look ", trigger: named))
        XCTAssertFalse(TriggerSelector.matches("quick", trigger: named))
        XCTAssertTrue(TriggerSelector.matches(named.id.uuidString, trigger: named))
        XCTAssertTrue(TriggerSelector.matches(named.id.uuidString.lowercased(), trigger: named))
        XCTAssertFalse(TriggerSelector.matches(named.id.uuidString, trigger: other))
        XCTAssertFalse(TriggerSelector.matches("", trigger: named))
    }

    // MARK: IF operators

    func testExtendedComparisonOperators() {
        let c = WorkflowBranchCondition.compare
        XCTAssertTrue(c("Hello World", "hello", "beginsWith")); XCTAssertFalse(c("Hello World", "world", "beginsWith"))
        XCTAssertTrue(c("Hello World", "WORLD", "endsWith")); XCTAssertFalse(c("Hello", "", "endsWith"))
        XCTAssertTrue(c("Safari", "safari", "is")); XCTAssertFalse(c("Safari", "Chrome", "is"))
        XCTAssertTrue(c("3", "3.0", "is"), "numbers compare as numbers"); XCTAssertTrue(c("3", "4", "isNot"))
        XCTAssertTrue(c("report-2026.pdf", "report-*.pdf", "like")); XCTAssertTrue(c("cat", "c?t", "like"))
        XCTAssertFalse(c("cats", "c?t", "like"), "like matches the whole text"); XCTAssertFalse(c("a.b", "a?c", "like"))
        XCTAssertTrue(c("a.b", "a.b", "like"), "regex metacharacters in a like pattern are literal")
        XCTAssertTrue(c("abc123", "[a-z]+\\d+", "regex")); XCTAssertFalse(c("abc", "^\\d+$", "regex"))
        XCTAssertTrue(c("hello", "xyz", "notContains")); XCTAssertFalse(c("hello", "ell", "notContains"))
        XCTAssertTrue(c("5", "5", "greaterOrEqual")); XCTAssertTrue(c("5", "5", "lessOrEqual")); XCTAssertFalse(c("x", "5", "greaterOrEqual"))
        // The original operators keep their exact behaviour.
        XCTAssertFalse(c("Safari", "safari", "equals")); XCTAssertTrue(c("a", "b", "notEquals"))
        XCTAssertTrue(c("Hello", "ELL", "contains")); XCTAssertTrue(c("9", "10", "less"))
        XCTAssertFalse(c("x", "y", "bogus"))
        XCTAssertEqual(Set(WorkflowBranchCondition.operators.map(\.id)).count, WorkflowBranchCondition.operators.count)
    }

    func testClipboardAndAppNameConditionKinds() {
        var p = ActionParameters()
        p.conditionKind = "clipboard"; p.conditionOperator = "contains"; p.conditionValue = "invoice"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "", title: "", mouseX: 0, mouseY: 0, variable: { _ in nil },
                                                      clipboard: { "Invoice #44" }))
        XCTAssertFalse(WorkflowBranchCondition.matches(p, app: "", title: "", mouseX: 0, mouseY: 0, variable: { _ in nil }))
        p.conditionKind = "appName"; p.conditionOperator = "beginsWith"; p.conditionValue = "Saf"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "com.apple.Safari", title: "", mouseX: 0, mouseY: 0,
                                                      variable: { _ in nil }, appName: "Safari"))
        p.conditionKind = "app"; p.conditionOperator = "endsWith"; p.conditionValue = ".Safari"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "com.apple.Safari", title: "", mouseX: 0, mouseY: 0, variable: { _ in nil }))
    }

    func testIfElseUsesNewOperatorEndToEnd() {
        let name = unique()
        WorkflowVariables.set(name, value: "Deep Work Session")
        var branch = TriggerAction(actionType: .ifElse)
        branch.parameters.conditionKind = "variable"; branch.parameters.variableName = name
        branch.parameters.conditionOperator = "like"; branch.parameters.conditionValue = "deep*session"
        branch.parameters.children = [marker("then")]; branch.parameters.elseChildren = [marker("else")]
        XCTAssertEqual(run([branch]).fired, ["then"])
        branch.parameters.conditionOperator = "beginsWith"; branch.parameters.conditionValue = "work"
        XCTAssertEqual(run([branch]).fired, ["else"])
    }

    // MARK: Validation

    private func with(_ type: ActionType, _ edit: (inout ActionParameters) -> Void) -> TriggerAction {
        var action = TriggerAction(actionType: type); edit(&action.parameters); return action
    }

    func testParameterValidation() {
        let bad: [TriggerAction] = [
            with(.moveResizeWindow) { $0.moveResizeUnit = "inches" },
            with(.moveResizeWindow) { $0.moveResizeAnchor = "middle" },
            with(.moveResizeWindow) { $0.moveResizeWidth = 150 },
            with(.moveResizeWindow) { $0.moveResizeWidth = -5 },
            with(.moveResizeWindow) { $0.moveResizeX = .infinity },
            with(.zoomWindow) { $0.windowTarget = "everywhere" },
            with(.switchToDesktop) { $0.desktopNumber = 10 },
            with(.customClick) { $0.clickButton = 40 },
            with(.customClick) { $0.clickCount = 4 },
            with(.scrollCustom) { $0.scrollDirection = "sideways" },
            with(.scrollCustom) { $0.scrollDurationMs = 20_000 },
            with(.moveMouseRelative) { $0.mouseDeltaX = .nan },
            with(.modifierKeyDown) { $0.modifierKey = "hyper" },
            with(.setVolume) { $0.levelPercent = 120 },
            with(.setBrightness) { $0.levelPercent = -1 },
            with(.speakText) { $0.speechRate = 2 },
            with(.waitFor) { $0.waitCondition = "later" },
            with(.waitFor) { $0.waitTimeoutMs = 9_999_999 },
            with(.disableTriggersForSeconds) { $0.pauseSeconds = 0 },
            with(.cycleActions) { $0.cycleResetSeconds = -1 },
            with(.startMovingWindow) { $0.windowDragTimeoutSeconds = 0 },
            with(.runJavaScript) { $0.scriptTimeoutSeconds = 500 },
        ]
        for action in bad { XCTAssertNotNil(ActionTree.problem([action]), "\(action.actionType.rawValue) should be rejected: \(action.parameters)") }
        let good: [TriggerAction] = [
            with(.moveResizeWindow) { $0.moveResizeUnit = "percent"; $0.moveResizeAnchor = "center"; $0.moveResizeWidth = 60; $0.moveResizeHeight = 60 },
            with(.switchToDesktop) { $0.desktopNumber = 9 },
            with(.customClick) { $0.clickButton = 3; $0.clickCount = 2 },
            with(.scrollCustom) { $0.scrollDirection = "up"; $0.scrollAmount = 300; $0.scrollUnit = "pixels"; $0.scrollDurationMs = 400 },
            with(.setVolume) { $0.levelPercent = 35 },
            with(.waitFor) { $0.waitCondition = "fileExists"; $0.waitTarget = "/tmp/x"; $0.waitTimeoutMs = 5000 },
            with(.disableTriggersForSeconds) { $0.pauseSeconds = 10 },
        ]
        for action in good { XCTAssertNil(ActionTree.problem([action]), "\(action.actionType.rawValue): \(ActionTree.problem([action]) ?? "")") }
    }

    func testDescriptionsMentionSystemShortcutRequirementForSpaces() {
        for type in [ActionType.switchSpaceLeft, .switchSpaceRight, .switchToDesktop, .appExpose] {
            XCTAssertTrue(type.description.contains("system shortcut"), type.rawValue)
        }
    }
}

/// Action picker, favourites, copy/paste and drag-reorder logic (phase 5).
final class BTTActionPickerTests: XCTestCase {
    private func store() -> ActionPickerStore {
        ActionPickerStore(defaults: UserDefaults(suiteName: "aomtest-picker-" + UUID().uuidString)!)
    }
    private func marker(_ name: String) -> TriggerAction {
        var a = TriggerAction(actionType: .showHUD); a.parameters.label = name; return a
    }

    func testFavoritesToggleAndPersist() {
        let s = store()
        XCTAssertTrue(s.favorites.isEmpty)
        XCTAssertTrue(s.toggleFavorite(.speakText)); XCTAssertTrue(s.toggleFavorite(.setVolume))
        XCTAssertEqual(s.favorites, [.speakText, .setVolume]); XCTAssertTrue(s.isFavorite(.speakText))
        XCTAssertFalse(s.toggleFavorite(.speakText))
        XCTAssertEqual(s.favorites, [.setVolume])
        // A second store over the same defaults sees the same data.
        XCTAssertEqual(ActionPickerStore(defaults: s.defaults).favorites, [.setVolume])
    }

    func testRecentsAreMostRecentFirstDeduplicatedAndCapped() {
        let s = store()
        let types: [ActionType] = [.maximizeWindow, .centerWindow, .speakText, .setVolume, .customClick, .pressArrowKey,
                                   .repeatLoop, .debounce, .waitFor, .askForInput]
        types.forEach(s.recordUse)
        XCTAssertEqual(s.recents.count, ActionPickerStore.maxRecents)
        XCTAssertEqual(s.recents.first, .askForInput)
        s.recordUse(.waitFor)
        XCTAssertEqual(s.recents.first, .waitFor)
        XCTAssertEqual(s.recents.filter { $0 == .waitFor }.count, 1)
        s.clearRecents(); XCTAssertTrue(s.recents.isEmpty)
    }

    func testUnknownStoredActionsAreDroppedNotFatal() {
        let s = store()
        s.defaults.set(["Maximize Window", "Action From The Future", "Maximize Window"], forKey: ActionPickerStore.favoritesKey)
        XCTAssertEqual(s.favorites, [.maximizeWindow])
    }

    func testSearchRanksNameAboveDescriptionAndRequiresEveryWord() {
        let results = ActionSearch.results(for: "scroll")
        XCTAssertEqual(results.first?.category, .mouseActions)
        XCTAssertTrue(results.prefix(6).contains(.scrollCustom))
        XCTAssertTrue(ActionSearch.results(for: "volume").prefix(6).contains(.setVolume))
        // Description-only hits are found too: "ChatGPT" is nowhere, "microphone" is in a description and name.
        XCTAssertTrue(ActionSearch.results(for: "microphone").contains(.toggleMuteMicrophone))
        XCTAssertTrue(ActionSearch.results(for: "speak").contains(.speakText))
        XCTAssertTrue(ActionSearch.results(for: "top half").contains(.snapWindowTopHalf))
        XCTAssertFalse(ActionSearch.results(for: "top half").contains(.snapWindowBottomHalf))
        XCTAssertTrue(ActionSearch.results(for: "zzzzqqq").isEmpty)
        XCTAssertEqual(ActionSearch.results(for: "   ").count, ActionType.allCases.count)
        // Name beats description: the action named "Mission Control" outranks anything that merely mentions it.
        XCTAssertEqual(ActionSearch.results(for: "mission control").first, .missionControl)
    }

    func testEveryDefaultParameterSetIsValid() {
        for type in ActionType.allCases {
            let action = TriggerAction(actionType: type, parameters: type.defaultParameters)
            let requiresSelection: Set<ActionType> = [.pressAccessibilityElement, .setAccessibilityValue, .matchScreenImage]
            if requiresSelection.contains(type) {
                XCTAssertNotNil(ActionParameterValidation.problem(for: action), "\(type.rawValue) must require the user to select a target")
            } else {
                XCTAssertNil(ActionParameterValidation.problem(for: action), "\(type.rawValue): \(ActionParameterValidation.problem(for: action) ?? "")")
            }
        }
        XCTAssertEqual(ActionType.setVolume.defaultParameters.levelPercent, 50)
        XCTAssertEqual(ActionType.moveResizeWindow.defaultParameters.moveResizeUnit, "percent")
        XCTAssertEqual(ActionType.ifElse.defaultParameters.variableName, "state")
    }

    func testEveryActionHasAFormOrAnExistingEditor() {
        // Every action added in 1.1.4 that takes options must have a parameter form.
        let needsForm: [ActionType] = [.moveResizeWindow, .zoomWindow, .closeWindow, .toggleFullscreenWindow, .startMovingWindow,
            .switchToDesktop, .switchSpaceLeft, .appExpose, .customClick, .scrollCustom, .moveMouseRelative, .pasteString,
            .pressFunctionKey, .modifierKeyDown, .modifierKeyUp, .pressArrowKey, .setVolume, .setBrightness, .playSoundFile,
            .speakText, .showNotification, .copyTextToClipboard, .openFileOrFolder, .revealInFinder, .runAppleShortcut,
            .runJavaScript, .repeatLoop, .cycleActions, .toggleOnOff, .increaseVariable, .decreaseVariable, .askForInput,
            .debounce, .enableTrigger, .disableTrigger, .waitFor, .disableTriggersForSeconds,
            .runSwiftScript, .pressAccessibilityElement, .setAccessibilityValue, .matchScreenImage, .showFloatingMenu]
        for type in needsForm { XCTAssertTrue(ActionParameterForm.handles(type), type.rawValue) }
        XCTAssertFalse(ActionParameterForm.handles(.maximizeWindow))
        XCTAssertTrue(ActionParameterForm.handles(.runShellScript), "Shared script form is also used by floating menu items")
        XCTAssertFalse(ActionParameterForm.infoNote(.emptyTrash).isEmpty)
        for anchor in ActionParameterValidation.anchors { XCTAssertFalse(ActionParameterForm.anchorTitle(anchor).isEmpty) }
        for name in ActionParameterValidation.modifierNames { XCTAssertFalse(ActionParameterForm.modifierTitle(name).isEmpty) }
    }

    func testHotKeyRequirementsForSystemShortcutActions() {
        XCTAssertEqual(ActionType.switchSpaceLeft.requiredHotKeyID(), 79)
        XCTAssertEqual(ActionType.moveWindowToNextSpace.requiredHotKeyID(), 81)
        XCTAssertEqual(ActionType.switchToDesktop.requiredHotKeyID(desktop: 4), 121)
        XCTAssertEqual(ActionType.switchToDesktop.requiredHotKeyID(desktop: 99), 126, "out-of-range desktops clamp")
        XCTAssertNil(ActionType.missionControl.requiredHotKeyID())
        XCTAssertNil(ActionType.maximizeWindow.requiredHotKeyID())
    }

    func testDragReorderMovesBeforeTargetAndReparents() {
        let a = marker("a"), b = marker("b"), c = marker("c")
        var inner = marker("inner")
        var group = TriggerAction(actionType: .actionGroup); group.parameters.children = [inner]
        var list = [a, b, c, group]
        XCTAssertTrue(ActionTree.move(&list, id: c.id, before: a.id))
        XCTAssertEqual(list.map(\.id), [c.id, a.id, b.id, group.id])
        // Dropping onto a nested row moves into that row's list.
        XCTAssertTrue(ActionTree.move(&list, id: b.id, before: inner.id))
        XCTAssertEqual(list.map(\.id), [c.id, a.id, group.id])
        XCTAssertEqual(list[2].parameters.children?.map(\.id), [b.id, inner.id])
        // A container can't be dropped into itself.
        XCTAssertFalse(ActionTree.move(&list, id: group.id, before: inner.id))
        XCTAssertFalse(ActionTree.move(&list, id: a.id, before: a.id))
        XCTAssertFalse(ActionTree.move(&list, id: UUID(), before: a.id))
        XCTAssertFalse(ActionTree.move(&list, id: a.id, before: UUID()))
        XCTAssertEqual(list.map(\.id), [c.id, a.id, group.id], "failed moves leave the list untouched")
        XCTAssertTrue(ActionTree.moveToEnd(&list, id: b.id))
        XCTAssertEqual(list.last?.id, b.id)
        XCTAssertNil(ActionTree.problem(list))
        inner.isEnabled = false // silence unused-mutation warning
    }

    func testCopyPasteGivesFreshIdsRecursively() {
        var child = marker("child"); child.parameters.delayBeforeMs = 5
        var group = TriggerAction(actionType: .repeatLoop)
        group.parameters.loopCount = 3; group.parameters.children = [child]
        ActionClipboard.copied = group
        defer { ActionClipboard.copied = nil }
        let pasted = ActionClipboard.pasteCopy()!
        XCTAssertNotEqual(pasted.id, group.id)
        XCTAssertNotEqual(pasted.parameters.children?.first?.id, child.id)
        XCTAssertEqual(pasted.parameters.loopCount, 3)
        XCTAssertEqual(pasted.parameters.children?.first?.parameters.delayBeforeMs, 5)
        XCTAssertNil(ActionTree.problem([group, pasted]), "a copy can sit beside its source")
        ActionClipboard.copied = nil
        XCTAssertNil(ActionClipboard.pasteCopy())
    }

    func testDisabledStepSurvivesButIsSkipped() {
        var off = marker("off"); off.isEnabled = false
        var fired: [String] = []
        let previous = ActionExecutor.onActionExecuted
        defer { ActionExecutor.onActionExecuted = previous }
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.label ?? "") }
        let done = expectation(description: "done")
        ActionExecutor.executeActions([marker("on"), off]) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fired, ["on"])
        let decoded = try! JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(decoded.isEnabled)
    }

    func testSummaryLinesForNewActions() {
        func summary(_ type: ActionType, _ edit: (inout ActionParameters) -> Void = { _ in }) -> String? {
            var action = TriggerAction(actionType: type, parameters: type.defaultParameters); edit(&action.parameters)
            return ActionSummary.detail(action)
        }
        XCTAssertEqual(summary(.setVolume), "50 %")
        XCTAssertEqual(summary(.switchToDesktop) { $0.desktopNumber = 3 }, "Desktop 3")
        XCTAssertEqual(summary(.pressFunctionKey) { $0.functionKeyNumber = 5 }, "F5")
        XCTAssertEqual(summary(.repeatLoop), "2× · 0 steps")
        XCTAssertEqual(summary(.emptyTrash), "asks first")
        XCTAssertEqual(summary(.emptyTrash) { $0.requiresConfirmation = false }, "no confirmation")
        XCTAssertTrue(summary(.moveResizeWindow)!.contains("60%"))
        XCTAssertNil(summary(.maximizeWindow))
    }
}
