import Foundation

enum TriggerCategory: String, CaseIterable, Identifiable, Codable {
    case all = "All"
    case trackpad = "Trackpad"
    case keyboard = "Keyboard"
    case normalMouse = "Normal Mouse"
    case drawings = "Drawings"
    case otherTriggers = "Other Triggers"

    var id: String { rawValue }
    static var inputCategories: [TriggerCategory] { allCases.filter { $0 != .all } }

    var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .trackpad: return "hand.point.up"
        case .keyboard: return "keyboard"
        case .normalMouse: return "computermouse.fill"
        case .drawings: return "hand.draw"
        case .otherTriggers: return "ellipsis.circle"
        }
    }
}

enum TrackpadGesture: String, CaseIterable, Identifiable, Codable {
    // 2-finger gestures
    case twoFingerSwipeUp = "2 Finger Swipe Up"
    case twoFingerSwipeDown = "2 Finger Swipe Down"
    case twoFingerSwipeLeft = "2 Finger Swipe Left"
    case twoFingerSwipeRight = "2 Finger Swipe Right"
    case twoFingerPinchIn = "2 Finger Pinch In"
    case twoFingerPinchOut = "2 Finger Pinch Out"
    case threeFingerPinchIn = "3 Finger Pinch In"
    case threeFingerPinchOut = "3 Finger Pinch Out"
    case fourFingerPinchIn = "4 Finger Pinch In"
    case fourFingerPinchOut = "4 Finger Pinch Out"
    case fiveFingerPinchIn = "5 Finger Pinch In"
    case fiveFingerPinchOut = "5 Finger Pinch Out"
    case twoFingerRotateLeft = "Rotate Left"
    case twoFingerRotateRight = "Rotate Right"
    case threeFingerRotateLeft = "3 Finger Rotate Left"
    case threeFingerRotateRight = "3 Finger Rotate Right"
    case fourFingerRotateLeft = "4 Finger Rotate Left"
    case fourFingerRotateRight = "4 Finger Rotate Right"
    case fiveFingerRotateLeft = "5 Finger Rotate Left"
    case fiveFingerRotateRight = "5 Finger Rotate Right"
    case oneFingerTap = "1 Finger Tap"
    case oneFingerDoubleTap = "1 Finger Double Tap"
    case twoFingerTap = "2 Finger Tap"
    case twoFingerDoubleTap = "2 Finger Double Tap"
    case twoFingerClick = "2 Finger Click"
    case twoFingerPressDragLeft = "2 Finger Press Drag Left"
    case twoFingerPressDragRight = "2 Finger Press Drag Right"

    // 3-finger gestures
    case threeFingerSwipeUp = "3 Finger Swipe Up"
    case threeFingerSwipeDown = "3 Finger Swipe Down"
    case threeFingerSwipeLeft = "3 Finger Swipe Left"
    case threeFingerSwipeRight = "3 Finger Swipe Right"
    case threeFingerTap = "3 Finger Tap"
    case threeFingerDoubleTap = "3 Finger Double Tap"
    case threeFingerClick = "3 Finger Click"

    // 4-finger gestures
    case fourFingerSwipeUp = "4 Finger Swipe Up"
    case fourFingerSwipeDown = "4 Finger Swipe Down"
    case fourFingerSwipeLeft = "4 Finger Swipe Left"
    case fourFingerSwipeRight = "4 Finger Swipe Right"
    case fourFingerTap = "4 Finger Tap"
    case fourFingerClick = "4 Finger Click"
    case fourFingerDoubleTap = "4 Finger Double Tap"
    case fiveFingerTap = "5 Finger Tap"
    case fiveFingerClick = "5 Finger Click"
    case fiveFingerSwipeUp = "5 Finger Swipe Up"
    case fiveFingerSwipeDown = "5 Finger Swipe Down"
    case fiveFingerSwipeLeft = "5 Finger Swipe Left"
    case fiveFingerSwipeRight = "5 Finger Swipe Right"

    // TipTap gestures (one finger rests, another taps)
    case tipTapLeft = "TipTap Left"
    case tipTapRight = "TipTap Right"
    case tipTapMiddle = "TipTap Middle"

    // Circular gestures
    case circleClockwise = "Circle Clockwise"
    case circleCounterClockwise = "Circle Counter-Clockwise"

