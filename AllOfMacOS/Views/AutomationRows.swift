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
    /// 6.1 (status-first rows): when it last ran, from the statistics.
    var lastRun: Date?
    /// 6.1: the row says what it does on a second line.
    var showsDetail = false
    /// Where it applies when not everywhere ("Finder", "Group: Coding").
    var scope: String?
    let setEnabled: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trigger == rhs.trigger && lhs.isSelected == rhs.isSelected && lhs.showsSwitch == rhs.showsSwitch
            && lhs.lastRun == rhs.lastRun && lhs.showsDetail == rhs.showsDetail && lhs.scope == rhs.scope
    }

    /// "Ran 3 min ago", "Ran yesterday" — nil when it never ran.
    static func lastRunText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Ran just now" }
        if seconds < 3600 { return "Ran \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Ran \(Int(seconds / 3600)) h ago" }
        if seconds < 172_800 { return "Ran yesterday" }
        return "Ran \(Int(seconds / 86_400)) days ago"
    }

    private var detail: String? {
        guard showsDetail else { return nil }
        var parts: [String] = []
        let does = trigger.aomRowDetail
        if !does.isEmpty { parts.append(does) }
        if let scope, !scope.isEmpty { parts.append(scope) }
        if let ran = Self.lastRunText(lastRun) { parts.append(ran) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        // The name, then what it does and when it last ran; the input glyph
        // and the trailing keys say the rest.
        AOMListRow(trigger.displayName, detail: detail, dimmed: !trigger.isEnabled) {
            // A neutral input glyph (6.0): the list is about names, not colour.
            Image(systemName: trigger.input.category.iconName)
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
