import SwiftUI
import ServiceManagement
import AppKit

@main
enum AOMLauncher {
    private static var instanceLease: SingleInstanceLease?
    static func main() {
        let args = ProcessInfo.processInfo.arguments
        // AI tools launch `AllOfMacOS --mcp` as a stdio MCP server; it only
        // bridges to the running app and never starts a second UI instance.
        if args.contains("--mcp") { ClipboardMCPBridge.run(arguments: args) }
        // A malformed preview launch must never fall back to the real preset.
        if (args.contains("--aom-ui-preview") || Bundle.main.bundleIdentifier == "com.kyw.allofmacos.preview") && !PresetManager.isUIPreview {
            fputs("UI preview requires an isolated temporary directory.\n", stderr); exit(2)
        }
        if let i = args.firstIndex(of: "--aom-self-test"), args.indices.contains(i + 1) {
            let result = GestureReplaySuite.run()
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: args[i + 1]), options: .atomic)
                exit(result["passed"] as? Bool == true ? 0 : 1)
            } catch { fputs("Self-test report failed: \(error)\n", stderr); exit(2) }
        }
        if let i = args.firstIndex(of: "--aom-select-audio"), args.indices.contains(i + 2) {
            _ = NSApplication.shared
            let name = args[i + 1]
            var completed = false; var success = false
            let before = AudioOutputService.currentDeviceID()
            AudioOutputService.shared.select(name: name, uid: nil) { ok in success = ok; completed = true }
            let deadline = Date().addingTimeInterval(20)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let result: [String: Any] = ["requested": name, "success": success && completed,
                "accessibility": AXIsProcessTrusted(), "before": before.map(Int.init) ?? -1,
                "after": AudioOutputService.currentDeviceID().map(Int.init) ?? -1]
            writeCheck(result, path: args[i + 2]); exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-window-batch"), args.indices.contains(i + 2), let pid = Int32(args[i + 1]) {
            _ = NSApplication.shared
            let manager = WindowManager.shared
            let targets = manager.diagnosticTargets(pid: pid)
            guard targets.count >= 2 else { exit(2) }
            let originals = targets.compactMap { manager.frame(of: $0) }
            guard originals.count == targets.count else { exit(2) }
            let name = "AOM batch diagnostic " + UUID().uuidString
            var completed = false; var steps: [[String: Any]] = []
            func matches(_ expected: [CGRect]) -> Bool {
                zip(targets, expected).allSatisfy { target, frame in manager.frame(of: target).map { WindowGeometry.close($0, frame) } == true }
            }
            guard manager.saveLayout(name: name, onlyPID: pid) else { exit(2) }
            func finish() {
                if let id = manager.layouts.first(where: { $0.name == name })?.id { manager.removeLayout(id) }
                completed = true
            }
            func move(_ index: Int) {
                guard index < targets.count else {
                    let moved = targets.compactMap { manager.frame(of: $0) }
                    manager.restoreLayout(name: name) { ok in
                        steps.append(["step": "Restore all", "success": ok && matches(originals)])
                        manager.undoLastPlacement { ok in
                            steps.append(["step": "Undo all", "success": ok && matches(moved)])
                            manager.restoreLayout(name: name) { ok in
                                steps.append(["step": "Restore originals", "success": ok && matches(originals)])
                                finish()
                            }
                        }
                    }
                    return
                }
                manager.execute(index % 2 == 0 ? .snapWindowLeft : .snapWindowRight, target: targets[index]) { ok in
                    steps.append(["step": "Move receiver \(index)", "success": ok]); move(index+1)
                }
            }
            move(0)
            let deadline = Date().addingTimeInterval(35)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let success = completed && steps.allSatisfy { $0["success"] as? Bool == true }
            writeCheck(["success": success, "windows": targets.count, "steps": steps], path: args[i+2])
            exit(success ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-window-history"), args.indices.contains(i + 2), let pid = Int32(args[i + 1]) {
            _ = NSApplication.shared
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.kyw.allofmacos.gesture-test",
                  let target = WindowManager.shared.captureTarget(pid: pid),
                  let original = WindowManager.shared.frame(of: target) else { exit(2) }
            let manager = WindowManager.shared
            let name = "AOM diagnostic " + UUID().uuidString
            var results: [[String: Any]] = []; var complete = false
            let operations: [(String, (@escaping (Bool) -> Void) -> Void)] = [
                ("Save receiver", { done in done(manager.saveLayout(name: name, onlyPID: pid)) }),
                ("Left", { manager.execute(.snapWindowLeft, target: target, completion: $0) }),
                ("Right", { manager.execute(.snapWindowRight, target: target, completion: $0) }),
                ("Undo right", { manager.undoLastPlacement(completion: $0) }),
                ("Undo left", { done in manager.undoLastPlacement { ok in done(ok && manager.frame(of: target).map { WindowGeometry.close($0, original) } == true) } }),
                ("Maximize", { manager.execute(.maximizeWindow, target: target, completion: $0) }),
                ("Restore layout", { done in manager.restoreLayout(name: name) { ok in done(ok && manager.frame(of: target).map { WindowGeometry.close($0, original) } == true) } }),
                ("Undo layout", { manager.undoLastPlacement(completion: $0) }),
                ("Restore original", { manager.execute(.restoreWindowSize, target: target, completion: $0) })
            ]
            func step(_ index: Int) {
                guard index < operations.count else { complete = true; return }
                operations[index].1 { ok in
                    results.append(["step": operations[index].0, "success": ok, "frame": manager.frame(of: target).map(NSStringFromRect) ?? "missing"])
                    step(index + 1)
                }
            }
            step(0)
            let deadline = Date().addingTimeInterval(35)
            while !complete && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if let id = manager.layouts.first(where: { $0.name == name })?.id { manager.removeLayout(id) }
            let success = complete && results.allSatisfy { $0["success"] as? Bool == true }
            writeCheck(["success": success, "steps": results, "accessibility": AXIsProcessTrusted()], path: args[i+2])
            exit(success ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-window"), args.indices.contains(i + 2), let pid = Int32(args[i + 1]) {
            _ = NSApplication.shared
            // Diagnostics may only move the disposable test receiver.
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.kyw.allofmacos.gesture-test",
                  let target = WindowManager.shared.captureTarget(pid: pid),
                  let original = WindowManager.shared.frame(of: target) else { exit(2) }
            let manager = WindowManager.shared
            let screens = manager.screens()
            var steps: [[String: Any]] = []; var completed = false; var success = true
            let actions: [ActionType] = [.moveWindowNextMonitor, .maximizeWindow, .moveWindowNextMonitor, .maximizeWindow]
            func restore() {
                manager.execute(.restoreWindowSize, target: target) { ok in
                    success = success && ok
                    steps.append(["action": "Restore", "success": ok, "frame": manager.frame(of: target).map(NSStringFromRect) ?? "missing"])
                    completed = true
                }
            }
            func step(_ index: Int) {
                guard index < actions.count else { restore(); return }
                manager.execute(actions[index], target: target) { ok in
                    steps.append(["action": actions[index].rawValue, "success": ok,
                        "frame": manager.frame(of: target).map(NSStringFromRect) ?? "missing"])
                    success = success && ok
                    if ok { step(index + 1) } else { restore() }
                }
            }
            step(0)
            let deadline = Date().addingTimeInterval(15)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            writeCheck(["success": success && completed, "steps": steps, "original": NSStringFromRect(original),
                        "screens": screens.map { NSStringFromRect($0.visible) }], path: args[i + 2])
            exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-window-parity"), args.indices.contains(i + 2), let pid = Int32(args[i + 1]) {
            _ = NSApplication.shared
            // Only the disposable receiver may be moved, same as --aom-check-window.
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.kyw.allofmacos.gesture-test",
                  let target = WindowManager.shared.captureTarget(pid: pid),
                  let original = WindowManager.shared.frame(of: target) else { exit(2) }
            let manager = WindowManager.shared
            let visible = manager.screens().first { $0.frame.intersects(original) }?.visible ?? original
            var steps: [[String: Any]] = []; var completed = false; var success = true
            // Each new layout action must land the window where its geometry says
            // it should, not merely report success.
            let cases: [(ActionType, CGRect?)] = [
                (.snapWindowLeftThird, CGRect(x: visible.minX, y: visible.minY, width: visible.width/3, height: visible.height)),
                (.snapWindowCenterThird, CGRect(x: visible.minX + visible.width/3, y: visible.minY, width: visible.width/3, height: visible.height)),
                (.snapWindowRightThird, CGRect(x: visible.minX + visible.width*2/3, y: visible.minY, width: visible.width/3, height: visible.height)),
                (.snapWindowTopLeftSixth, CGRect(x: visible.minX, y: visible.minY, width: visible.width/3, height: visible.height/2)),
                (.snapWindowBottomRightSixth, CGRect(x: visible.minX + visible.width*2/3, y: visible.minY + visible.height/2, width: visible.width/3, height: visible.height/2)),
                (.snapWindowLeftTwoThirds, CGRect(x: visible.minX, y: visible.minY, width: visible.width*2/3, height: visible.height)),
                (.bringWindowToFront, nil),
                (.maximizeWindow, visible)]
            func restore() {
                manager.execute(.restoreWindowSize, target: target) { ok in
                    success = success && ok; completed = true
                    steps.append(["action": "Restore", "success": ok])
                }
            }
            func step(_ index: Int) {
                guard index < cases.count else { restore(); return }
                let (action, expected) = cases[index]
                manager.execute(action, target: target) { ok in
                    let actual = manager.frame(of: target)
                    // A nil expectation means the action is not a layout change,
                    // so there is no frame to compare; success alone decides.
                    let matched = expected.map { want in
                        actual.map { WindowGeometry.close($0, want) } ?? false
                    } ?? true
                    steps.append(["action": action.rawValue, "success": ok, "matchedExpected": matched,
                                  "frame": actual.map(NSStringFromRect) ?? "missing",
                                  "expected": expected.map(NSStringFromRect) ?? "-"])
                    success = success && ok && matched
                    if ok { step(index + 1) } else { restore() }
                }
            }
            step(0)
            let deadline = Date().addingTimeInterval(40)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            writeCheck(["success": success && completed, "steps": steps,
                        "original": NSStringFromRect(original), "visible": NSStringFromRect(visible)],
                       path: args[i + 2])
            exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-capture"), args.indices.contains(i + 1) {
            // Verifies the capture path against real pixels rather than against
            // the model. It takes an actual screen capture, encodes it, runs OCR
            // over it, and reports what came back — so a permission problem, a
            // ScreenCaptureKit failure or a broken encoder all surface here
            // instead of only when a user presses the key.
            _ = NSApplication.shared
            let reportPath = args[i + 1]
            let checkText = args.contains("--ocr")
            let checkScroll = args.contains("--scroll")

            // Write the permission state before anything can block. Without this
            // the check produces no file at all when ScreenCaptureKit waits on a
            // grant, which is indistinguishable from a crash.
            let granted = ScreenCaptureService.hasPermission
            Self.writeCheck(["permission": granted, "stage": "starting"], path: reportPath)
            guard granted else {
                Self.writeCheck([
                    "permission": false,
                    "success": false,
                    "error": "Screen Recording permission is not granted to this build, so the capture path cannot run."
                ], path: reportPath)
                exit(1)
            }

            Task { @MainActor in
                var report: [String: Any] = [
                    "permission": true,
                    "displays": NSScreen.screens.count
                ]
                do {
                    let displays = try await ScreenCaptureService.shared.shareableContentDisplays()
                    report["shareableDisplays"] = displays.count
                    guard let display = displays.first else { throw CaptureError.noDisplays }

                    let full = try await ScreenCaptureService.shared.captureFullscreen(display: display)
                    report["fullscreenPixels"] = ["w": full.image.width, "h": full.image.height]
                    report["fullscreenPoints"] = ["w": Double(full.globalRect.width),
                                                  "h": Double(full.globalRect.height)]
                    report["scale"] = Double(full.scale)
                    report["nonEmpty"] = full.image.width > 0 && full.image.height > 0

                    // Every format must encode, or the capture is unusable.
                    var encoded: [String: Int] = [:]
                    for format in CaptureFormat.allCases {
                        encoded[format.rawValue] = (try? ScreenCaptureService.shared.encode(full, format: format))?.count ?? -1
                    }
                    report["encodedBytes"] = encoded

                    // An area capture proves the rect-to-pixel path, which is the
                    // one that a Retina display gets wrong if the scale is mishandled.
                    let area = try await ScreenCaptureService.shared.captureArea(
                        CGRect(x: full.globalRect.minX + 40, y: full.globalRect.minY + 40,
                               width: 200, height: 120))
                    report["areaPixels"] = ["w": area.image.width, "h": area.image.height]
                    report["areaPoints"] = ["w": Double(area.globalRect.width), "h": Double(area.globalRect.height)]

                    if checkText {
                        let text = try await TextRecognitionService.recognize(full.image, keepsLineBreaks: true)
                        report["ocrCharacters"] = text.count
                        report["ocrSample"] = String(text.prefix(120))
                    }

                    if checkScroll {
                        // A stitcher that cannot find a shift on a synthetic pair
                        // would silently produce a one-frame result in real use.
                        let a = try await ScreenCaptureService.shared.captureArea(
                            CGRect(x: full.globalRect.minX, y: full.globalRect.minY, width: 300, height: 300))
                        let shift = ScrollingCaptureService.verticalShift(from: a.image, to: a.image)
                        report["scrollSelfShift"] = shift.map { Double($0) } as Any
                    }

                    // Optionally save the capture, so a human can look at what
                    // the pipeline actually produced rather than trusting the
                    // pixel counts.
                    if let outIndex = args.firstIndex(of: "--out"), args.indices.contains(outIndex + 1) {
                        let out = URL(fileURLWithPath: args[outIndex + 1])
                        try? ScreenCaptureService.shared.encode(full).write(to: out, options: .atomic)
                        report["savedTo"] = out.path
                    }

                    report["success"] = true
                } catch {
                    report["success"] = false
                    report["error"] = error.localizedDescription
                }
                Self.writeCheck(report, path: reportPath)
                exit((report["success"] as? Bool) == true ? 0 : 1)
            }
            AllOfMacOSApp.main()
        }
        if let i = args.firstIndex(of: "--aom-check-translucency"), args.indices.contains(i + 1) {
            // A behind-window blur is invisible unless the window itself is
            // non-opaque, so that property is what this verifies.
            let app = NSApplication.shared
            // The window has to exist before it can be inspected, so this runs
            // the real app loop for a moment rather than checking immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                var report: [[String: Any]] = []
                for window in app.windows where window.isVisible {
                    let hasEffect = Self.containsVisualEffect(window.contentView)
                    report.append([
                        "title": window.title,
                        "isOpaque": window.isOpaque,
                        "backgroundColorClear": (window.backgroundColor.alphaComponent) < 0.01,
                        "titlebarTransparent": window.titlebarAppearsTransparent,
                        "behindWindowEffect": hasEffect
                    ])
                }
                // Only the main window carries the material; menu-bar and HUD
                // panels are legitimately non-opaque without one. So the
                // requirement is: every window is non-opaque, and the main
                // window actually has the behind-window effect.
                let nonOpaque = !report.isEmpty && report.allSatisfy {
                    ($0["isOpaque"] as? Bool) == false && ($0["backgroundColorClear"] as? Bool) == true
                }
                let hasMainMaterial = report.contains {
                    ($0["behindWindowEffect"] as? Bool) == true && ($0["title"] as? String ?? "").isEmpty
                }
                let allTranslucent = nonOpaque && hasMainMaterial
                writeCheck(["success": allTranslucent, "windows": report], path: args[i + 1])
                exit(allTranslucent ? 0 : 1)
            }
            AllOfMacOSApp.main()
        }
        if let i = args.firstIndex(of: "--aom-check-mouse"), args.indices.contains(i + 1) {
            _ = NSApplication.shared
            // Drives the real ActionExecutor path, so the synthesis code under
            // test is the same code a trigger runs. NSScreen and CGEvent share
            // one coordinate space, so locations compare directly.
            let before = CGEvent(source: nil)?.location ?? .zero
            var steps: [[String: Any]] = []; var success = true
            func run(_ action: TriggerAction, _ label: String, _ check: @escaping () -> Bool) {
                var done = false; var ok = false
                ActionExecutor.executeActions([action]) { result in ok = result; done = true }
                let deadline = Date().addingTimeInterval(5)
                while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                // The event is posted asynchronously; give it a moment to land.
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                let verified = check()
                steps.append(["action": label, "reported": ok, "verified": verified])
                success = success && ok && verified
            }
            // A click is verified by watching for the event rather than by
            // relying on what happens to sit under the cursor: posting a real
            // click at an arbitrary point would activate whatever is there.
            //
            // The observer is a listen-only session tap, not an NSEvent global
            // monitor: a global monitor deliberately ignores events posted by
            // this process, so it would never see the very events under test.
            final class Counter { var clicks = 0; var scrolls = 0 }
            let counter = Counter()
            let tapMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: CGEventMask(tapMask),
                                        callback: { _, type, event, refcon in
                    if let refcon {
                        let counter = Unmanaged<Counter>.fromOpaque(refcon).takeUnretainedValue()
                        if type == .leftMouseDown { counter.clicks += 1 } else { counter.scrolls += 1 }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(counter).toOpaque())
            var tapSource: CFRunLoopSource?
            if let tap {
                tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            defer {
                if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
                if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes) }
            }
            var p = ActionParameters(); p.mouseX = 0.5; p.mouseY = 0.5
            run(TriggerAction(actionType: .moveMouseToPosition, parameters: p), "MoveMouseToPosition") {
                let now = CGEvent(source: nil)?.location ?? .zero
                return abs(now.x - before.x) > 1 || abs(now.y - before.y) > 1
            }
            run(TriggerAction(actionType: .saveMousePosition), "SaveMousePosition") { true }
            let saved = CGEvent(source: nil)?.location ?? .zero
            p = ActionParameters(); p.mouseX = 0.2; p.mouseY = 0.2
            run(TriggerAction(actionType: .moveMouseToPosition, parameters: p), "MoveMouseAway") {
                abs((CGEvent(source: nil)?.location ?? .zero).x - saved.x) > 1
            }
            run(TriggerAction(actionType: .restoreMousePosition), "RestoreMousePosition") {
                let now = CGEvent(source: nil)?.location ?? .zero
                return abs(now.x - saved.x) <= 1 && abs(now.y - saved.y) <= 1
            }
            p = ActionParameters(); p.scrollAmount = 3
            let beforeScroll = counter.scrolls
            run(TriggerAction(actionType: .scrollDown, parameters: p), "ScrollDown") { counter.scrolls > beforeScroll }
            let beforeClick = counter.clicks
            run(TriggerAction(actionType: .leftClick), "LeftClick") { counter.clicks > beforeClick }
            writeCheck(["success": success, "steps": steps, "start": NSStringFromPoint(before),
                        "end": NSStringFromPoint(CGEvent(source: nil)?.location ?? .zero)],
                       path: args[i + 1])
            exit(success ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-keyboard"), args.indices.contains(i + 2), let pid = Int32(args[i + 1]) {
            _ = NSApplication.shared
            guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.kyw.allofmacos.gesture-test",
                  let url = app.bundleURL else { exit(2) }
            let expected = "AOM 한글 😀 e\u{301} — typing test 1234567890"
            var activate = TriggerAction(actionType: .activateApplication)
            activate.parameters.applicationPath = url.path
            var type = TriggerAction(actionType: .typeText); type.parameters.text = expected
            let root = AXUIElementCreateApplication(pid)
            func containsExpectedText() -> Bool {
                var queue = [root]; var index = 0
                while index < queue.count && index < 100 {
                    let node = queue[index]; index += 1
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value) == .success,
                       value as? String == expected { return true }
                    if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                       let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
                }
                return false
            }
            ActionExecutor.executeActions([activate, type])
            let deadline = Date().addingTimeInterval(8)
            var success = false
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if containsExpectedText() { success = true; break }
            }
            writeCheck(["success": success, "activated": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                        "accessibility": AXIsProcessTrusted(), "unicodeTextMatched": success], path: args[i + 2])
            exit(success ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-adjust-volume"), args.indices.contains(i + 2), let delta = Double(args[i + 1]), abs(delta) <= 6 {
            _ = NSApplication.shared
            let before = AudioOutputService.currentVolume()
            var completed = false; var success = false
            AudioOutputService.shared.adjustVolume(percentagePoints: delta) { ok in success = ok; completed = true }
            let deadline = Date().addingTimeInterval(3)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            writeCheck(["success": success && completed, "deltaPercentagePoints": delta,
                        "before": before.map(Double.init) ?? -1, "after": AudioOutputService.currentVolume().map(Double.init) ?? -1], path: args[i + 2])
            exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-workflow"), args.indices.contains(i + 1) {
            _ = NSApplication.shared
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aom-workflow-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            func append(_ text: String) -> TriggerAction {
                var action = TriggerAction(actionType: .runShellScript)
                action.parameters.scriptContent = "printf " + text + " >> " + quoted
                return action
            }
            var pause = TriggerAction(actionType: .wait); pause.parameters.waitMs = 15
            var group = TriggerAction(actionType: .actionGroup)
            group.parameters.children = [append("a"), pause, append("b")]; group.parameters.repeatCount = 2
            var fail = TriggerAction(actionType: .runShellScript); fail.parameters.scriptContent = "exit 7"
            var recoverable = fail; recoverable.parameters.continueOnFailure = true
            var done = false; var success = false; var stopOnError = false
            var macro = Trigger(name: "Diagnostic macro", input: .namedTrigger("diagnostic-workflow"))
            macro.actions = [group]
            ActionExecutor.registerTriggers([macro])
            var invoke = TriggerAction(actionType: .triggerNamedTrigger); invoke.parameters.namedTriggerName = "diagnostic-workflow"
            ActionExecutor.executeActions([invoke, recoverable, append("end")], fromTrackpad: true) { ok in
                success = ok
                ActionExecutor.executeActions([fail, append("unexpected")], fromTrackpad: true) { ok in
                    stopOnError = !ok; done = true
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let matched = (try? String(contentsOf: file, encoding: .utf8)) == "ababend"
            writeCheck(["success": success && done && matched && stopOnError, "orderedGroupRepeatMatched": matched, "namedTriggerAwaited": matched && success,
                        "stopOnError": stopOnError, "continueOnError": success], path: args[i + 1])
            exit(success && done && matched && stopOnError ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-xpc"), args.indices.contains(i + 1) {
            _ = NSApplication.shared
            let cases: [(String, String, Double, Int32, Bool)] = [
                ("shell", "sleep 0.2; printf xpc-ok", 2, 0, false),
                ("applescript", "return \"xpc-apple-ok\"", 2, 0, false),
                ("shell", "exit 7", 2, 7, false),
                ("shell", "yes x | head -c 200000", 2, 0, false),
                ("shell", "sleep 30 & echo $!; wait", 0.2, 137, true),
                ("shell", "kill -KILL $PPID", 2, -1, false),
                ("shell", "printf recovered", 2, 0, false)]
            var reports: [[String: Any]] = []; var done = false; var ticks = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in ticks += 1 }
            func step(_ index: Int) {
                guard index < cases.count else { done = true; return }
                let (kind, source, timeout, expected, expectedTimeout) = cases[index]
                ScriptRunnerClient.shared.run(kind: kind, source: source, timeout: timeout) { code, output, timedOut in
                    var ok = code == expected && timedOut == expectedTimeout
                    if index == 0 { ok = ok && output == "xpc-ok" }
                    if index == 1 { ok = ok && output.trimmingCharacters(in: .whitespacesAndNewlines) == "xpc-apple-ok" }
                    if index == 3 { ok = ok && output.utf8.count == 65536 }
                    if index == 6 { ok = ok && output == "recovered" }
                    reports.append(["case": index, "success": ok, "exitCode": code, "timedOut": timedOut, "outputBytes": output.utf8.count])
                    step(index + 1)
                }
            }
            step(0)
            let deadline = Date().addingTimeInterval(35)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            timer.invalidate()
            let success = done && ticks >= 10 && reports.allSatisfy { $0["success"] as? Bool == true }
            writeCheck(["success": success, "mainRunLoopTicks": ticks, "cases": reports], path: args[i + 1])
            exit(success ? 0 : 1)
        }
        // A test host is not a second running copy: it must neither take the
        // input-owner lease nor defer to the installed app, or the suite can
        // never start while AOM is running.
        if !PresetManager.isUIPreview && !PresetManager.isRunningTests {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("allofmacos-input-owner.lock").path
            guard let lease = SingleInstanceLease(path: path) else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.kyw.allofmacos")
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate(options: [])
                return
            }
            instanceLease = lease
            // Older builds did not take the lease, so also honor a running older copy.
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kyw.allofmacos")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching }) {
                other.activate(options: []); return
            }
        } else { ActionExecutor.onActionExecuted = { _ in } }
        // Isolated capture-UI preview (no screen capture); see CaptureUIPreview.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { CaptureUIPreview.show() }
        }
        AllOfMacOSApp.main()
    }

    /// Whether a view tree contains a behind-window material, which is what
    /// actually blurs the desktop rather than the window's own contents.
    private static func containsVisualEffect(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if let effect = view as? NSVisualEffectView, effect.blendingMode == .behindWindow { return true }
        return view.subviews.contains { containsVisualEffect($0) }
    }

    private static func writeCheck(_ result: [String: Any], path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { fputs("Check report failed: \(error)\n", stderr); exit(2) }
    }
}

