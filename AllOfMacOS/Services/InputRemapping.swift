import AppKit
import Carbon

// BetterTouchTool-style keyboard remapping, a Hyper key and wheel-only scroll
// reversal. Remaps go through `hidutil` (Apple TN2450): they work at the HID
// level, so Caps Lock stops toggling and secure text fields see them too. AOM
// only ever adds and removes the pairs it owns, and removes them when it quits.

/// A key on the HID keyboard page (usage page 7) that AOM offers for remapping.
struct HIDKey: Identifiable, Hashable {
    let usage: UInt32
    let title: String
    var id: UInt32 { usage }

    static let catalog: [HIDKey] = [
        HIDKey(usage: 0x39, title: "Caps Lock"), HIDKey(usage: 0x29, title: "Escape"),
        HIDKey(usage: 0x2B, title: "Tab"), HIDKey(usage: 0x28, title: "Return"),
        HIDKey(usage: 0x2A, title: "Delete"), HIDKey(usage: 0x4C, title: "Forward Delete"),
        HIDKey(usage: 0x35, title: "` Grave Accent"), HIDKey(usage: 0x64, title: "§ ISO Section"),
        HIDKey(usage: 0xE0, title: "Left Control"), HIDKey(usage: 0xE1, title: "Left Shift"),
        HIDKey(usage: 0xE2, title: "Left Option"), HIDKey(usage: 0xE3, title: "Left Command"),
        HIDKey(usage: 0xE4, title: "Right Control"), HIDKey(usage: 0xE5, title: "Right Shift"),
        HIDKey(usage: 0xE6, title: "Right Option"), HIDKey(usage: 0xE7, title: "Right Command"),
        HIDKey(usage: 0x90, title: "한/영 (Lang 1)"), HIDKey(usage: 0x91, title: "한자 (Lang 2)"),
        HIDKey(usage: 0x65, title: "Menu"),
        HIDKey(usage: 0x4A, title: "Home"), HIDKey(usage: 0x4D, title: "End"),
        HIDKey(usage: 0x4B, title: "Page Up"), HIDKey(usage: 0x4E, title: "Page Down"),
        HIDKey(usage: 0x68, title: "F13"), HIDKey(usage: 0x69, title: "F14"), HIDKey(usage: 0x6A, title: "F15"),
        HIDKey(usage: 0x6B, title: "F16"), HIDKey(usage: 0x6C, title: "F17"), HIDKey(usage: 0x6D, title: "F18"),
        HIDKey(usage: 0x6E, title: "F19"), HIDKey(usage: 0x6F, title: "F20")
    ]

    /// Keys that make sense as the physical Hyper key.
    static let hyperSources: [HIDKey] = catalog.filter { [0x39, 0xE4, 0xE6, 0xE7, 0x35, 0x64, 0x90].contains($0.usage) }

    static func title(_ usage: UInt32) -> String {
        catalog.first { $0.usage == usage }?.title ?? String(format: "Key 0x%02X", usage)
    }
}

struct KeyRemap: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: UInt32
    var to: UInt32
}

/// One UserKeyMapping entry; both values are 0x7_0000_0000 | usage.
struct HIDMappingPair: Codable, Hashable {
    var src: UInt64
    var dst: UInt64
}

enum HIDKeyMapping {
    static let keyboardPage: UInt64 = 0x7_0000_0000
    static let f18: UInt32 = 0x6D

    static func pair(_ from: UInt32, _ to: UInt32) -> HIDMappingPair {
        HIDMappingPair(src: keyboardPage | UInt64(from), dst: keyboardPage | UInt64(to))
    }

    /// The pairs AOM wants: the user's table plus source → F18 for the Hyper
    /// key. The Hyper key wins its source, the last remap wins any other
    /// source, and identity mappings are dropped.
    static func desired(remaps: [KeyRemap], hyperSource: UInt32?) -> [HIDMappingPair] {
        var bySource: [UInt32: UInt32] = [:]
        var order: [UInt32] = []
        for remap in remaps where remap.from != remap.to {
            if bySource[remap.from] == nil { order.append(remap.from) }
            bySource[remap.from] = remap.to
        }
        if let hyperSource {
            if bySource[hyperSource] == nil { order.append(hyperSource) }
            bySource[hyperSource] = f18
        }
        return order.compactMap { from in bySource[from].map { pair(from, $0) } }
    }