    // Drawing gestures (press + draw shape)
    case drawTriangle = "Draw Triangle"

    // Edge slider gestures (1-finger press + slide along edge, fires repeatedly)
    case leftEdgeSlideUp = "Left Edge Slide Up"
    case leftEdgeSlideDown = "Left Edge Slide Down"
    case rightEdgeSlideUp = "Right Edge Slide Up"
    case rightEdgeSlideDown = "Right Edge Slide Down"

    // Position clicks (click at specific trackpad zones)
    case cornerClickTopLeft = "Corner Click Top Left"
    case cornerClickTopRight = "Corner Click Top Right"
    case cornerClickBottomLeft = "Corner Click Bottom Left"
    case cornerClickBottomRight = "Corner Click Bottom Right"
    case middleClickTop = "Middle Click Top"
    case middleClickBottom = "Middle Click Bottom"

    // Positional taps, matching BTT's 1-finger tap zones. These are taps, not
    // clicks: the finger rests and lifts without pressing.
    case oneFingerTapTopLeft = "1 Finger Tap Top Left"
    case oneFingerTapTopRight = "1 Finger Tap Top Right"
    case oneFingerTapTopMiddle = "1 Finger Tap Top Middle"
    case oneFingerTapBottomLeft = "1 Finger Tap Bottom Left"
    case oneFingerTapBottomRight = "1 Finger Tap Bottom Right"
    case oneFingerTapBottomMiddle = "1 Finger Tap Bottom Middle"
    case oneFingerTapLeftSideMiddle = "1 Finger Tap Left Side Middle"
    case oneFingerTapRightSideMiddle = "1 Finger Tap Right Side Middle"

    // Edge swipes in all four directions. The vertical left/right slides
    // already existed; these add the horizontal and top/bottom edges.
    case oneFingerSwipeUpOnLeftEdge = "1 Finger Swipe Up on Left Edge"
    case oneFingerSwipeDownOnLeftEdge = "1 Finger Swipe Down on Left Edge"
    case oneFingerSwipeUpOnRightEdge = "1 Finger Swipe Up on Right Edge"
    case oneFingerSwipeDownOnRightEdge = "1 Finger Swipe Down on Right Edge"
    case oneFingerSwipeLeftOnTopEdge = "1 Finger Swipe Left on Top Edge"
    case oneFingerSwipeRightOnTopEdge = "1 Finger Swipe Right on Top Edge"
    case oneFingerSwipeLeftOnBottomEdge = "1 Finger Swipe Left on Bottom Edge"
    case oneFingerSwipeRightOnBottomEdge = "1 Finger Swipe Right on Bottom Edge"
    // Force Touch. These need a pressure reading, so they only fire on
    // hardware that reports one; a trackpad without it never matches.
    case forceClick = "Single Finger Force Click"
    case forceClickTwoFinger = "2 Finger Force Click"
    case forceClickThreeFinger = "3 Finger Force Click"
    case cornerForceClickTopLeft = "Corner Force Click Top Left"
    case cornerForceClickTopRight = "Corner Force Click Top Right"
    case cornerForceClickBottomLeft = "Corner Force Click Bottom Left"
    case cornerForceClickBottomRight = "Corner Force Click Bottom Right"

    // MARK: BTT parity additions (names follow BTT's trigger list)

