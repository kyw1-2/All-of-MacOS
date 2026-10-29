import AppKit

// Swish's configurable modifier roles and the ⌃⌥ hotkey extensions (3.3.3).
//
// Swish 1.13.3's Advanced tab lets the user pick a key for each of five roles:
// "Super Modifier" ("Use this modifier to perform window gestures on their
// entire area instead of their titlebar only or on their dock icon. Can be
// combined with all modifiers below."), then "General", "Screen", "Secondary"
// and "Tertiary" ("Perform general functions (fullscreen, closing, spaces,
// etc.), invoke multi-screen actions, unlock secondary (3×2 snapping, all
// windows, etc.) and tertiary (3×3 snapping) functionality."). Its modifier
// controls carry `flagsConstraints` closures that refuse a key another role
// already uses, and "Restore Modifiers" puts the defaults back.
//
// The same tab adds the keyboard: "Arrow Hotkeys: ←↑↓→ | WASD | ,AOE",
// "Center: Esc | ⌫ | ↩", and "Use the super modifier together with your arrow
// keys to enable all snapping, screens and spaces gestures. Press the center
// key to center & unsnap." AOM keeps its 3.3.2 ⌃⌥ chord as the base and lets
// the Screen and Secondary roles extend it.
//
// AOM 3.3.2 hard-wired ⌥ (general), ⌘ (screen) and ⇧ (secondary) in
// `SwishSnap.Modifiers`; the standard roles below keep exactly those, so an
// upgrade changes nothing until the user edits them.
//
// Everything here is pure: settings are read and written only through the
// `UserDefaults` passed in, so tests use a throwaway suite.
//
// Note: a top-level `ModifierKeys` (flagsChanged key codes for actions) lives
// in ActionInputSynthesis.swift. Inside `SwishSnap` the nested type below
// shadows it; outside, write `SwishSnap.ModifierKeys`.

extension SwishSnap {
    // MARK: Modifier keys

    /// The physical keys a modifier role can use.
    struct ModifierKeys: OptionSet, Hashable, CustomStringConvertible {
        let rawValue: Int

        /// Keeps only the five known bits, so a stray value from an old or
        /// hand-edited backup cannot name a key AOM does not know.
        init(rawValue: Int) {
            // A literal mask: reading `known` here would re-enter its own
            // lazy initialisation.
            self.rawValue = rawValue & 0b1_1111
        }

        static let control = ModifierKeys(rawValue: 1)
        static let option = ModifierKeys(rawValue: 1 << 1)
        static let shift = ModifierKeys(rawValue: 1 << 2)
        static let command = ModifierKeys(rawValue: 1 << 3)
        /// fn / 🌐.
        static let function = ModifierKeys(rawValue: 1 << 4)
        static let known: ModifierKeys = [.control, .option, .shift, .command, .function]

        /// The role keys among an event's flags; Caps Lock, numeric pad and
        /// the device-dependent bits are dropped.
        init(flags: NSEvent.ModifierFlags) {
            var keys: ModifierKeys = []
            if flags.contains(.control) { keys.insert(.control) }
            if flags.contains(.option) { keys.insert(.option) }
            if flags.contains(.shift) { keys.insert(.shift) }
            if flags.contains(.command) { keys.insert(.command) }
            if flags.contains(.function) { keys.insert(.function) }
            self = keys
        }

