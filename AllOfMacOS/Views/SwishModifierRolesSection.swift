import SwiftUI

/// Window Tiling › Modifiers (3.3.3, Swish's Advanced tab): "Super key: whole
/// window", one picker per modifier role, and Restore Modifiers.
///
/// - A pick that would share a key with another role is refused through
///   `ModifierRoles.conflict(setting:to:)` (Swish's `flagsConstraints`). The
///   menu names the role that already has each key, and the footer says why
///   a pick did not stick.
/// - A stored set that clashes (an old or hand-edited backup) is read as the
///   standard set; `ModifierRoles.loadIssue` says so above the card, next to
///   Restore Modifiers (`ModifierRoles.save(.standard, to:)`).
/// - Every row belongs to title-bar snap and dims while it is off (ui.md's
///   dependent-options rule); Title-bar snap's footer says why, so this
///   section's footer only carries a refused pick. The section ⓘ explains the
///   roles; each row keeps its explanation as a tooltip.
struct SwishModifierRolesSection: View {
    /// Title-bar snap's switch.
    let snapOn: Bool

    @AppStorage(TitleBarWindowSnap.superAnywhereKey) private var superAnywhere = false
    // Observed so the pickers follow a restore, a backup or another window;
    // the roles themselves are always read through `ModifierRoles.load`.
    @AppStorage(SwishSnap.ModifierRole.superKey.defaultsKey)
    private var superRaw = SwishSnap.ModifierRoles.standard.superKey.rawValue
    @AppStorage(SwishSnap.ModifierRole.general.defaultsKey)
    private var generalRaw = SwishSnap.ModifierRoles.standard.general.rawValue
    @AppStorage(SwishSnap.ModifierRole.screen.defaultsKey)
    private var screenRaw = SwishSnap.ModifierRoles.standard.screen.rawValue
    @AppStorage(SwishSnap.ModifierRole.secondary.defaultsKey)
    private var secondaryRaw = SwishSnap.ModifierRoles.standard.secondary.rawValue
    @AppStorage(SwishSnap.ModifierRole.tertiary.defaultsKey)
    private var tertiaryRaw = SwishSnap.ModifierRoles.standard.tertiary.rawValue
    /// Why the last pick was refused; cleared by the next pick that sticks.
    @State private var refusal: String?
    /// Bumped by every refusal: the pickers are rebuilt, so the menu shows
    /// the key the role kept instead of the refused one.
    @State private var refusals = 0

    private typealias Keys = SwishSnap.ModifierKeys
    private typealias Roles = SwishSnap.ModifierRoles
    private typealias Role = SwishSnap.ModifierRole

    private struct Choice: Identifiable {
        let keys: SwishSnap.ModifierKeys
        let name: String
        var id: Int { keys.rawValue }
    }

    /// One key per role, in Apple's order ⌃⌥⇧⌘, then fn.
    private static let choices = [
        Choice(keys: .control, name: "⌃ Control"), Choice(keys: .option, name: "⌥ Option"),
        Choice(keys: .shift, name: "⇧ Shift"), Choice(keys: .command, name: "⌘ Command"),
        Choice(keys: .function, name: "fn Globe"),
    ]

    private static let sectionHelp = "Each role is one modifier key: hold it while you swipe, pinch or double tap on a title bar (with Modifier gestures on) to change what the gesture does. Two roles can't share a key. Restore Modifiers puts back fn, ⌥, ⌘, ⇧ and ⌃."
    private static let superAnywhereHelp = "Hold the Super key to start window gestures anywhere on a window, not only its title bar."

    /// "Super fn · General ⌥ · Screen ⌘ · Secondary ⇧ · Tertiary ⌃"
    private static let standardSummary = Role.allCases
        .map { "\($0.title) \(Roles.standard[$0].symbols)" }
        .joined(separator: " · ")