    // Touch Start: fires when the Nth finger has landed and settled.
    case oneFingerTouchStart = "1 Finger Touch Start"
    case twoFingerTouchStart = "2 Finger Touch Start"
    case threeFingerTouchStart = "3 Finger Touch Start"
    case fourFingerTouchStart = "4 Finger Touch Start"
    case fiveFingerTouchStart = "5 Finger Touch Start"
    // Long Touch: N fingers resting without moving for `Trigger.longTouchDurationMs`.
    case oneFingerLongTouch = "1 Finger Long Touch"
    case twoFingerLongTouch = "2 Finger Long Touch"
    case threeFingerLongTouch = "3 Finger Long Touch"
    case fourFingerLongTouch = "4 Finger Long Touch"
    case fiveFingerLongTouch = "5 Finger Long Touch"
    // Release Last Finger: fires when the final finger lifts.
    case releaseLastFingerAfter1 = "Release Last Finger After Previous Touch With 1 Finger"
    case releaseLastFingerAfter2 = "Release Last Finger After Previous Touch With 2 Fingers"
    case releaseLastFingerAfter3 = "Release Last Finger After Previous Touch With 3 Fingers"
    case releaseLastFingerAfter4 = "Release Last Finger After Previous Touch With 4 Fingers"
    case releaseLastFingerAfter5 = "Release Last Finger After Previous Touch With 5 Fingers"
    case releaseLastFingerRegardless = "Release Last Finger Regardless of How Many Were Touching Before"
    // Two fingers that begin on a pad edge and swipe inward.
    case twoFingerSwipeFromLeftEdge = "2 Finger Swipe From Left Edge"
    case twoFingerSwipeFromRightEdge = "2 Finger Swipe From Right Edge"
    case twoFingerSwipeFromTopEdge = "2 Finger Swipe From Top Edge"
    case twoFingerSwipeFromBottomEdge = "2 Finger Swipe From Bottom Edge"
    // 3-finger taps resolved by where the hand landed.
    case threeFingerTapTop = "3 Finger Tap Top"
    case threeFingerTapBottom = "3 Finger Tap Bottom"
    // Two-finger scrolling with a modifier held; REQUIRES a modifier.
    case scrollUp = "Scroll Up (modifier key needed)"
    case scrollDown = "Scroll Down (modifier key needed)"

    var id: String { rawValue }

    /// Finger count for Touch Start / Long Touch gestures.
    var touchHoldFingerCount: Int? {
        switch self {
        case .oneFingerTouchStart, .oneFingerLongTouch: return 1
        case .twoFingerTouchStart, .twoFingerLongTouch: return 2
        case .threeFingerTouchStart, .threeFingerLongTouch: return 3
        case .fourFingerTouchStart, .fourFingerLongTouch: return 4
        case .fiveFingerTouchStart, .fiveFingerLongTouch: return 5
        default: return nil
        }
    }
    var isTouchStart: Bool { [.oneFingerTouchStart, .twoFingerTouchStart, .threeFingerTouchStart, .fourFingerTouchStart, .fiveFingerTouchStart].contains(self) }
    var isLongTouch: Bool { [.oneFingerLongTouch, .twoFingerLongTouch, .threeFingerLongTouch, .fourFingerLongTouch, .fiveFingerLongTouch].contains(self) }
    static func touchStart(fingers: Int) -> TrackpadGesture? {
        [nil, .oneFingerTouchStart, .twoFingerTouchStart, .threeFingerTouchStart, .fourFingerTouchStart, .fiveFingerTouchStart][safe: fingers] ?? nil
    }
    static func longTouch(fingers: Int) -> TrackpadGesture? {
        [nil, .oneFingerLongTouch, .twoFingerLongTouch, .threeFingerLongTouch, .fourFingerLongTouch, .fiveFingerLongTouch][safe: fingers] ?? nil
    }
    static func releaseLast(after fingers: Int) -> TrackpadGesture? {
        [nil, .releaseLastFingerAfter1, .releaseLastFingerAfter2, .releaseLastFingerAfter3, .releaseLastFingerAfter4, .releaseLastFingerAfter5][safe: fingers] ?? nil
    }
    var isTrackpadScroll: Bool { self == .scrollUp || self == .scrollDown }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum MouseButton: String, CaseIterable, Identifiable, Codable {
    case button3 = "Middle Click (Button 3)"
    case button4 = "Button 4"
    case button5 = "Button 5"
    case button6 = "Button 6"
    case button7 = "Button 7"

    var id: String { rawValue }

    /// The CGEvent button number (0-indexed: button3 = 2, button4 = 3, etc.)
    var cgButtonNumber: Int64 {
        switch self {
        case .button3: return 2
        case .button4: return 3
        case .button5: return 4
        case .button6: return 5
        case .button7: return 6
        }
    }

    /// Create from a CGEvent mouse button number
    static func from(cgButton: Int64) -> MouseButton? {
        switch cgButton {
        case 2: return .button3
        case 3: return .button4
        case 4: return .button5
        case 5: return .button6
        case 6: return .button7
        default: return nil
        }
    }
}

/// What a Normal Mouse trigger reacts to (BTT §2.3).
enum MouseTriggerKind: String, CaseIterable, Identifiable, Codable {
    case click = "Click"
    case doubleClick = "Double Click"
    case tripleClick = "Triple Click"
    case longPress = "Long Press"
    case dragUp = "Drag Up"
    case dragDown = "Drag Down"
    case dragLeft = "Drag Left"
    case dragRight = "Drag Right"
    case scrollUp = "Scroll Up"
    case scrollDown = "Scroll Down"
    case scrollLeft = "Scroll Left"
    case scrollRight = "Scroll Right"

