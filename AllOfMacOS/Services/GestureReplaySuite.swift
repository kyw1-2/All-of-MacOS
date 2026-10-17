import AppKit

/// Runs inside the installed executable with --aom-self-test <report.json>.
/// No hardware monitor is registered and no action is posted to another app.
enum GestureReplaySuite {
    static func rawFrame(_ points: [TouchPoint], state: Int32 = 4) -> Data {
        var data = Data(count: points.count * TouchFrameDecoder.stride)
        data.withUnsafeMutableBytes { bytes in
            for (i, p) in points.enumerated() {
                let base = i * TouchFrameDecoder.stride
                bytes.storeBytes(of: Int32(1), toByteOffset: base, as: Int32.self)
                bytes.storeBytes(of: Int32(p.id), toByteOffset: base + 16, as: Int32.self)
                bytes.storeBytes(of: state, toByteOffset: base + 20, as: Int32.self)
                bytes.storeBytes(of: p.x, toByteOffset: base + 32, as: Float.self)
                bytes.storeBytes(of: p.y, toByteOffset: base + 36, as: Float.self)
                bytes.storeBytes(of: Float(8), toByteOffset: base + 60, as: Float.self)
                bytes.storeBytes(of: p.pressure, toByteOffset: base + 64, as: Float.self)
            }
        }
        return data
    }