    /// Everything already mapped, minus what AOM applied earlier and any
    /// other entry for a source AOM now maps, plus AOM's pairs. Entries other
    /// tools made for other keys are kept.
    static func merged(current: [HIDMappingPair], previouslyOwned: [HIDMappingPair], desired: [HIDMappingPair]) -> [HIDMappingPair] {
        let owned = Set(previouslyOwned)
        let sources = Set(desired.map(\.src))
        var seen = Set<HIDMappingPair>()
        let kept = current.filter { !owned.contains($0) && !sources.contains($0.src) && seen.insert($0).inserted }
        return kept + desired
    }

    /// Distinct pairs in `hidutil property --get UserKeyMapping` output, which
    /// lists one plist-style array per HID service.
    static func parse(_ output: String) -> [HIDMappingPair] {
        var result: [HIDMappingPair] = []
        var seen = Set<HIDMappingPair>()
        for block in output.components(separatedBy: "{").dropFirst() {
            let body = block.components(separatedBy: "}").first ?? ""
            func value(_ key: String) -> UInt64? {
                guard let range = body.range(of: key) else { return nil }
                let digits = body[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
                return UInt64(digits)
            }
            guard let src = value("HIDKeyboardModifierMappingSrc"), let dst = value("HIDKeyboardModifierMappingDst") else { continue }
            let pair = HIDMappingPair(src: src, dst: dst)
            if seen.insert(pair).inserted { result.append(pair) }
        }
        return result
    }

    static func json(_ pairs: [HIDMappingPair]) -> String {
        let entries = pairs.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }
}

enum InputRemapSettings {
    private static let d = UserDefaults.standard
    static let changed = Notification.Name("AOMInputRemapSettingsChanged")

    static var remaps: [KeyRemap] {
        get {
            guard let data = d.data(forKey: "AOMKeyRemaps"), let list = try? JSONDecoder().decode([KeyRemap].self, from: data) else { return [] }
            return Array(list.prefix(32))
        }
        set { d.set(try? JSONEncoder().encode(Array(newValue.prefix(32))), forKey: "AOMKeyRemaps") }
    }
    static var hyperEnabled: Bool {
        get { d.bool(forKey: "AOMHyperKeyEnabled") }
        set { d.set(newValue, forKey: "AOMHyperKeyEnabled") }
    }
    static var hyperSource: UInt32 {
        get { (d.object(forKey: "AOMHyperKeySource") as? NSNumber)?.uint32Value ?? 0x39 }
        set { d.set(NSNumber(value: newValue), forKey: "AOMHyperKeySource") }
    }
    /// Tapping the Hyper key alone sends Escape.
    static var hyperTapEscape: Bool {
        get { d.object(forKey: "AOMHyperKeyTapEscape") as? Bool ?? true }
        set { d.set(newValue, forKey: "AOMHyperKeyTapEscape") }
    }
    static var reverseMouseWheel: Bool {
        get { d.bool(forKey: "AOMReverseMouseWheel") }
        set { d.set(newValue, forKey: "AOMReverseMouseWheel") }
    }
    /// Exactly what AOM last applied, so it can take only its own pairs back.
    static var ownedPairs: [HIDMappingPair] {
        get {
            guard let data = d.data(forKey: "AOMKeyRemapOwnedPairs") else { return [] }
            return (try? JSONDecoder().decode([HIDMappingPair].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "AOMKeyRemapOwnedPairs") }
    }
}

/// Applies the settings: hidutil pairs, the Hyper key tap and the wheel tap.
final class InputRemapService {
    static let shared = InputRemapService()
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.key-remap")
    private(set) var lastError: String?

    /// Launch, settings change, wake. Does nothing at all for a user who never
    /// turned remapping on and has nothing left over from an earlier run.
    /// Isolated previews and tests never touch the real HID mapping or taps.
    func apply() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        let desired = HIDKeyMapping.desired(remaps: InputRemapSettings.remaps,
                                            hyperSource: InputRemapSettings.hyperEnabled ? InputRemapSettings.hyperSource : nil)
        let owned = InputRemapSettings.ownedPairs
        let hyper = InputRemapSettings.hyperEnabled
        let escape = InputRemapSettings.hyperTapEscape
        let wheel = InputRemapSettings.reverseMouseWheel
        DispatchQueue.main.async {
            HyperKeyTap.shared.setEnabled(hyper, tapEscape: escape)
            ScrollWheelReverser.shared.setEnabled(wheel)
        }
        guard !desired.isEmpty || !owned.isEmpty else { return }
        queue.async { self.write(desired: desired, owned: owned) }
    }