struct AllOfMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .accentColor(appState.accentColorChoice.color)
                .tint(appState.accentColorChoice.color)
                .frame(minWidth: 1040, minHeight: 650)
                .task {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 820)
        // aom:// links and opened files are handled by AppDelegate; without
        // this every link (Raycast, Shortcuts, Alfred) opened another window.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(before: .sidebar) {
                ForEach(AOMMainTab.allCases) { tab in
                    Button(tab.title) {
                        appState.selectedMainTab = tab
                        appDelegate.showMainWindow()
                    }
                    .keyboardShortcut(tab.shortcutKey, modifiers: .command)
                }
                Divider()
            }
            TriggerEditorCommands()
            WorkflowVariableCommands()
            CommandGroup(after: .newItem) {
                Button("Open Annotation Project…") { AnnotationEditorController.shared.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit All of MacOS") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Window("Workflow Variables", id: "workflow-variables") {
            WorkflowVariablesView()
                .scrollIndicators(.hidden)
        }
        .defaultSize(width: 620, height: 440)
        // aom:// links must not open this window (AppDelegate handles them).
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .scrollIndicators(.hidden)
                .environmentObject(appState)
                .accentColor(appState.accentColorChoice.color)
                .tint(appState.accentColorChoice.color)
        }
    }
}