    static func run() -> [String: Any] {
        let defaults = UserDefaults.standard
        let keys = ["AOMGlobalEnabled", "AOMTipTapMinRestTime", "AOMPressDragThreshold",
                    "AOMForcePressEnabled", "AOMForcePressThreshold"] +
            TrackpadGesture.allCases.map { "AOMSwipeMinVelocity_\($0.rawValue)" }
        var saved: [String: Any] = [:]
        for key in keys { saved[key] = defaults.object(forKey: key) }
        let previousHook = ActionExecutor.onActionExecuted
        defaults.set(true, forKey: "AOMGlobalEnabled")
        defaults.set(0.12, forKey: "AOMTipTapMinRestTime")
        defaults.set(300, forKey: "AOMPressDragThreshold")
        // Force Click is opt-in in production; the harness enables it so the
        // force gestures are exercised, with a threshold the synthetic frames
        // (pressure 0.8) clear.
        defaults.set(true, forKey: "AOMForcePressEnabled")
        defaults.set(0.5, forKey: "AOMForcePressThreshold")
        for gesture in TrackpadGesture.allCases { defaults.set(200, forKey: "AOMSwipeMinVelocity_\(gesture.rawValue)") }
        defer {
            ActionExecutor.onActionExecuted = previousHook
            for key in keys { defaults.set(saved[key], forKey: key) }
        }
        var cases: [[String: Any]] = []
        for gesture in TrackpadGesture.allCases {
            let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "replay" })
            var trigger = Trigger(name: "Replay", input: .trackpadGesture(gesture))
            var parameters = ActionParameters(); parameters.text = gesture.rawValue
            trigger.actions = [TriggerAction(actionType: .typeText, parameters: parameters)]
            if gesture.isTrackpadScroll { trigger.requiredModifiers = NSEvent.ModifierFlags.option.rawValue }
            monitor.registerTriggers([trigger])
            var fired: [String] = []
            ActionExecutor.onActionExecuted = { fired.append($0.parameters.text ?? "wrong action") }
            func point(_ id: Int, _ x: Float, _ y: Float, pressure: Float = 0) -> TouchPoint {
                TouchPoint(id: id, x: x, y: y, size: 0.4, pressure: pressure)
            }
            func frame(_ points: [TouchPoint], _ time: Double, state: Int32 = 4, pressed: Bool = false) {
                if pressed { monitor.processTouchFrame(points, count: points.count, timestamp: time, pressedButtons: 1) }
                else {
                    var bytes = rawFrame(points, state: state)
                    bytes.withUnsafeMutableBytes { buffer in
                        monitor.handleMultitouchFrame(rawTouches: buffer.baseAddress, numTouches: points.count, timestamp: time)
                    }
                }
            }
            switch gesture {
            case .oneFingerTapTopLeft, .oneFingerTapTopRight, .oneFingerTapTopMiddle,
                 .oneFingerTapBottomLeft, .oneFingerTapBottomRight, .oneFingerTapBottomMiddle,
                 .oneFingerTapLeftSideMiddle, .oneFingerTapRightSideMiddle:
                // The tap is judged from where the finger rested, so the replay
                // has to place it in the matching zone.
                let (tx, ty): (Float, Float)
                switch gesture {
                case .oneFingerTapTopLeft: (tx, ty) = (0.05, 0.95)
                case .oneFingerTapTopRight: (tx, ty) = (0.95, 0.95)
                case .oneFingerTapTopMiddle: (tx, ty) = (0.5, 0.95)
                case .oneFingerTapBottomLeft: (tx, ty) = (0.05, 0.05)
                case .oneFingerTapBottomRight: (tx, ty) = (0.95, 0.05)
                case .oneFingerTapBottomMiddle: (tx, ty) = (0.5, 0.05)
                case .oneFingerTapLeftSideMiddle: (tx, ty) = (0.05, 0.5)
                default: (tx, ty) = (0.95, 0.5)
                }
                frame([point(1, tx, ty)], 1); frame([point(1, tx, ty)], 1.1, state: 7)
            case .oneFingerSwipeUpOnLeftEdge, .oneFingerSwipeDownOnLeftEdge,
                 .oneFingerSwipeUpOnRightEdge, .oneFingerSwipeDownOnRightEdge,
                 .oneFingerSwipeLeftOnTopEdge, .oneFingerSwipeRightOnTopEdge,
                 .oneFingerSwipeLeftOnBottomEdge, .oneFingerSwipeRightOnBottomEdge:
                let left = gesture.rawValue.contains("Left Edge")
                let right = gesture.rawValue.contains("Right Edge")
                let top = gesture.rawValue.contains("Top Edge")
                let up = gesture.rawValue.contains("Up on")
                let goingLeft = gesture.rawValue.contains("Swipe Left")
                let sx: Float = left ? 0.03 : right ? 0.97 : 0.5
                let sy: Float = top ? 0.97 : (left || right) ? 0.5 : 0.03
                let dx: Float = (left || right) ? 0 : (goingLeft ? -0.25 : 0.25)
                let dy: Float = (left || right) ? (up ? 0.25 : -0.25) : 0
                frame([point(1, sx, sy)], 1)
                frame([point(1, sx + dx, sy + dy)], 1.15)
            case .oneFingerTap, .oneFingerDoubleTap,
                 .twoFingerTap, .twoFingerDoubleTap, .threeFingerTap, .threeFingerDoubleTap,
                 .fourFingerTap, .fourFingerDoubleTap, .fiveFingerTap:
                let n: Int
                switch gesture {
                case .oneFingerTap, .oneFingerDoubleTap: n = 1
                case .threeFingerTap, .threeFingerDoubleTap: n = 3
                case .fourFingerTap, .fourFingerDoubleTap: n = 4
                case .fiveFingerTap: n = 5
                default: n = 2
                }
                let points = (0..<n).map { point($0, 0.2 + Float($0) * 0.12, 0.5) }
                frame(points, 1); frame(points, 1.1, state: 7)
                if [.oneFingerDoubleTap, .twoFingerDoubleTap, .threeFingerDoubleTap, .fourFingerDoubleTap].contains(gesture) {
                    frame(points, 1.2); frame(points, 1.3, state: 7)
                }
            case .twoFingerSwipeUp, .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight,
                 .threeFingerSwipeUp, .threeFingerSwipeDown, .threeFingerSwipeLeft, .threeFingerSwipeRight,
                 .fourFingerSwipeUp, .fourFingerSwipeDown, .fourFingerSwipeLeft, .fourFingerSwipeRight,
                 .fiveFingerSwipeUp, .fiveFingerSwipeDown, .fiveFingerSwipeLeft, .fiveFingerSwipeRight:
                let n = gesture.rawValue.hasPrefix("5") ? 5 : gesture.rawValue.hasPrefix("4") ? 4 : gesture.rawValue.hasPrefix("3") ? 3 : 2
                let dx: Float = gesture.rawValue.hasSuffix("Left") ? -0.12 : gesture.rawValue.hasSuffix("Right") ? 0.12 : 0
                let dy: Float = gesture.rawValue.hasSuffix("Down") ? -0.12 : gesture.rawValue.hasSuffix("Up") ? 0.12 : 0
                let points = (0..<n).map { point($0, 0.2 + Float($0) * 0.16, 0.5) }
                frame(points, 1)
                let moved = points.map { point($0.id, $0.x + dx, $0.y + dy) }
                frame(moved, 1.1); frame(moved, 1.2, state: 7)
            case .twoFingerPinchIn, .twoFingerPinchOut, .threeFingerPinchIn, .threeFingerPinchOut,
                 .fourFingerPinchIn, .fourFingerPinchOut, .fiveFingerPinchIn, .fiveFingerPinchOut:
                let n = Int(gesture.rawValue.prefix(1)) ?? 2
                // Fingers start on a circle, then the radius changes.
                let start: Float = 0.15
                let isIn = gesture.rawValue.contains("In")
                let end: Float = isIn ? 0.07 : 0.30
                func ring(_ radius: Float) -> [TouchPoint] {
                    (0..<n).map { i in
                        let a = Float(i) / Float(n) * 2 * .pi - .pi / 2
                        return point(i + 1, 0.5 + radius * cos(a), 0.5 + radius * sin(a))
                    }
                }
                frame(ring(start), 1)
                frame(ring(end), 1.1)
            case .twoFingerRotateLeft, .twoFingerRotateRight, .threeFingerRotateLeft, .threeFingerRotateRight,
                 .fourFingerRotateLeft, .fourFingerRotateRight, .fiveFingerRotateLeft, .fiveFingerRotateRight:
                let n = Int(gesture.rawValue.prefix(1)) ?? 2
                let angle: Float = gesture.rawValue.contains("Left") ? 0.4 : -0.4
                func ring(_ rotation: Float) -> [TouchPoint] {
                    (0..<n).map { i in
                        let a = Float(i) / Float(n) * 2 * .pi - .pi / 2 + rotation
                        return point(i + 1, 0.5 + 0.15 * cos(a), 0.5 + 0.15 * sin(a))
                    }
                }
                frame(ring(0), 1)
                frame(ring(angle), 1.1)
            case .tipTapLeft, .tipTapRight, .tipTapMiddle:
                let rest = gesture == .tipTapMiddle ? [point(1, 0.3, 0.5), point(2, 0.7, 0.5)] : [point(1, 0.5, 0.5)]
                let x: Float = gesture == .tipTapLeft ? 0.25 : gesture == .tipTapRight ? 0.75 : 0.5
                frame(rest, 1); frame(rest + [point(3, x, 0.5)], 1.2); frame(rest, 1.25)
            case .twoFingerClick, .threeFingerClick, .fourFingerClick, .fiveFingerClick,
                 .twoFingerPressDragLeft, .twoFingerPressDragRight:
                let n = gesture == .fiveFingerClick ? 5 : gesture == .fourFingerClick ? 4 : gesture == .threeFingerClick ? 3 : 2
                frame((0..<n).map { point($0, 0.3 + Float($0) * 0.15, 0.5) }, 1)
                monitor.handleMousePress()
                if gesture == .twoFingerPressDragLeft || gesture == .twoFingerPressDragRight {
                    monitor.processMouseDrag(deltaX: gesture == .twoFingerPressDragLeft ? -400 : 400)
                }
                monitor.handleMouseRelease()
            case .cornerClickTopLeft, .cornerClickTopRight, .cornerClickBottomLeft, .cornerClickBottomRight,
                 .middleClickTop, .middleClickBottom:
                let x: Float = gesture.rawValue.contains("Left") ? 0.05 : gesture.rawValue.contains("Right") ? 0.95 : 0.5
                let y: Float = gesture.rawValue.contains("Top") ? 0.95 : 0.05
                frame([point(1, x, y)], 1); monitor.handleMousePress(); monitor.handleMouseRelease()
            case .leftEdgeSlideUp, .leftEdgeSlideDown, .rightEdgeSlideUp, .rightEdgeSlideDown:
                let x: Float = gesture.rawValue.hasPrefix("Left") ? 0.05 : 0.95
                let dy: Float = gesture.rawValue.hasSuffix("Up") ? 0.06 : -0.06
                frame([point(1, x, 0.5)], 1, pressed: true)
                frame([point(1, x, 0.5 + dy)], 1.1, pressed: true)
            case .circleClockwise, .circleCounterClockwise:
                for i in 0...72 {
                    let angle = Float(i) * 2 * .pi / 72 * (gesture == .circleClockwise ? -1 : 1)
                    frame([point(1, 0.5 + 0.05 * cos(angle), 0.5 + 0.05 * sin(angle))], 1 + Double(i) / 60, pressed: true)
                }
            case .forceClick, .forceClickTwoFinger, .forceClickThreeFinger,
                 .cornerForceClickTopLeft, .cornerForceClickTopRight,
                 .cornerForceClickBottomLeft, .cornerForceClickBottomRight:
                // A force press is an ordinary contact whose pressure crosses
                // the threshold before the click arrives from the mouse tap.
                let fingers = gesture == .forceClickThreeFinger ? 3 : gesture == .forceClickTwoFinger ? 2 : 1
                let corner = gesture.rawValue.contains("Corner")
                let x: Float = corner ? (gesture.rawValue.contains("Left") ? 0.05 : 0.95) : 0.5
                let y: Float = corner ? (gesture.rawValue.contains("Top") ? 0.95 : 0.05) : 0.5
                let pressed = (0..<fingers).map { point($0, x, y, pressure: 0.8) }
                frame(pressed, 1)
                monitor.handleMousePress(); monitor.handleMouseRelease()
            case .oneFingerTouchStart, .twoFingerTouchStart, .threeFingerTouchStart, .fourFingerTouchStart, .fiveFingerTouchStart:
                let n = gesture.touchHoldFingerCount ?? 1
                let points = (0..<n).map { point($0, 0.2 + Float($0) * 0.12, 0.5) }
                frame(points, 1); frame(points, 1.03); frame(points, 1.08); frame(points, 1.2)
            case .oneFingerLongTouch, .twoFingerLongTouch, .threeFingerLongTouch, .fourFingerLongTouch, .fiveFingerLongTouch:
                let n = gesture.touchHoldFingerCount ?? 1
                let points = (0..<n).map { point($0, 0.2 + Float($0) * 0.12, 0.5) }
                for i in 0...7 { frame(points, 1 + Double(i) * 0.1) } // rests 0.7 s, default threshold 0.5 s
            case .releaseLastFingerAfter1, .releaseLastFingerAfter2, .releaseLastFingerAfter3,
                 .releaseLastFingerAfter4, .releaseLastFingerAfter5, .releaseLastFingerRegardless:
                let n = gesture == .releaseLastFingerRegardless ? 2 : (gesture.rawValue.first(where: \.isNumber).flatMap { Int(String($0)) } ?? 1)
                let points = (0..<n).map { point($0, 0.2 + Float($0) * 0.12, 0.5) }
                frame(points, 1); frame(Array(points.prefix(max(0, n - 1))), 1.1); frame(points, 1.15, state: 7)
                if n > 1 { frame([], 1.2) } // the final finger lifting is the release
            case .twoFingerSwipeFromLeftEdge, .twoFingerSwipeFromRightEdge, .twoFingerSwipeFromTopEdge, .twoFingerSwipeFromBottomEdge:
                let left = gesture == .twoFingerSwipeFromLeftEdge, right = gesture == .twoFingerSwipeFromRightEdge
                let top = gesture == .twoFingerSwipeFromTopEdge
                let start: [TouchPoint] = left ? [point(1, 0.03, 0.45), point(2, 0.05, 0.55)]
                    : right ? [point(1, 0.97, 0.45), point(2, 0.95, 0.55)]
                    : top ? [point(1, 0.45, 0.96), point(2, 0.55, 0.94)]
                    : [point(1, 0.45, 0.04), point(2, 0.55, 0.06)]
                let dx: Float = left ? 0.2 : right ? -0.2 : 0
                let dy: Float = top ? -0.2 : (left || right) ? 0 : 0.2
                frame(start, 1)
                let moved = start.map { point($0.id, $0.x + dx, $0.y + dy) }
                frame(moved, 1.1); frame(moved, 1.2, state: 7)
            case .threeFingerTapTop, .threeFingerTapBottom:
                let y: Float = gesture == .threeFingerTapTop ? 0.85 : 0.15
                let points = (0..<3).map { point($0, 0.3 + Float($0) * 0.15, y) }
                frame(points, 1); frame(points, 1.1, state: 7)
            case .scrollUp, .scrollDown:
                // Scrolling arrives as scroll events with the modifier held, not as contacts.
                monitor.modifierFlagsProvider = { NSEvent.ModifierFlags.option.rawValue }
                let dy: CGFloat = gesture == .scrollUp ? 25 : -25
                monitor.processScroll(deltaX: 0, deltaY: dy, phase: .changed, timestamp: 1)
                monitor.processScroll(deltaX: 0, deltaY: dy, phase: .changed, timestamp: 1.05)
            case .drawTriangle:
                let corners: [(Float, Float)] = [(0.3, 0.3), (0.7, 0.3), (0.5, 0.65), (0.3, 0.3)]
                for side in 0..<3 { for i in 0...12 {
                    let t = Float(i) / 12
                    let a = corners[side], b = corners[side + 1]
                    frame([point(1, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)],
                          1 + Double(side * 13 + i) / 60, pressed: true)
                } }
            }
            // Recognition is delivered with DispatchQueue.main.async, so the
            // drain has to be bounded by the work actually arriving rather than
            // by a fixed sleep. A fixed 25 ms passed alone and failed under a
            // loaded suite, which is exactly the kind of flake that hides a
            // real regression later.
            let deadline = Date().addingTimeInterval(1.0)
            while fired.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let pass = fired == [gesture.rawValue]
            cases.append(["gesture": gesture.rawValue, "pass": pass, "actions": fired])
            monitor.unregisterAll()
        }
        return ["kind": "synthetic raw-contact replay; no hardware gestures generated",
                "passed": cases.allSatisfy { $0["pass"] as? Bool == true },
                "count": cases.count, "cases": cases]
    }
}
