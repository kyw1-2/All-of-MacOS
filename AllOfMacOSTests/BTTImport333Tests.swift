import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// BTT importer coverage for 3.3.3: trigger and action tables, app groups,
/// enabled state, names and notes, the three-group report, script safety and
/// hostile input. Fixtures are authored here in BTT's documented JSON shape;
/// files only ever go to a temporary directory.
@MainActor
final class BTTImport333Tests: XCTestCase {
    typealias Group = BTTPresetImport.Entry.Group

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func parse(_ value: Any, apps: [String: String] = [:]) throws -> BTTPresetImport.Report {
        try BTTPresetImport.parse(data(value)) { apps[$0.path] }
    }
    private func trackpad(_ type: Int, actions: [[String: Any]] = [["BTTPredefinedActionType": 5]], extras: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeTouchpadAll", "BTTTriggerType": type, "BTTActionsToExecute": actions]
        t.merge(extras) { _, new in new }; return t
    }
    private func keyboard(_ actions: [[String: Any]], extras: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut", "BTTTriggerType": 0, "BTTShortcutKeyCode": 8,
                                "BTTShortcutModifierKeys": 1_048_576, "BTTTriggerOnDown": 1, "BTTActionsToExecute": actions]
        t.merge(extras) { _, new in new }; return t
    }
    private func trigger(_ report: BTTPresetImport.Report, file: StaticString = #filePath, line: UInt = #line) throws -> Trigger {
        try XCTUnwrap(report.triggers.first, file: file, line: line)
    }
    private func group(_ report: BTTPresetImport.Report) -> Group? { report.entries.first { $0.kind == .trigger }?.group }

    // MARK: Trigger tables

    func testEveryCatalogTrackpadGestureMapsOrIsSkippedWithItsName() throws {
        for (id, gesture) in BTTImportMappings.trackpad.sorted(by: { $0.key < $1.key }) {
            let needsModifier = gesture.aom?.isTrackpadScroll == true
            let report = try parse([trackpad(id, extras: needsModifier ? ["BTTRequiredModifierKeys": 1_048_576] : [:])])
            let entry = try XCTUnwrap(report.entries.first { $0.kind == .trigger }, "\(id)")
            XCTAssertEqual(entry.bttName, gesture.name, "\(id)")
            XCTAssertEqual(entry.bttID, "TouchpadAll \(id)", "\(id)")
            if let aom = gesture.aom {
                XCTAssertEqual(try trigger(report).input, .trackpadGesture(aom), "\(id)")
                XCTAssertEqual(entry.group, gesture.approximation == nil ? .imported : .approximate, "\(id)")
            } else {
                XCTAssertTrue(report.triggers.isEmpty, "\(id)")
                XCTAssertEqual(entry.group, .skipped, "\(id)")
                XCTAssertEqual(entry.reasons, [gesture.gap!], "\(id)")
            }
        }
    }

    func testRepresentativeTrackpadRows() throws {
        let rows: [(Int, TrackpadGesture?, Group)] = [
            (102, .threeFingerSwipeUp, .imported), (159, .twoFingerSwipeLeft, .imported), (107, .fourFingerSwipeDown, .imported),
            (115, .twoFingerPinchIn, .imported), (138, .tipTapMiddle, .imported), (203, .forceClick, .imported),
            (214, .releaseLastFingerRegardless, .imported), (194, .fourFingerPinchIn, .approximate),
            (176, nil, .skipped), (255, nil, .skipped), (999, nil, .skipped)
        ]
        for (id, gesture, expected) in rows {
            let report = try parse(trackpad(id))
            XCTAssertEqual(group(report), expected, "\(id)")
            XCTAssertEqual(report.triggers.first?.input, gesture.map { .trackpadGesture($0) }, "\(id)")
        }
        let builtIn = try parse(trackpad(102, extras: ["BTTTriggerClass": "BTTTriggerTypeTouchpadBuiltIn"]))
        XCTAssertEqual(group(builtIn), .approximate)
        XCTAssertTrue(builtIn.entries[0].reasons.contains { $0.contains("built-in trackpad") })
        let longTouch = try trigger(parse(trackpad(222, extras: ["BTTAdditionalConfiguration": "0.8"])))
        XCTAssertEqual(longTouch.longTouchDurationMs, 800)
        let scrollWithoutModifier = try parse(trackpad(119))
        XCTAssertTrue(scrollWithoutModifier.triggers.isEmpty)
    }

    func testMagicMouseTouchBarAndOtherDeviceClassesAreSkippedByName() throws {
        for (id, name) in BTTImportMappings.magicMouse {
            let report = try parse(["BTTTriggerClass": "BTTTriggerTypeMagicMouse", "BTTTriggerType": id, "BTTActionsToExecute": [["BTTPredefinedActionType": 5]]])
            let entry = try XCTUnwrap(report.entries.first)
            XCTAssertEqual(entry.group, .skipped)
            XCTAssertEqual(entry.bttName, "Magic Mouse " + name)
            XCTAssertEqual(entry.reasons, [BTTImportMappings.magicMouseGap])
        }
        for cls in ["BTTTriggerTypeTouchBar", "BTTTriggerTypeStreamDeck", "BTTTriggerTypeDrawings", "BTTTriggerTypeMIDI", "BTTTriggerTypeGamepad"] {
            let report = try parse(["BTTTriggerClass": cls, "BTTTriggerType": 629, "BTTActionsToExecute": [["BTTPredefinedActionType": 5]]])
            XCTAssertEqual(group(report), .skipped, cls)
            XCTAssertEqual(report.entries[0].reasons, [BTTImportMappings.unsupportedClasses[cls]!.gap], cls)
        }
    }

    func testKeyboardPhasesHoldTimesAndModifierSides() throws {
        let split = try parse(keyboard([["BTTPredefinedActionType": 21]], extras: [
            "BTTActionCategoryKeyLongPress": [["BTTPredefinedActionType": 19]],
            "BTTActionCategoryKeyRelease": [["BTTPredefinedActionType": 20]],
            "BTTKeyboardShortcutMinTime": 0.2, "BTTKeyboardShortcutMaxTime": 1.5]))
        XCTAssertEqual(group(split), .imported)
        XCTAssertEqual(split.triggers.map(\.keyboardPhase), [.keyDown, .keyUp, .longPress])
        XCTAssertEqual(split.triggers.map { $0.actions.map(\.actionType) }, [[.maximizeWindow], [.snapWindowRight], [.snapWindowLeft]])
        XCTAssertEqual(split.triggers[0].minHoldMs, 200)
        XCTAssertEqual(split.triggers[0].maxHoldMs, 1_500)
        // 1179658 = ⌘⇧ plus the device bits for left ⌘ and left ⇧.
        let sided = try parse(keyboard([["BTTPredefinedActionType": 21]], extras: ["BTTShortcutModifierKeys": 1_179_658]))
        XCTAssertEqual(group(sided), .approximate)
        XCTAssertEqual(try trigger(sided).input, .keyboardShortcut(KeyboardShortcut(keyCode: 8, modifiers: [.command, .shift])))
        let rows: [([String: Any], Group)] = [
            (["BTTShortcutKeyCode": 1004], .skipped), (["BTTShortcutKeyCode": 55], .skipped),
            (["BTTShortcutModifierKeys": 2], .skipped), (["BTTTriggerType": -1], .imported),
            (["BTTAutoAdaptToKeyboardLayout": 1], .approximate), (["BTTKeyboardShortcutKeyboardType": 1118], .imported)
        ]
        for (extras, expected) in rows {
            XCTAssertEqual(group(try parse(keyboard([["BTTPredefinedActionType": 21]], extras: extras))), expected, "\(extras)")
        }
    }

    func testKeySequenceKeepsHeldModifiersOptionalKeysAndGap() throws {
        // ⌘ held while F is pressed twice, as BTT records it.
        let key: (Int, Int?) -> [String: Any] = { code, down in
            var k: [String: Any] = ["BTTKEYCode": code, "BTTKEYRequired": 1, "BTTKEYOrderRelevant": 1]
            if let down { k["BTTKEYDown"] = down }; return k
        }
        let sequence: [String: Any] = [
            "BTTTriggerClass": "BTTTriggerTypeKeySequence", "BTTTriggerType": 624,
            "BTTKeySequence": ["BTTPauseBetween": 3, "BTTKeyCount": 5,
                               "BTTKeySequenceDownKeys": [key(55, 1), key(3, 1), key(3, 1)],
                               "BTTKeySequenceMixedKeys": [key(55, 1), key(3, 1), key(3, nil), key(3, 1), key(3, nil)],
                               "BTTKeySequenceUpKeys": [key(3, nil), key(3, nil)]],
            "BTTActionsToExecute": [["BTTPredefinedActionType": 124, "BTTMenubarPath": "Edit;Find;Jump to Top"]]
        ]
        let report = try parse([sequence])
        let imported = try trigger(report)
        let cmd = NSEvent.ModifierFlags.command.rawValue
        XCTAssertEqual(imported.input, .keySequence([KeySequenceStroke(keyCode: 55, modifiers: 0), KeySequenceStroke(keyCode: 3, modifiers: cmd), KeySequenceStroke(keyCode: 3, modifiers: cmd)]))
        XCTAssertEqual(imported.sequenceMaxGapMs, 2_000)
        XCTAssertEqual(group(report), .approximate, "3 s between keys is clamped to AOM's 2 s")
        XCTAssertEqual(imported.actions.first?.parameters.menuPath, "Edit > Find > Jump to Top")
        var long = sequence
        long["BTTKeySequence"] = ["BTTKeySequenceDownKeys": Array(repeating: key(0, 1), count: 7)]
        XCTAssertEqual(group(try parse(long)), .skipped)
    }

    func testNormalMouseClicksDragsAndPrimaryButtonSafety() throws {
        func mouse(_ type: Int, _ extras: [String: Any] = [:]) -> [String: Any] {
            var t: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeNormalMouse", "BTTTriggerType": type, "BTTShortcutToSend": "55,13"]
            t.merge(extras) { _, new in new }; return t
        }
        let middle = try trigger(parse(mouse(1002)))
        XCTAssertEqual(middle.input, .mouse(MouseTriggerSpec(button: 2, kind: .click)))
        XCTAssertEqual(middle.actions.first?.parameters.shortcutKeyCode, 13)
        XCTAssertEqual(try trigger(parse(mouse(1104))).input, .mouse(MouseTriggerSpec(button: 4, kind: .doubleClick)))
        let gestures = try parse(mouse(1002, ["BTTActionCategoryDragUp": [["BTTPredefinedActionType": 5]],
                                              "BTTActionCategoryDragLeft": [["BTTPredefinedActionType": 113]]]))
        XCTAssertEqual(gestures.triggers.map(\.input), [.mouse(MouseTriggerSpec(button: 2, kind: .click)),
                                                        .mouse(MouseTriggerSpec(button: 2, kind: .dragUp)),
                                                        .mouse(MouseTriggerSpec(button: 2, kind: .dragLeft))])
        XCTAssertEqual(group(try parse(mouse(1000))), .skipped, "left clicks need a modifier")
        let guarded = try trigger(parse(mouse(1000, ["BTTRequiredModifierKeys": 524_288])))
        XCTAssertEqual(guarded.requiredModifiers, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(group(try parse(mouse(1302))), .skipped)
        XCTAssertEqual(group(try parse(mouse(996, ["BTTRequiredModifierKeys": 262_144]))), .imported)
    }

    func testOtherTriggersMapToSystemEventsOrAreSkipped() throws {
        let safari = "/Applications/Safari.app"
        let rows: [(Int, [String: Any], TriggerInput?, Group)] = [
            (605, [:], .systemEvent(.systemWillSleep), .imported),
            (739, [:], .systemEvent(.screenUnlocked), .imported),
            (706, ["BTTAdditionalConfiguration": "20"], .systemEvent(.batteryBelow(20)), .imported),
            (688, ["BTTWifiName": "Home"], .systemEvent(.wifiConnected(ssid: "Home")), .imported),
            (689, ["BTTWifiName": "*"], .systemEvent(.wifiDisconnected(ssid: "")), .imported),
            (785, ["BTTUSBDeviceName": "YubiKey.*"], .systemEvent(.usbConnected(name: "YubiKey")), .approximate),
            (609, ["BTTRepeatDelay": 0.5], .systemEvent(.screenCornerHover(corner: .topLeft, dwellMs: 500)), .imported),
            (661, ["BTTRepeatDelay": 0, "BTTMoveToTopScreenEdgeMinDistance": 8], .systemEvent(.screenEdgeHover(edge: .top, dwellMs: 0, minDistance: 8)), .imported),
            (670, ["BTTAdditionalConfiguration": "file://\(safari)/"], .systemEvent(.appLaunched("com.apple.Safari")), .imported),
            (671, [:], .systemEvent(.appActivated("")), .imported),
            (789, ["BTTAdditionalConfiguration": "mode"], .systemEvent(.variableChanged(name: "mode")), .imported),
            (807, ["BTTGenericActionConfig": "/tmp/watched"], .systemEvent(.fileDidChange(path: "/tmp/watched")), .imported),
            (678, ["BTTAdditionalConfiguration": "{\"BTTTimedWhenToTrigger\":0,\"BTTTimedRepeatEveryXSeconds\":3600}"], .systemEvent(.everyMinutes(60)), .imported),
            (678, ["BTTAdditionalConfiguration": "{\"BTTTimedWhenToTrigger\":1,\"BTTTimedHour\":\"9\",\"BTTTimedMinute\":0,\"BTTTimedSecond\":0,\"BTTTimedWeekday\":\"1-5\"}"],
             .systemEvent(.weekly(days: [2, 3, 4, 5, 6], hour: 9, minute: 0)), .imported),
            (678, ["BTTAdditionalConfiguration": "{\"BTTTimedWhenToTrigger\":1,\"BTTTimedHour\":10}"], nil, .skipped),
            (670, ["BTTAdditionalConfiguration": "file:///Applications/Missing.app/"], nil, .skipped),
            (806, [:], nil, .skipped), (848, [:], nil, .skipped), (683, [:], nil, .skipped)
        ]
        for (type, extras, input, expected) in rows {
            var t: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeOtherTriggers", "BTTTriggerType": type, "BTTActionsToExecute": [["BTTPredefinedActionType": 22]]]
            t.merge(extras) { _, new in new }
            let report = try parse([t], apps: [safari: "com.apple.Safari"])
            XCTAssertEqual(group(report), expected, "\(type) \(extras)")
            XCTAssertEqual(report.triggers.first?.input, input, "\(type) \(extras)")
        }
    }

    // MARK: Action tables

    func testEverySimpleCatalogActionMapsToItsAOMType() throws {
        for (id, info) in BTTImportMappings.actions.sorted(by: { $0.key < $1.key }) {
            let report = try parse(keyboard([["BTTPredefinedActionType": id]]))
            let entry = try XCTUnwrap(report.entries.first { $0.kind == .trigger }, "\(id)")
            switch info.rule {
            case .exact(let type):
                XCTAssertEqual(entry.group, .imported, "\(id) \(info.name)")
                XCTAssertEqual(report.triggers.first?.actions.map(\.actionType), [type], "\(id)")
            case .approximate(let type, let why):
                XCTAssertEqual(entry.group, .approximate, "\(id)")
                XCTAssertEqual(report.triggers.first?.actions.map(\.actionType), [type], "\(id)")
                XCTAssertTrue(entry.reasons.contains { $0.contains(why) }, "\(id)")
            case .unsupported(let why):
                XCTAssertEqual(entry.group, .skipped, "\(id)")
                XCTAssertTrue(entry.reasons[0].contains("\(info.name) (action \(id))"), "\(id) \(entry.reasons)")
                XCTAssertFalse(why.isEmpty)
            case .controlFlow:
                XCTAssertEqual(entry.group, .skipped, "\(id)")
                XCTAssertTrue(entry.reasons[0].contains("control flow"), "\(id)")
            case .noOp:
                XCTAssertEqual(entry.group, .skipped, "\(id): a trigger whose only step does nothing is not imported")
            case .custom:
                break // Parameterized; covered below.
            }
        }
    }

    func testParameterizedActionsConvertTheirSettings() throws {
        typealias Check = (TriggerAction) -> Bool
        let rows: [([String: Any], ActionType, Group, Check)] = [
            (["BTTPredefinedActionType": 193, "BTTStringToType": "Hello"], .typeText, .imported, { $0.parameters.text == "Hello" }),
            (["BTTPredefinedActionType": 118, "BTTStringToType": "{date:yyyy}", "BTTMoveCursorLeftBy": 2], .pasteString, .approximate, { $0.parameters.text == "{date:yyyy}" }),
            (["BTTPredefinedActionType": 264, "BTTShortcutToSend": "63,59,58,56,55,49"], .sendKeyStroke, .imported,
             { $0.parameters.shortcutKeyCode == 49 && $0.parameters.shortcutModifiers == NSEvent.ModifierFlags([.function, .control, .option, .shift, .command]).rawValue }),
            (["BTTPredefinedActionType": 264, "BTTShortcutToSend": "54,8"], .sendKeyStroke, .approximate, { $0.parameters.shortcutModifiers == NSEvent.ModifierFlags.command.rawValue }),
            (["BTTShortcutToSend": "58,55,124", "BTTIsPureAction": true], .sendKeyStroke, .imported, { $0.parameters.shortcutKeyCode == 124 }),
            (["BTTPredefinedActionType": 128, "BTTShortcutToSend": "55,1", "BTTShortcutAppUnderCursor": "com.apple.finder", "BTTShortcutSwitchToAppFirst": 1],
             .sendKeyStroke, .approximate, { $0.parameters.targetApplicationBundleID == "com.apple.finder" }),
            (["BTTPredefinedActionType": 49, "BTTLaunchPath": "/Applications/Safari.app"], .launchApplication, .imported, { $0.parameters.applicationPath == "/Applications/Safari.app" }),
            (["BTTPredefinedActionType": 49, "BTTLaunchPath": "com.apple.Notes"], .launchApplication, .imported, { $0.parameters.applicationName == "com.apple.Notes" }),
            (["BTTPredefinedActionType": 59, "BTTOpenURL": "https://folivora.ai", "BTTOpenURLBrowser": "Safari"], .openURL, .approximate, { $0.parameters.url == "https://folivora.ai" && $0.isEnabled }),
            (["BTTPredefinedActionType": 373, "BTTGenericActionConfig": "50"], .setVolume, .imported, { $0.parameters.levelPercent == 50 }),
            (["BTTPredefinedActionType": 370, "BTTGenericActionConfig": "75"], .setBrightness, .imported, { $0.parameters.levelPercent == 75 }),
            (["BTTPredefinedActionType": 211], .switchToDesktop, .imported, { $0.parameters.desktopNumber == 5 }),
            (["BTTPredefinedActionType": 43], .pressFunctionKey, .imported, { $0.parameters.functionKeyNumber == 11 }),
            (["BTTPredefinedActionType": 443], .modifierKeyDown, .imported, { $0.parameters.modifierKey == "rightCommand" }),
            (["BTTPredefinedActionType": 129, "BTTDelayNextActionBy": "1.5"], .wait, .imported, { $0.parameters.waitMs == 1_500 }),
            (["BTTPredefinedActionType": 248, "BTTNamedTriggerToTrigger": "Child", "BTTAdditionalActionData": ["BTTActionTriggerNamedTriggerVar_mode": "dark"]],
             .triggerNamedTrigger, .approximate, { $0.parameters.namedTriggerName == "Child" }),
            (["BTTPredefinedActionType": 292, "BTTVariableName": "state", "BTTVariableValue": "on"], .setVariable, .imported, { $0.parameters.variableValue == "on" }),
            (["BTTPredefinedActionType": 254, "BTTAdditionalActionData": ["BTTActionHUDTitle": "Saved"]], .showHUD, .imported, { $0.parameters.hudText == "Saved" }),
            (["BTTPredefinedActionType": 371, "BTTAdditionalActionData": ["BTTActionSendNotificationTitle": "T", "BTTActionSendNotificationMessage": "M"]],
             .showNotification, .imported, { $0.parameters.notificationTitle == "T" && $0.parameters.text == "M" }),
            (["BTTPredefinedActionType": 583, "BTTAdditionalActionData": ["BTTAudioDeviceName": "MacBook Pro Speakers", "BTTAudioDeviceUID": "BuiltInSpeakerDevice"]],
             .setSoundOutput, .imported, { $0.parameters.audioOutputUID == "BuiltInSpeakerDevice" }),
            (["BTTPredefinedActionType": 529, "BTTAdditionalActionData": "{\"BTTActionSetClipboardContentsAttributedString\":\"Copied\",\"BTTActionSetClipboardContentsFormat\":\"0\"}"],
             .copyTextToClipboard, .imported, { $0.parameters.text == "Copied" }),
            (["BTTPredefinedActionType": 502, "BTTDisableTriggerForXSeconds": "10"], .disableTriggersForSeconds, .imported, { $0.parameters.pauseSeconds == 10 }),
            (["BTTPredefinedActionType": 107], .zoomWindow, .imported, { $0.parameters.windowTarget == "underCursor" }),
            (["BTTPredefinedActionType": 21, "BTTDelayNextActionBy": 0.25], .maximizeWindow, .imported, { $0.parameters.delayAfterMs == 250 })
        ]
        for (json, type, expected, check) in rows {
            let report = try parse(keyboard([json]))
            XCTAssertEqual(group(report), expected, "\(json)")
            let action = try XCTUnwrap(report.triggers.first?.actions.first, "\(json)")
            XCTAssertEqual(action.actionType, type, "\(json)")
            XCTAssertTrue(check(action), "\(json) → \(action.parameters)")
        }
    }

    func testUnsupportedStepsBecomeDisabledPlaceholdersAndAreListedAsSkipped() throws {
        let report = try parse(keyboard([["BTTPredefinedActionType": 21], ["BTTPredefinedActionType": 249, "BTTPredefinedActionName": "Show Floating Web View"],
                                         ["BTTPredefinedActionType": 99_999], ["BTTPredefinedActionType": 22]]))
        let imported = try trigger(report)
        XCTAssertEqual(group(report), .approximate)
        XCTAssertFalse(imported.isEnabled, "approximate imports are added disabled")
        XCTAssertEqual(imported.actions.map(\.actionType), [.maximizeWindow, .showHUD, .showHUD, .muteVolume])
        XCTAssertEqual(imported.actions.map(\.isEnabled), [true, false, false, true])
        let skippedActions = report.entries(in: .skipped).filter { $0.kind == .action }
        XCTAssertEqual(skippedActions.map(\.bttID), ["action 249", "action 99999"])
        XCTAssertTrue(imported.notes.contains("Show Floating Web View"))
        let flow = try parse(keyboard([["BTTPredefinedActionType": 330], ["BTTPredefinedActionType": 21], ["BTTPredefinedActionType": 334]]))
        XCTAssertTrue(flow.triggers.isEmpty, "IF blocks never become unconditional steps")
    }

    // MARK: Safety

    func testScriptsShortcutsRunnableFilesAndAppLinksArriveDisabledAndFlagged() throws {
        let rows: [([String: Any], ActionType, Group)] = [
            (["BTTPredefinedActionType": 172, "BTTAdditionalActionData": ["BTTScriptType": 0, "BTTAppleScriptString": "beep"]], .runAppleScript, .imported),
            (["BTTPredefinedActionType": 195, "BTTInlineAppleScript": "beep"], .runAppleScript, .approximate),
            (["BTTPredefinedActionType": 252, "BTTAdditionalActionData": "{\"BTTScriptType\":1,\"BTTAppleScriptString\":\"1\"}"], .runJavaScript, .approximate),
            (["BTTPredefinedActionType": 246, "BTTTerminalCommand": "echo hi"], .runShellScript, .approximate),
            (["BTTPredefinedActionType": 206, "BTTShellTaskActionScript": "echo hi", "BTTShellTaskActionConfig": "/bin/zsh:::-c:::-:::"], .runShellScript, .imported),
            (["BTTPredefinedActionType": 295, "BTTAdditionalActionData": ["BTTFormAppleShortcutName": "Morning"]], .runAppleShortcut, .imported),
            (["BTTPredefinedActionType": 49, "BTTLaunchPath": "/Users/me/run.command"], .openFileOrFolder, .imported),
            (["BTTPredefinedActionType": 59, "BTTOpenURL": "shortcuts://run-shortcut?name=X"], .openURL, .imported)
        ]
        for (json, type, expected) in rows {
            let report = try parse(keyboard([json, ["BTTPredefinedActionType": 22]]))
            let imported = try trigger(report)
            let entry = report.entries[0]
            XCTAssertEqual(entry.group, expected, "\(json)")
            XCTAssertTrue(entry.needsReview, "\(json)")
            XCTAssertEqual(imported.actions.first?.actionType, type, "\(json)")
            XCTAssertEqual(imported.actions.first?.isEnabled, false, "\(json)")
            XCTAssertEqual(imported.actions.last?.isEnabled, true, "other steps keep their state")
            XCTAssertEqual(imported.isEnabled, expected == .imported, "the trigger keeps BTT's enabled state only when exact")
        }
        let python = try parse(keyboard([["BTTPredefinedActionType": 206, "BTTShellTaskActionScript": "print(1)", "BTTShellTaskActionConfig": "/usr/bin/python3:::-c:::-:::"]]))
        XCTAssertTrue(python.triggers.isEmpty, "other interpreters are not run as zsh")
        let filed = try parse(keyboard([["BTTPredefinedActionType": 172, "BTTAdditionalActionData": ["BTTAppleScriptUsePath": true, "BTTAppleScriptString": "x"]]]))
        XCTAssertTrue(filed.triggers.isEmpty)
    }

    func testMalformedAndHostileInputThrowsOrSkipsWithoutCrashing() throws {
        let blobs: [Data] = [
            Data(), Data("{".utf8), Data("[1, 2".utf8), Data("null".utf8), Data("42".utf8), Data("\"text\"".utf8),
            Data([0xFF, 0xFE, 0x00, 0x7B]), Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]),
            Data((String(repeating: "[", count: 40) + String(repeating: "]", count: 40)).utf8),
            Data("{\"BTTPresetContent\": 5}".utf8), Data("{\"BTTPresetContent\": []}".utf8),
            Data("{\"BTTPresetContent\": [{\"BTTAppBundleIdentifier\": \"BT.G\", \"BTTTriggers\": 7}]}".utf8),
            Data("{\"Unrelated\": true}".utf8)
        ]
        for blob in blobs {
            XCTAssertThrowsError(try BTTPresetImport.parse(blob), "\(blob.prefix(16) as NSData)")
        }
        XCTAssertThrowsError(try BTTPresetImport.parse(Data("[\"\(String(repeating: "a", count: BTTPresetImport.maximumStringBytes + 1))\"]".utf8)))
        let hostile: [Any] = [
            "not an object", 17, NSNull(), ["BTTTriggerClass": 5],
            ["BTTTriggerClass": "BTTTriggerTypeTouchpadAll", "BTTTriggerType": "102", "BTTActionsToExecute": [["BTTPredefinedActionType": 5]]],
            trackpad(102, actions: [["BTTPredefinedActionType": true]]), trackpad(102, extras: ["BTTActionsToExecute": ["x"]]),
            trackpad(102, extras: ["BTTActionsToExecute": "nope"]), trackpad(102, extras: ["BTTGestureNotes": "a\u{0}b"]),
            trackpad(102, extras: ["BTTEnabled": 2]), trackpad(102, extras: ["BTTRequiredModifierKeys": 1 << 30]),
            keyboard([["BTTPredefinedActionType": 59, "BTTOpenURL": "not a url"]]),
            keyboard([["BTTPredefinedActionType": 49, "BTTLaunchPath": "relative/path.app"]]),
            keyboard([["BTTPredefinedActionType": 373, "BTTGenericActionConfig": "150"]]),
            keyboard([["BTTPredefinedActionType": 248, "BTTNamedTriggerToTrigger": "bad\nname"]]),
            keyboard([["BTTPredefinedActionType": 254, "BTTAdditionalActionData": "{not json"]]),
            ["BTTTriggerClass": "BTTTriggerTypeOtherTriggers", "BTTTriggerType": 643, "BTTTriggerName": "", "BTTActionsToExecute": [["BTTPredefinedActionType": 5]]]
        ]
        let report = try parse(hostile)
        XCTAssertTrue(report.triggers.isEmpty)
        XCTAssertEqual(report.skipped.count, hostile.count)
        XCTAssertTrue(report.entries.allSatisfy { $0.group == .skipped && !$0.reasons.isEmpty })

        // Seeded mutations of a valid preset: every result is a report or an error.
        let valid = try data(presetFixture())
        var seed: UInt64 = 0x5EED_B77
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: seed >> 33) }
        for _ in 0..<300 {
            var bytes = [UInt8](valid)
            for _ in 0...(abs(next()) % 4) {
                let index = abs(next()) % bytes.count
                switch abs(next()) % 3 {
                case 0: bytes[index] = UInt8(truncatingIfNeeded: next())
                case 1: bytes.remove(at: index)
                default:
                    let alphabet = Array("{}[],:\"0".utf8)
                    bytes.insert(alphabet[abs(next()) % alphabet.count], at: index)
                }
            }
            if let report = try? BTTPresetImport.parse(Data(bytes)) {
                XCTAssertLessThanOrEqual(report.triggers.count, BTTPresetImport.maximumTriggers * 4)
            }
        }
    }

    // MARK: Preset files, scopes, names, notes and the merge

    private func presetFixture() -> [String: Any] {
        [
            "BTTPresetName": "Work", "BTTPresetUUID": "B754F447-A985-4C6D-AB3E-5C6080034F63", "BTTPresetSnapAreas": [],
            "BTTPresetContent": [
                ["BTTAppBundleIdentifier": "BT.L", "BTTAppName": "Recently Used", "BTTTriggers": [trackpad(100)]],
                ["BTTAppBundleIdentifier": "com.apple.Safari", "BTTAppName": "Safari", "BTTAppAutoInvertIcon": 1,
                 "BTTAppSpecificSettings": ["BTTDisableGlobalTriggers": true],
                 "BTTTriggers": [
                    ["BTTLastUpdatedAt": 1_767_552_443.74, "BTTTriggerType": 113, "BTTTriggerTypeDescriptionReadOnly": "TipTap Left (1 Finger Fix)",
                     "BTTTriggerClass": "BTTTriggerTypeTouchpadAll", "BTTUUID": "97A7659F-D847-4596-8D64-52F5F77214D9", "BTTOrder": 1,
                     "BTTGestureNotes": "Previous tab", "BTTTriggerTypeDescription": "Tab left",
                     "BTTActionsToExecute": [["BTTTriggerParentUUID": "97A7659F-D847-4596-8D64-52F5F77214D9", "BTTIsPureAction": true,
                                              "BTTTriggerClass": "BTTTriggerTypeTouchpadAll", "BTTUUID": "F2BC10C9-D26F-404F-86C8-7617CFFB54A3",
                                              "BTTLayoutIndependentActionChar": "LEFT", "BTTShortcutToSend": "58,55,123", "BTTOrder": 2]]],
                    ["BTTTriggerType": 0, "BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut", "BTTOrder": 0, "BTTEnabled": 1, "BTTEnabled2": 0,
                     "BTTShortcutKeyCode": 17, "BTTShortcutModifierKeys": 1_048_576, "BTTTriggerOnDown": 1,
                     "BTTActionsToExecute": [["BTTPredefinedActionType": 246, "BTTTerminalCommand": "open -a Terminal"]]]
                 ]],
                ["BTTAppBundleIdentifier": "BT.G", "BTTAppName": "Global", "BTTAppSpecificSettings": ["BTTDisableGlobalTriggers": false],
                 "BTTTriggers": [
                    ["BTTTriggerType": 102, "BTTTriggerClass": "BTTTriggerTypeTouchpadAll", "BTTTriggerTypeDescriptionReadOnly": "3 Finger Swipe Up",
                     "BTTOrder": 0, "BTTActionsToExecute": [["BTTPredefinedActionType": 5, "BTTPredefinedActionName": "Mission Control"]]],
                    ["BTTTriggerType": 1002, "BTTTriggerClass": "BTTTriggerTypeNormalMouse", "BTTShortcutToSend": "55,13", "BTTOrder": 1],
                    ["BTTTriggerType": 643, "BTTTriggerClass": "BTTTriggerTypeOtherTriggers", "BTTTriggerName": "Window Task", "BTTOrder": 2,
                     "BTTActionsToExecute": [["BTTPredefinedActionType": 19]]],
                    ["BTTTriggerType": 7, "BTTTriggerClass": "BTTTriggerTypeMagicMouse", "BTTOrder": 3, "BTTActionsToExecute": [["BTTPredefinedActionType": 5]]],
                    ["BTTTriggerType": 629, "BTTTriggerClass": "BTTTriggerTypeTouchBar", "BTTTouchBarButtonName": "Notes", "BTTOrder": 4,
                     "BTTPredefinedActionType": 49, "BTTLaunchPath": "/System/Applications/Notes.app"]
                 ]]
            ]
        ]
    }

    func testPresetFileKeepsAppScopesEnabledStateNamesAndNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BTTImport333-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Work.bttpreset")
        try data(presetFixture()).write(to: file)
        let report = try BTTPresetImport.parse(BTTPresetImport.read(file))

        XCTAssertEqual(report.presetName, "Work")
        XCTAssertEqual(report.candidateCount, 8)
        XCTAssertEqual(report.appTargets.map(\.bundleID), ["com.apple.Safari"])
        XCTAssertEqual(report.appTargets.map(\.name), ["Safari"])
        let byInput = Dictionary(report.triggers.map { ($0.input.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        let tab = try XCTUnwrap(byInput["TipTap Left"])
        XCTAssertEqual(tab.appBundleID, "com.apple.Safari")
        XCTAssertEqual(tab.name, "Tab left")
        XCTAssertTrue(tab.notes.hasPrefix("Previous tab\n"))
        XCTAssertTrue(tab.isEnabled)
        XCTAssertEqual(tab.actions.first?.parameters.shortcutKeyCode, 123)
        let terminal = try XCTUnwrap(report.triggers.first { $0.input == .keyboardShortcut(KeyboardShortcut(keyCode: 17, modifiers: .command)) })
        XCTAssertFalse(terminal.isEnabled, "BTTEnabled2 = 0 stays disabled")
        XCTAssertFalse(terminal.actions[0].isEnabled, "shell steps are disabled")
        let swipe = try XCTUnwrap(byInput["3 Finger Swipe Up"])
        XCTAssertNil(swipe.appBundleID)
        XCTAssertTrue(swipe.isEnabled)
        XCTAssertEqual(swipe.actions.map(\.actionType), [.missionControl])
        XCTAssertEqual(byInput["Middle Click"]?.actions.first?.parameters.shortcutKeyCode, 13)
        XCTAssertEqual(byInput["Window Task"]?.input, .namedTrigger("Window Task"))

        let skipped = report.entries(in: .skipped)
        XCTAssertEqual(Set(skipped.map(\.bttID)), ["TouchpadAll 100", "MagicMouse 7", "TouchBar 629"])
        XCTAssertTrue(skipped.contains { $0.bttName == "Magic Mouse 2 Finger Swipe Up" })
        XCTAssertTrue(report.entries(in: .approximate).contains { $0.kind == .scope && $0.scope.contains("com.apple.Safari") })
        XCTAssertTrue(report.entries.contains { $0.needsReview && $0.bttID == "KeyboardShortcut 0" })
        XCTAssertTrue(report.reviewText.contains("Skipped (3)"))
    }

    func testReviewedMergeAddsScopesAndKeepsStagedState() throws {
        let report = try parse(presetFixture())
        let state = AppState()
        state.currentPreset = Preset(name: "Existing")
        let existing = Trigger(name: "Keep", input: .namedTrigger("Window Task"))
        state.currentPreset.addTrigger(existing)
        XCTAssertEqual(state.bttNamedTriggerCollisions(report), ["Window Task"])
        state.addReviewedBTTImport(report)
        XCTAssertEqual(state.currentPreset.name, "Existing")
        XCTAssertEqual(state.currentPreset.triggers.first, existing)
        XCTAssertEqual(state.currentPreset.triggers.count, 1 + report.triggers.count)
        XCTAssertTrue(state.currentPreset.appTargets.contains { $0.bundleID == "com.apple.Safari" && $0.name == "Safari" })
        XCTAssertEqual(state.currentPreset.triggers.dropFirst().map(\.isEnabled), report.triggers.map(\.isEnabled))
        state.addReviewedBTTImport(try parse(presetFixture()))
        XCTAssertEqual(state.currentPreset.appTargets.filter { $0.bundleID == "com.apple.Safari" }.count, 1)
        XCTAssertNoThrow(try PresetCodec.decode(PresetCodec.encode(state.currentPreset)))
        state.flushPendingWrites()
    }

    func testReportViewRendersAllThreeGroups() throws {
        let report = try parse(presetFixture())
        XCTAssertFalse(report.entries(in: .imported).isEmpty)
        XCTAssertFalse(report.entries(in: .approximate).isEmpty)
        XCTAssertFalse(report.entries(in: .skipped).isEmpty)
        let host = NSHostingView(rootView: BTTImportReportView(report: report, namedTriggerCollisions: ["Window Task"]))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertTrue(BTTPresetImport.openPanelContentTypes.contains { $0.preferredFilenameExtension == "bttpreset" })
    }
}