    var body: some View {
        let roles = Roles.load(.standard)
        let issue = Roles.loadIssue(.standard)
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Modifiers", help: Self.sectionHelp)
            if let issue {
                AOMNotice(.warning, "The saved modifiers clash.", detail: issue) {
                    Button("Restore Modifiers", action: restore)
                }
            }
            AOMSection(footer: snapOn ? refusal : nil) {
                Group {
                    AOMToggleRow("Super key: whole window", detail: superDetail(roles), isOn: $superAnywhere)
                        .help(Self.superAnywhereHelp)
                    ForEach(Role.allCases, id: \.self) { role in
                        rolePicker(role, roles: roles)
                    }
                    AOMSettingRow("Standard modifiers", detail: Self.standardSummary) {
                        Button("Restore Modifiers", action: restore)
                            .disabled(roles == .standard && issue == nil)
                    }
                    .help("Put back Super fn, General ⌥, Screen ⌘, Secondary ⇧ and Tertiary ⌃")
                }
                .dependentSetting(on: snapOn)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows

    private func rolePicker(_ role: Role, roles: Roles) -> some View {
        let current = roles[role]
        return AOMSettingRow(role.title, detail: Self.detail(role)) {
            Picker("\(role.title) modifier", selection: Binding(get: { current.rawValue },
                                                               set: { choose(Keys(rawValue: $0), for: role) })) {
                Text("None").tag(0)
                ForEach(Self.choices) { choice in
                    // A key another role has is shown with that role, and refused.
                    let owner = Self.owner(of: choice.keys, for: role, in: roles)
                    Text(owner.map { "\(choice.name) · \($0.title)" } ?? choice.name)
                        .tag(choice.keys.rawValue)
                        .disabled(owner != nil)
                }
                if !current.isEmpty, !Self.choices.contains(where: { $0.keys == current }) {
                    // A key combination from a backup or a hand-edited setting.
                    Text(current.symbols).tag(current.rawValue)
                }
            }
            .pickerStyle(.menu)
            .id("\(role.rawValue)-\(refusals)")
        }
        .help(Self.help(role))
    }

    private func superDetail(_ roles: Roles) -> String {
        roles.superKey.isEmpty ? "Choose a Super key below to use this"
                               : "Hold \(roles.superKey.symbols) to start a gesture anywhere on a window"
    }

    private static func detail(_ role: Role) -> String {
        switch role {
        case .superKey: return "Used by Super key: whole window"
        case .general: return "Spaces, close and hide"
        case .screen: return "Move to another display"
        case .secondary: return "3 × 2 grid, almost maximize, hide others"
        case .tertiary: return "3 × 3 grid"
        }
    }

    /// The role's own help, plus where the ⌃⌥ keyboard shortcuts and dragging use it.
    private static func help(_ role: Role) -> String {
        switch role {
        case .screen:
            return role.help + " With the ⌃⌥ keyboard shortcuts, add it to move the front window to the display that way."
        case .secondary:
            return role.help + " Hold it while dragging a snapped window to keep its size; with the ⌃⌥ keyboard shortcuts, add it for the 3 × 2 grid."
        case .superKey, .general, .tertiary:
            return role.help
        }
    }

    // MARK: Changes

    /// The other role that already uses `keys`, when giving them to `role` would clash.
    private static func owner(of keys: Keys, for role: Role, in roles: Roles) -> Role? {
        roles.conflict(setting: role, to: keys).map { $0.first == role ? $0.second : $0.first }
    }

    private func choose(_ keys: Keys, for role: Role) {
        var roles = Roles.load(.standard)
        guard roles[role] != keys else { return }
        if let other = Self.owner(of: keys, for: role, in: roles) {
            let text = "\(keys.symbols) is the \(other.title) modifier. Change \(other.title) first to use it for \(role.title)."
            refusal = text
            refusals += 1
            AccessibilityNotification.Announcement(text).post()
            return
        }
        roles[role] = keys
        if Roles.save(roles, to: .standard) { refusal = nil }
    }

    private func restore() {
        Roles.save(.standard, to: .standard)
        refusal = nil
    }
}