    /// Quit: give back exactly the pairs AOM owns; other mappings stay.
    func removeOwnedMappingsNow() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        let owned = InputRemapSettings.ownedPairs
        HyperKeyTap.shared.setEnabled(false, tapEscape: false)
        ScrollWheelReverser.shared.setEnabled(false)
        guard !owned.isEmpty else { return }
        queue.sync { self.write(desired: [], owned: owned) }
    }

    private func write(desired: [HIDMappingPair], owned: [HIDMappingPair]) {
        guard let current = Self.hidutil(["property", "--get", "UserKeyMapping"]) else {
            lastError = "hidutil could not read the current key mapping."; return
        }
        let merged = HIDKeyMapping.merged(current: HIDKeyMapping.parse(current), previouslyOwned: owned, desired: desired)
        guard Self.hidutil(["property", "--set", HIDKeyMapping.json(merged)]) != nil else {
            lastError = "hidutil could not apply the key mapping."; return
        }
        lastError = nil
        InputRemapSettings.ownedPairs = desired
    }

    private static func hidutil(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// While F18 (the remapped Hyper source) is held, every other key gets
/// ⌃⌥⇧⌘. Tapping it alone can send Escape. AOM's own synthetic keys pass.
final class HyperKeyTap {
    static let shared = HyperKeyTap()
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var held = false
    fileprivate var usedWhileHeld = false
    fileprivate var tapEscape = true
    var isRunning: Bool { tap != nil }

    func setEnabled(_ enabled: Bool, tapEscape: Bool) {
        self.tapEscape = tapEscape
        enabled ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hyperKeyCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            GestureLog.shared.logFromAnyThread("Hyper key needs Accessibility permission", level: .error)
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; held = false
    }

    /// The event-tap decision, separated for tests. Returns nil to swallow.
    static func process(type: CGEventType, keyCode: Int64, isSynthetic: Bool,
                        state: inout (held: Bool, used: Bool)) -> (pass: Bool, addHyper: Bool, sendEscape: Bool) {
        guard !isSynthetic else { return (true, false, false) }
        if keyCode == Int64(kVK_F18) {
            if type == .keyDown {
                if !state.held { state = (true, false) }
                return (false, false, false)
            }
            let alone = state.held && !state.used
            state = (false, false)
            return (false, false, alone)
        }
        guard state.held else { return (true, false, false) }
        if type == .keyDown { state.used = true }
        return (true, true, false)
    }
}

private func hyperKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let hyper = Unmanaged<HyperKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = hyper.tap { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    var state = (held: hyper.held, used: hyper.usedWhileHeld)
    let decision = HyperKeyTap.process(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                       isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SyntheticInput.selfTag,
                                       state: &state)
    hyper.held = state.held; hyper.usedWhileHeld = state.used
    if decision.sendEscape, hyper.tapEscape { SyntheticInput.key(UInt16(kVK_Escape)) }
    guard decision.pass else { return nil }
    if decision.addHyper { event.flags.formUnion([.maskCommand, .maskAlternate, .maskShift, .maskControl]) }
    return Unmanaged.passUnretained(event)
}

/// Reverses a wheel mouse's scrolling and leaves trackpads (continuous
/// scrolling) alone, so each device keeps its own natural direction.
final class ScrollWheelReverser {
    static let shared = ScrollWheelReverser()
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }

    func setEnabled(_ enabled: Bool) { enabled ? start() : stop() }

    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: scrollReverseCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            GestureLog.shared.logFromAnyThread("Reversing the mouse wheel needs Accessibility permission", level: .error)
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    static func shouldReverse(isContinuous: Int64, isSynthetic: Bool) -> Bool { isContinuous == 0 && !isSynthetic }

    static func reverse(_ event: CGEvent) {
        for (line, point, fixed) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1),
                                     (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)] {
            let lines = event.getIntegerValueField(line)
            let points = event.getIntegerValueField(point)
            let fraction = event.getDoubleValueField(fixed)
            event.setIntegerValueField(line, value: -lines)
            event.setIntegerValueField(point, value: -points)
            event.setDoubleValueField(fixed, value: -fraction)
        }
    }
}

private func scrollReverseCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let refcon {
        if let port = Unmanaged<ScrollWheelReverser>.fromOpaque(refcon).takeUnretainedValue().tap { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .scrollWheel, ScrollWheelReverser.shouldReverse(
        isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous),
        isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SyntheticInput.selfTag) {
        ScrollWheelReverser.reverse(event)
    }
    return Unmanaged.passUnretained(event)
}