    var id: String { rawValue }
    var isScroll: Bool { [.scrollUp, .scrollDown, .scrollLeft, .scrollRight].contains(self) }
    var isDrag: Bool { [.dragUp, .dragDown, .dragLeft, .dragRight].contains(self) }
    /// Number of consecutive presses for the click family, otherwise nil.
    var clickCount: Int? {
        switch self {
        case .click: return 1
        case .doubleClick: return 2
        case .tripleClick: return 3
        default: return nil
        }
    }
}

/// A Normal Mouse trigger: a button (0 left, 1 right, 2 middle, 3+ extra
/// buttons, as in CGEvent's `mouseEventButtonNumber`) plus what it does.
/// Scroll triggers carry no button; it is normalized to 0.
struct MouseTriggerSpec: Codable, Hashable {
    static let maxButton = 31
    /// Buttons the picker offers: left, right, middle and extra buttons 4…16.
    static let pickerButtons = Array(0...15)

    var button: Int
    var kind: MouseTriggerKind

    init(button: Int, kind: MouseTriggerKind) {
        self.kind = kind
        self.button = kind.isScroll ? 0 : min(max(button, 0), Self.maxButton)
    }

    enum CodingKeys: String, CodingKey { case button, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(button: try c.decodeIfPresent(Int.self, forKey: .button) ?? 0,
                  kind: try c.decodeIfPresent(MouseTriggerKind.self, forKey: .kind) ?? .click)
    }

    static func buttonName(_ button: Int) -> String {
        switch button {
        case 0: return "Left"
        case 1: return "Right"
        case 2: return "Middle"
        default: return "Button \(button + 1)"
        }
    }

    var displayName: String {
        kind.isScroll ? kind.rawValue : "\(Self.buttonName(button)) \(kind.rawValue)"
    }

    /// Left and right buttons are the ones a user cannot afford to lose.
    var isPrimaryButton: Bool { !kind.isScroll && (button == 0 || button == 1) }

    /// Legacy `.mouseButton` equivalent, used to share one display/lookup path.
    init(legacy button: MouseButton) {
        self.init(button: Int(button.cgButtonNumber), kind: .click)
    }
}

/// MIDI 1.0 channel-voice messages a MIDI trigger can match. The raw value is
/// the status byte without its channel, as stored in
/// `SystemTriggerKind.midiMessage(status:)`; names follow BTT's MIDI list.
///
/// Filters: `channel` 0 = any; `number` (note, controller or program) -1 = any
/// and is ignored by the two messages that have none; the value range filters
/// the velocity, controller value, pressure or 14-bit bend, and is ignored by
/// Program Change, whose only data is the program number.
enum MIDIMessageType: Int, CaseIterable, Identifiable {
    case noteOff = 0x80, noteOn = 0x90, polyPressure = 0xA0, controlChange = 0xB0
    case programChange = 0xC0, channelPressure = 0xD0, pitchBend = 0xE0

    static let anyNumber = -1
    static let pitchBendCentre = 8192

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .noteOff: return "Note Off"
        case .noteOn: return "Note On"
        case .polyPressure: return "Poly Pressure"
        case .controlChange: return "Control Change"
        case .programChange: return "Program Change"
        case .channelPressure: return "Channel Pressure"
        case .pitchBend: return "Pitch Bend"
        }
    }
    /// Trigger names keep the short "CC" they always used.
    var shortTitle: String { self == .controlChange ? "CC" : title }
    /// What `number` selects, or nil when the message has no number.
    var numberTitle: String? {
        switch self {
        case .noteOff, .noteOn, .polyPressure: return "Note"
        case .controlChange: return "Controller"
        case .programChange: return "Program"
        case .channelPressure, .pitchBend: return nil
        }
    }
    var hasNumber: Bool { numberTitle != nil }
    /// What the value range filters, or nil when it is not a filter.
    var valueTitle: String? {
        switch self {
        case .noteOff, .noteOn: return "Velocity"
        case .polyPressure, .channelPressure: return "Pressure"
        case .controlChange: return "Value"
        case .programChange: return nil
        case .pitchBend: return "Bend"
        }
    }
    var valueRange: ClosedRange<Int> { self == .pitchBend ? 0...16383 : 0...127 }
    /// Messages that can drive a continuous value binding.
    var isContinuous: Bool { [.controlChange, .pitchBend, .channelPressure, .polyPressure].contains(self) }
    /// The decoded value as the AOM value 0…1.
    func normalized(_ value: Int) -> Double {
        Double(min(max(value, valueRange.lowerBound), valueRange.upperBound)) / Double(valueRange.upperBound)
    }
}

