import AppKit

/// The microphone's mute logic without hardware, so it can be tested: what
/// the person chose (`resting`), whether the push-to-talk key is holding the
/// microphone open (`talking`), and what the hardware should be (`muted`).
///
/// Every input returns an `Effect`: `.apply` means write the hardware and
/// show the HUD; `.adopt` means the hardware already changed (another app,
/// the Audio page, Control Center) and only the indicator follows.
struct MicMuteMachine: Equatable {
    enum Cause: Equatable {
        case toggle
        case talkStarted
        case talkEnded
        /// An app on the auto-mute list opened (its name).
        case autoMute(String)
        /// The default microphone changed while muted; the new one is muted too.
        case deviceChanged
    }

    enum Effect: Equatable {
        case none
        case apply(muted: Bool, cause: Cause)
        case adopt(muted: Bool)
    }

    /// The state the person chose (toggle, auto-mute, another app's mute).
    private(set) var resting: Bool
    /// The push-to-talk key is down and opened the microphone.
    private(set) var talking = false

    /// What the hardware should be now.
    var muted: Bool { resting && !talking }

    init(muted: Bool) { resting = muted }

    /// The toggle hotkey, the status menu, Workspace: flips what people
    /// hear. While push-to-talk holds the microphone open, toggling mutes
    /// it and ends the talk (the key is still down, but its release no
    /// longer changes anything).
    mutating func toggle() -> Effect {
        set(muted: !muted, cause: .toggle)
    }

    mutating func set(muted target: Bool, cause: Cause = .toggle) -> Effect {
        let before = muted
        resting = target
        talking = false
        return before == muted ? .none : .apply(muted: muted, cause: cause)
    }

    /// The push-to-talk key went down. It only opens a muted microphone.
    mutating func keyDown() -> Effect {
        guard resting, !talking else { return .none }
        talking = true
        return .apply(muted: false, cause: .talkStarted)
    }

    /// The push-to-talk key came up: back to muted if it had opened it.
    mutating func keyUp() -> Effect {
        guard talking else { return .none }
        talking = false
        return muted ? .apply(muted: true, cause: .talkEnded) : .none
    }

    /// An auto-mute app opened. While push-to-talk is held the microphone
    /// stays open until the key comes up.
    mutating func autoMute(app: String) -> Effect {
        let before = muted
        resting = true
        return before == muted ? .none : .apply(muted: true, cause: .autoMute(app))
    }

    /// The hardware's state as read now. A difference that AOM didn't make
    /// becomes the new choice; reading what AOM wrote changes nothing.
    mutating func observe(hardwareMuted: Bool) -> Effect {
        guard hardwareMuted != muted else { return .none }
        resting = hardwareMuted
        talking = false
        return .adopt(muted: hardwareMuted)
    }

    /// The default microphone changed. A muted microphone stays muted on
    /// the new device; an open one is never opened automatically, so a new
    /// device that is already muted is simply adopted.
    mutating func deviceChanged(newDeviceMuted: Bool) -> Effect {
        if muted { return newDeviceMuted ? .none : .apply(muted: true, cause: .deviceChanged) }
        return observe(hardwareMuted: newDeviceMuted)
    }
}

/// The key people hold to talk while muted. Only modifier keys: they never
/// type a character into the front app, and AOM reads only their up/down
/// state (flagsChanged events), never keystrokes.
enum MicPushToTalkKey: String, CaseIterable, Codable, Identifiable, Sendable {
    case rightOption, rightCommand, rightControl, rightShift, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .fn: return "Fn (Globe)"
        }
    }

    var shortTitle: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        case .fn: return "Fn"
        }
    }

    /// The physical key's virtual key code (kVK_RightOption …, kVK_Function).
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// The device-dependent bit for this side of the modifier (IOLLEvent.h
    /// NX_DEVICER…KEYMASK) or, for Fn, the secondary-function flag.
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .rightShift: return 0x04
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    /// The side-independent flag, for the hold watchdog.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .rightShift: return .shift
        case .fn: return .function
        }
    }

    func isDown(flags: UInt) -> Bool { flags & deviceMask != 0 }
}

/// Turns flagsChanged events into press and release of one key. A release
/// that the monitor missed (secure input started mid-hold) is caught by the
/// next event of any modifier, or by `poll(flags:)` while the key is held.
struct PushToTalkTracker: Equatable {
    enum Transition: Equatable { case pressed, released }

    let key: MicPushToTalkKey
    private(set) var isDown = false

    init(key: MicPushToTalkKey) { self.key = key }

    mutating func handle(keyCode: UInt16, flags: UInt) -> Transition? {
        let down = keyCode == key.keyCode ? key.isDown(flags: flags) : (isDown && key.isDown(flags: flags))
        if keyCode != key.keyCode && !isDown { return nil }
        guard down != isDown else { return nil }
        isDown = down
        return down ? .pressed : .released
    }

    /// `flags` are side-independent modifier flags read now.
    mutating func poll(flags: NSEvent.ModifierFlags) -> Transition? {
        guard isDown, !flags.contains(key.flag) else { return nil }
        isDown = false
        return .released
    }

    mutating func reset() -> Transition? {
        guard isDown else { return nil }
        isDown = false
        return .released
    }
}