// MARK: - Apple System Settings Components

struct AppleSettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
        }
    }
}

struct AppleSettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var showDivider: Bool = true
    @ViewBuilder let trailing: Trailing

    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil, showDivider: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Apple Control Center / Settings icon badge with soft depth
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor)
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showDivider {
                Divider()
                    .opacity(0.3)
                    .padding(.leading, 52)
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        SettingsHubView()
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("AOMAppearance") private var appearance: String = "system"
    @AppStorage("AOMHUDEnabled") private var hudEnabled = true
    @AppStorage("AOMHUDBackgroundOpacity") private var hudOpacity = 0.06

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                // Startup & Menu Bar
                AppleSettingsGroup("Startup & System") {
                    AppleSettingsRow(
                        icon: "power",
                        iconColor: .blue,
                        title: "Launch at Login",
                        subtitle: "Start All of MacOS automatically on system boot",
                        showDivider: true
                    ) {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    NSLog("[AOM] Failed to update login item: %@", error.localizedDescription)
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }

                    AppleSettingsRow(
                        icon: "menubar.rectangle",
                        iconColor: .purple,
                        title: "Show Menu Bar Icon",
                        subtitle: "Keep quick controls and status available in menu bar",
                        showDivider: false
                    ) {
                        Toggle("", isOn: $showMenuBarIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                // Appearance: Theme & Accent Color
                AppleSettingsGroup("Appearance") {
                    AppleSettingsRow(
                        icon: "circle.lefthalf.filled",
                        iconColor: .indigo,
                        title: "Interface Style",
                        subtitle: "Follow macOS or choose an appearance",
                        showDivider: true
                    ) {
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }

                    AppleSettingsRow(
                        icon: "paintpalette.fill",
                        iconColor: .pink,
                        title: "Highlight Color",
                        subtitle: "Personalize controls and active elements",
                        showDivider: false
                    ) {
                        HStack(spacing: 8) {
                            ForEach(AccentColorChoice.allCases) { choice in
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: appState.accentColorChoice == choice ? 2.5 : 0)
                                    )
                                    .shadow(color: appState.accentColorChoice == choice ? choice.color.opacity(0.5) : .clear, radius: 3)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            appState.accentColorChoice = choice
                                            UserDefaults.standard.set(choice.rawValue, forKey: "AOMAccentColor")
                                        }
                                    }
                            }
                        }
                    }
                }

                // Gesture HUD (User configurable transparency & test)
                AppleSettingsGroup("Gesture HUD Overlay") {
                    AppleSettingsRow(
                        icon: "sparkles",
                        iconColor: .cyan,
                        title: "Enable Gesture HUD",
                        subtitle: "Display translucent floating bezel when gestures fire",
                        showDivider: true
                    ) {
                        Toggle("", isOn: $hudEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    AppleSettingsRow(
                        icon: "slider.horizontal.3",
                        iconColor: .teal,
                        title: "Glass Tint Opacity",
                        subtitle: "Glass tint — lower is more transparent",
                        showDivider: false
                    ) {
                        HStack(spacing: 10) {
                            Slider(value: $hudOpacity, in: 0.0...0.25, step: 0.01)
                                .frame(width: 110)
                                .controlSize(.small)
                            Text("\(Int((hudOpacity * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Button("Test") {
                                GestureHUD.shared.show(title: "Three Finger Swipe Up", detail: "Mission Control")
                            }
                            .controlSize(.small)
                        }
                    }
                }

                // Presets & File
                AppleSettingsGroup("Preset & Storage") {
                    AppleSettingsRow(
                        icon: "arrow.up.arrow.down.square",
                        iconColor: .green,
                        title: "Preset Management",
                        subtitle: "Export or import configurations across Macs",
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Button("Export…") { exportPreset() }.controlSize(.small)
                            Button("Import…") { importPreset() }.controlSize(.small)
                        }
                    }

                    AppleSettingsRow(
                        icon: "folder",
                        iconColor: .gray,
                        title: "Preset File",
                        subtitle: PresetManager.presetFilePath,
                        showDivider: false
                    ) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(PresetManager.presetFilePath, inFileViewerRootedAtPath: "")
                        }
                        .controlSize(.small)
                    }
                }

                // Help & Reset
                AppleSettingsGroup("Maintenance") {
                    AppleSettingsRow(
                        icon: "questionmark.circle",
                        iconColor: .indigo,
                        title: "Tutorial",
                        subtitle: "Review touch gestures and setup guide",
                        showDivider: true
                    ) {
                        Button("Show Tutorial") { showTutorialFromSettings() }.controlSize(.small)
                    }

                    AppleSettingsRow(
                        icon: "arrow.counterclockwise",
                        iconColor: .red,
                        title: "Reset All Preferences",
                        subtitle: "Restores defaults without deleting custom triggers",
                        showDivider: false
                    ) {
                        Button("Reset to Defaults", role: .destructive) { resetAllSettings() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
    }

    private func showTutorialFromSettings() {
        let settingsWindow = NSApp.keyWindow
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
        settingsWindow?.close()
        appState.showTutorialRequested = true
    }

    private func exportPreset() { appState.presentPresetExport() }
    private func importPreset() { appState.presentPresetImport() }

    private func resetAllSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset All Settings?"
        alert.informativeText = "This will reset all preferences to defaults. Your triggers and actions will not be affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let keys = ["AOMGlobalEnabled", "AOMAccentColor", "AOMAppearance",
                        "AOMPressDragThreshold", "AOMTipTapMinRestTime",
                        "AOMSuppressMouseDuringDrawing", "launchAtLogin", "showMenuBarIcon", "AOMHasSeenTutorial", "AOMHUDBackgroundOpacity"]
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

struct BackupSettingsView: View {
    @State private var backupsEnabled = PresetManager.backupsEnabled
    @State private var customPath = UserDefaults.standard.string(forKey: "AOMBackupPath") ?? ""
    @State private var maxBackups = Double(PresetManager.maxBackups)
    @State private var backups: [(date: Date, size: Int64, url: URL)] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                AppleSettingsGroup("Automatic Backups") {
                    AppleSettingsRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .orange,
                        title: "Enable Automatic Backups",
                        subtitle: "Saves periodic snapshots of your gestures and profiles",
                        showDivider: true
                    ) {
                        Toggle("", isOn: $backupsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: backupsEnabled) { _, newValue in
                                PresetManager.backupsEnabled = newValue
                            }
                    }

                    AppleSettingsRow(
                        icon: "archivebox",
                        iconColor: .brown,
                        title: "Max Backups to Retain",
                        subtitle: "Older snapshots are automatically pruned",
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Slider(value: $maxBackups, in: 1...20, step: 1)
                                .frame(width: 120)
                                .controlSize(.small)
                                .onChange(of: maxBackups) { _, newValue in
                                    PresetManager.maxBackups = Int(newValue)
                                }
                            Text("\(Int(maxBackups))")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                        }
                    }

                    AppleSettingsRow(
                        icon: "folder",
                        iconColor: .yellow,
                        title: "Backup Directory",
                        subtitle: customPath.isEmpty ? "Default (~/.allofmacos_backups)" : customPath,
                        showDivider: false
                    ) {
                        HStack(spacing: 6) {
                            Button("Browse…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    customPath = url.path
                                    UserDefaults.standard.set(url.path, forKey: "AOMBackupPath")
                                }
                            }
                            .controlSize(.small)

                            if !customPath.isEmpty {
                                Button("Reset") {
                                    customPath = ""
                                    UserDefaults.standard.removeObject(forKey: "AOMBackupPath")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                AppleSettingsGroup("Existing Backups") {
                    if backups.isEmpty {
                        HStack {
                            Text("No backups found yet")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(Array(backups.enumerated()), id: \.offset) { index, backup in
                            AppleSettingsRow(
                                icon: "doc.badge.clock",
                                iconColor: .blue,
                                title: dateFormatter.string(from: backup.date),
                                subtitle: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file),
                                showDivider: index < backups.count - 1
                            ) {
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(backup.url.path, inFileViewerRootedAtPath: "")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(PresetManager.backupDirectory)
                    } label: {
                        Label("Open Backup Folder in Finder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .onAppear { backups = PresetManager.listBackups() }
    }
}

struct AboutSettingsView: View {
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.25), .purple.opacity(0.25), .pink.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .purple.opacity(0.20), radius: 10, y: 4)

                Image(systemName: "hand.point.up.braille.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 4) {
                Text("All of MacOS")
                    .font(.title2.bold())
                Text("Version \(appVersion)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Native Mac Gestures & Multi-Display Workspace Engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            AppleSettingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple-Native Experience")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Translucent glass interface and low-latency gesture engine")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 18))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