/// Creation-time validation that is independent of any UI.
enum TriggerValidation {
    /// MIDI filters and Force Touch stages, which the UI cannot always rule out.
    static func systemProblem(for kind: SystemTriggerKind) -> String? {
        switch kind {
        case .midiMessage(_, let status, let channel, let number, let low, let high):
            guard let type = MIDIMessageType(rawValue: status) else { return "Choose a MIDI message type." }
            if !(0...16).contains(channel) { return "MIDI channel must be 1–16, or any." }
            if let title = type.numberTitle, !(MIDIMessageType.anyNumber...127).contains(number) {
                return "\(title) must be 0–127, or any."
            }
            if let title = type.valueTitle, !(type.valueRange.contains(low) && type.valueRange.contains(high) && low <= high) {
                return "\(title) range must lie within \(type.valueRange.lowerBound)–\(type.valueRange.upperBound)."
            }
            return nil
        case .forceTouchStage(let stage):
            return (1...2).contains(stage) ? nil : "Force Touch stage must be 1 or 2."
        default: return nil
        }
    }

    /// A human-readable reason this trigger must not be created, or nil.
    ///
    /// Mirrors BTT's warning that binding the left (or right) button without a
    /// modifier would take the click away from the whole system: the same
    /// reasoning applies to scroll, which would hijack every scroll.
    static func problem(for input: TriggerInput, requiredModifiers: UInt?) -> String? {
        let held = (requiredModifiers ?? 0) & TriggerResolver.modifierMask
        if case .trackpadGesture(let gesture) = input, gesture.isTrackpadScroll, held == 0 {
            return "Scroll triggers need at least one required modifier key; otherwise every scroll would fire them."
        }
        guard case .mouse(let spec) = input else { return nil }
        if spec.isPrimaryButton && held == 0 {
            return "\(MouseTriggerSpec.buttonName(spec.button)) button triggers need at least one required modifier key; otherwise you would lose normal \(MouseTriggerSpec.buttonName(spec.button).lowercased()) clicks."
        }
        if spec.kind.isScroll && held == 0 {
            return "Scroll triggers need at least one required modifier key; otherwise every scroll would be intercepted."
        }
        return nil
    }
    static func problem(for trigger: Trigger) -> String? {
        if let problem = problem(for: trigger.input, requiredModifiers: trigger.requiredModifiers) { return problem }
        if case .systemEvent(let kind) = trigger.input, let problem = systemProblem(for: kind) { return problem }
        return trigger.valueBinding?.problem(for: trigger.input)
    }
}

struct KeyboardShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.function) { parts.append("fn") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    enum CodingKeys: String, CodingKey {
        case keyCode, modifierRawValue
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = Self.normalized(modifiers, keyCode: keyCode)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let raw = try container.decode(UInt.self, forKey: .modifierRawValue)
        modifiers = Self.normalized(NSEvent.ModifierFlags(rawValue: raw), keyCode: keyCode)
    }

    private static func normalized(_ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent.ModifierFlags {
        var result = flags.intersection([.command, .option, .control, .shift, .function])
        // macOS marks F-key events as secondary-Fn even without a physical Fn press.
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if functionKeys.contains(keyCode) { result.remove(.function) }
        return result
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifierRawValue)
    }
}

import AppKit

func keyCodeToString(_ keyCode: UInt16) -> String {
    let mapping: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "⇞",
        117: "⌦", 118: "F4", 119: "End", 120: "F2", 121: "⇟",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    return mapping[keyCode] ?? "Key\(keyCode)"
}

extension NSEvent.ModifierFlags: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