        var flags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.control) { flags.insert(.control) }
            if contains(.option) { flags.insert(.option) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.command) { flags.insert(.command) }
            if contains(.function) { flags.insert(.function) }
            return flags
        }

        /// Apple's order ⌃⌥⇧⌘, then "fn"; "None" when empty.
        var symbols: String {
            guard !isEmpty else { return "None" }
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            if contains(.function) { text += "fn" }
            return text
        }

        var description: String { symbols }
    }

    // MARK: Roles

    /// Swish's five modifier roles.
    enum ModifierRole: String, CaseIterable, Equatable {
        case superKey = "super", general, screen, secondary, tertiary

        /// The settings key, e.g. "AOMTitleBarSnapModifierSuper": an Int
        /// holding a `ModifierKeys` raw value; 0 turns the role off. (Not to
        /// be confused with "AOMTitleBarSnapModifiers", the 3.3.2 on/off
        /// switch for modifier gestures.)
        var defaultsKey: String { "AOMTitleBarSnapModifier" + title }

        var title: String {
            switch self {
            case .superKey: return "Super"
            case .general: return "General"
            case .screen: return "Screen"
            case .secondary: return "Secondary"
            case .tertiary: return "Tertiary"
            }
        }

        /// One-line help for settings: what the role does in AOM.
        var help: String {
            switch self {
            case .superKey:
                return "Hold it to start a gesture anywhere in a window, not only on its title bar (when that option is on)."
            case .general:
                return "Swipe sideways for the next Space, down to close; double tap hides the app."
            case .screen:
                return "Swipe to move the window to the display that way; pinch out for full screen there."
            case .secondary:
                return "Swipe for the 3 × 2 grid (up: almost maximize); double tap hides the other apps."
            case .tertiary:
                return "Swipe for the 3 × 3 grid."
            }
        }
    }

    /// Which keys play which role. Roles must not share keys (Swish checks
    /// this too), so a held key always means one thing.
    struct ModifierRoles: Equatable {
        var superKey: ModifierKeys
        var general: ModifierKeys
        var screen: ModifierKeys
        var secondary: ModifierKeys
        var tertiary: ModifierKeys

        /// AOM's defaults: Super fn (🌐), General ⌥, Screen ⌘, Secondary ⇧,
        /// Tertiary ⌃. General, Screen and Secondary are what 3.3.2
        /// hard-wired. Swish's update notes use ⇧ the same way ("Try them out
        /// with the new 'Almost Maximize' gesture by swiping up while holding ⇧").
        static let standard = ModifierRoles(superKey: .function, general: .option, screen: .command,
                                            secondary: .shift, tertiary: .control)

        subscript(role: ModifierRole) -> ModifierKeys {
            get {
                switch role {
                case .superKey: return superKey
                case .general: return general
                case .screen: return screen
                case .secondary: return secondary
                case .tertiary: return tertiary
                }
            }
            set {
                switch role {
                case .superKey: superKey = newValue
                case .general: general = newValue
                case .screen: screen = newValue
                case .secondary: secondary = newValue
                case .tertiary: tertiary = newValue
                }
            }
        }

        /// Two roles that share `keys`.
        struct Conflict: Equatable {
            let first: ModifierRole
            let second: ModifierRole
            let keys: ModifierKeys
        }

        /// Pairs of roles (in `ModifierRole.allCases` order, first before
        /// second) whose keys overlap. An empty role overlaps nothing.
        var conflicts: [Conflict] {
            let roles = ModifierRole.allCases
            var found: [Conflict] = []
            for (index, first) in roles.enumerated() {
                for second in roles[(index + 1)...] {
                    let shared = self[first].intersection(self[second])
                    if !shared.isEmpty { found.append(Conflict(first: first, second: second, keys: shared)) }
                }
            }
            return found
        }

        var isValid: Bool { conflicts.isEmpty }

        /// The roles whose keys are all held (an empty role never is). Keys
        /// outside every role are ignored, as are flags such as .numericPad
        /// and .capsLock.
        func held(_ flags: NSEvent.ModifierFlags) -> Set<ModifierRole> {
            let down = ModifierKeys(flags: flags)
            return Set(ModifierRole.allCases.filter { role in
                let keys = self[role]
                return !keys.isEmpty && down.isSuperset(of: keys)
            })
        }

        /// The stored roles as written, before the conflict fallback.
        private static func stored(_ defaults: UserDefaults) -> ModifierRoles {
            var roles = standard
            for role in ModifierRole.allCases {
                // A missing key, or one of the wrong type, keeps the default.
                guard let number = defaults.object(forKey: role.defaultsKey) as? NSNumber else { continue }
                roles[role] = ModifierKeys(rawValue: number.intValue)
            }
            return roles
        }

        /// Reads the five Int keys. A missing key keeps the role's default;
        /// values are masked to known keys. A set that conflicts falls back to
        /// `.standard` entirely (`loadIssue` says why), so a bad backup can
        /// never make a gesture ambiguous.
        static func load(_ defaults: UserDefaults) -> ModifierRoles {
            let roles = stored(defaults)
            return roles.isValid ? roles : standard
        }

        /// Nil when the stored roles are fine; else a short sentence for
        /// settings, e.g. "Super and General share ⌥; using the standard modifiers."
        static func loadIssue(_ defaults: UserDefaults) -> String? {
            guard let conflict = stored(defaults).conflicts.first else { return nil }
            return "\(conflict.first.title) and \(conflict.second.title) share \(conflict.keys.symbols); using the standard modifiers."
        }

        /// Writes all five roles (Swish's "Restore Modifiers" is
        /// `save(.standard, to:)`). Returns false and writes nothing when
        /// `roles` conflict.
        @discardableResult
        static func save(_ roles: ModifierRoles, to defaults: UserDefaults) -> Bool {
            guard roles.isValid else { return false }
            for role in ModifierRole.allCases {
                defaults.set(roles[role].rawValue, forKey: role.defaultsKey)
            }
            return true
        }

        /// Whether changing `role` to `keys` would clash with another role,
        /// so a settings control can refuse it (Swish's `flagsConstraints`).
        /// Nil when it would not; turning a role off never conflicts.
        func conflict(setting role: ModifierRole, to keys: ModifierKeys) -> Conflict? {
            var changed = self
            changed[role] = keys
            return changed.conflicts.first { $0.first == role || $0.second == role }
        }
    }

    // MARK: ⌃⌥ hotkey commands

    /// The center key of the ⌃⌥ hotkeys (Swish: "Center: Esc | ⌫ | ↩",
    /// "Press the center key to center & unsnap").
    enum HotkeyCenterKey: String, CaseIterable, Equatable {
        case off, escape, backspace, `return`

        /// Esc 53; ⌫ 51; ↩ 36 and keypad Enter 76. Empty when off.
        var keyCodes: [UInt16] {
            switch self {
            case .off: return []
            case .escape: return [53]
            case .backspace: return [51]
            case .`return`: return [36, 76]
            }
        }

        var symbol: String {
            switch self {
            case .off: return "Off"
            case .escape: return "Esc"
            case .backspace: return "⌫"
            case .`return`: return "↩"
            }
        }
    }

    /// What one ⌃⌥ key press does.
    enum HotkeyCommand: Equatable {
        /// ⌃⌥ and a direction key: the swipe that way on the front window (3.3.2).
        case swipe(Direction)
        /// ⌃⌥ plus the Screen role's keys (⌘ by default) and a direction key:
        /// move the window to the display that way (Swish: super + screen
        /// modifier + arrows).
        case screen(Direction)
        /// ⌃⌥ plus the Secondary role's keys (⇧ by default) and a direction
        /// key: the swipe with the secondary modifier held (3 × 2 grid for
        /// this press; ↑ almost maximizes).
        case secondary(Direction)
        /// ⌃⌥ and the center key: centre and unsnap (the two-finger double
        /// tap's restore-or-centre).
        case center
    }

    /// Pure: the command for a key press, or nil (the key then goes on to the app).
    /// - Hotkeys off (`scheme.keyCodes` nil) → nil for everything, the center key included.
    /// - Only ⌘⌥⌃⇧ count; .function, .numericPad, .capsLock etc. are ignored
    ///   (arrow keys carry the fn and numeric-pad flags).
    /// - The base chord is exactly `hotkeyModifiers` (⌃⌥). A Screen or
    ///   Secondary extension is available only when that role's keys are
    ///   non-empty, hold no ⌃, ⌥ or fn (fn cannot be told apart on arrow
    ///   keys; ⌃⌥ are the chord) and the two roles do not overlap. Extra keys
    ///   equal to the Screen role → `.screen`, equal to the Secondary role →
    ///   `.secondary`, anything else (both, or other keys) → nil.
    /// - The center key counts only with the bare chord and only when
    ///   `center` is not `.off`; a center key code that is also one of the
    ///   scheme's direction keys is a direction.
    static func hotkeyCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, scheme: HotkeyScheme,
                              center: HotkeyCenterKey, roles: ModifierRoles) -> HotkeyCommand? {
        // Only `keyCodes` is used, never a switch over the scheme, so a new
        // layout (e.g. Dvorak's ,AOE) needs no change here.
        guard let keys = scheme.keyCodes else { return nil }
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        guard relevant.isSuperset(of: hotkeyModifiers) else { return nil }
        let extra = ModifierKeys(flags: relevant.subtracting(hotkeyModifiers))

        let direction: Direction?
        switch keyCode {
        case keys.left: direction = .left
        case keys.right: direction = .right
        case keys.up: direction = .up
        case keys.down: direction = .down
        default: direction = nil
        }

        if extra.isEmpty {
            if let direction { return .swipe(direction) }
            if center != .off, center.keyCodes.contains(keyCode) { return .center }
            return nil
        }

        guard let direction else { return nil }
        let reserved: ModifierKeys = [.control, .option, .function]
        let screen = roles.screen, secondary = roles.secondary
        // Overlapping roles would make one chord mean two things; refuse both.
        guard screen.isDisjoint(with: secondary) else { return nil }
        if !screen.isEmpty, screen.isDisjoint(with: reserved), extra == screen { return .screen(direction) }
        if !secondary.isEmpty, secondary.isDisjoint(with: reserved), extra == secondary { return .secondary(direction) }
        return nil
    }

    // MARK: Grid unlocks

    /// Pure: the grid a trackpad gesture uses with `held` roles down (Swish:
    /// secondary unlocks 3×2 snapping, tertiary 3×3): 3 × 3 while Tertiary
    /// is held, 3 × 2 while Secondary is held on a 2 × 2 grid, else the
    /// configured grid. Secondary never shrinks a 3 × 3 grid.
    static func effectiveGrid(_ grid: Grid, held: Set<ModifierRole>) -> Grid {
        if held.contains(.tertiary) { return .threeByThree }
        if held.contains(.secondary), grid == .twoByTwo { return .threeByTwo }
        return grid
    }

    /// Pure: the gesture options while `held` roles are down: Secondary and
    /// Tertiary unlock their grids for this gesture, and Secondary makes a
    /// swipe up almost-maximize (Swish: "the new 'Almost Maximize' gesture by
    /// swiping up while holding ⇧"; up again maximizes). Unchanged while
    /// modifier gestures are off.
    static func effectiveOptions(_ options: GestureOptions, held: Set<ModifierRole>) -> GestureOptions {
        guard options.modifierGestures else { return options }
        var result = options
        result.grid = effectiveGrid(options.grid, held: held)
        if held.contains(.secondary) { result.almostMaximize = true }
        return result
    }

    /// Pure (X35): drag to unsnap applies to this drag unless the Secondary
    /// role's keys are held ("Use the secondary modifier to temporarily
    /// disable Drag to Unsnap").
    static func dragUnsnapApplies(enabled: Bool, held: Set<ModifierRole>) -> Bool {
        enabled && !held.contains(.secondary)
    }

    /// The roles held now, from the saved roles (main thread: reads
    /// `NSEvent.modifierFlags`).
    static func heldRoles(_ defaults: UserDefaults = .standard) -> Set<ModifierRole> {
        ModifierRoles.load(defaults).held(NSEvent.modifierFlags)
    }
}
