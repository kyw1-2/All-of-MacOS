import AppKit
import SwiftUI

// One way to show an automation in a list, used by Workspace and Automation.

extension Trigger {
    /// The first enabled action with its key value ("Send Keyboard Shortcut · ⌃→  +1").
    var aomActionSummary: String { ActionSummary.summary(actions) }

    /// Whether the automation has a name of its own. Unnamed automations are
    /// titled by their input, so the input must not be repeated beneath.
    var aomHasCustomName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(input.displayName) != .orderedSame
    }

    /// The second line of a row: the input only when the title is a custom
    /// name (keyboard shortcuts show as key caps instead), then the actions.
    var aomRowDetail: String {
        var input = input.displayName
        if requiredModifiers != nil { input = "\(modifierLabel) \(input)" }
        if case .keyboardShortcut = self.input { return aomActionSummary }
        return aomHasCustomName ? "\(input) → \(aomActionSummary)" : aomActionSummary
    }

    /// Whether running this from a list could type stored text (a password)
    /// into whatever has focus — those run only from their editor's Test.
    var aomTypesText: Bool { actions.contains { $0.actionType == .typeText } }
}

/// An automation as a list row: input glyph, title, what it does, and its
/// key caps / pin / switch on the trailing edge.
///
/// It reads no app state: the list passes whether it is selected and how to
/// switch it, and `==` compares only what it draws. Before, every row
/// observed AppState, so selecting, searching or toggling one automation
/// redrew all of them.
struct AOMAutomationRow: View, Equatable {
    let trigger: Trigger
    var isSelected = false
    var showsSwitch = true
    let setEnabled: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trigger == rhs.trigger && lhs.isSelected == rhs.isSelected && lhs.showsSwitch == rhs.showsSwitch
    }

    var body: some View {
        // Names only: the input glyph and the trailing value say the rest.
        AOMListRow(trigger.displayName, dimmed: !trigger.isEnabled) {
            AOMModuleBadge(symbol: trigger.input.category.iconName, size: 22, active: trigger.isEnabled)
                .help(trigger.input.category.rawValue)
        } trailing: {
            HStack(spacing: AOMSpace.xs) {
                if trigger.isFavorite {
                    // Hierarchical, so List selection turns it white with the
                    // row; tertiary at 9.5 pt all but vanished in light mode.
                    Image(systemName: "pin.fill").font(AOMFont.badge).foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                if case .keyboardShortcut(let shortcut) = trigger.input {
                    AOMShortcutKeys(shortcut: shortcut, onSelection: isSelected)
                }
                if showsSwitch {
                    Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled }, set: setEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable \(trigger.displayName)")
                }
            }
        }
    }
}
