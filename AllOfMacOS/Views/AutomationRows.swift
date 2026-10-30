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
struct AOMAutomationRow<Accessory: View>: View {
    @EnvironmentObject var appState: AppState
    let trigger: Trigger
    var showsSwitch = true
    /// True only inside a selection list: key caps then invert to white on the
    /// row's accent fill when this trigger is the selected one.
    var rendersSelection = false
    @ViewBuilder var accessory: Accessory

    init(trigger: Trigger, showsSwitch: Bool = true, rendersSelection: Bool = false,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.trigger = trigger
        self.showsSwitch = showsSwitch
        self.rendersSelection = rendersSelection
        self.accessory = accessory()
    }

    /// The list selection is app state, so the row knows when it is selected.
    private var isSelected: Bool { rendersSelection && appState.selectedTrigger?.id == trigger.id }

    var body: some View {
        AOMListRow(trigger.displayName, detail: trigger.aomRowDetail, dimmed: !trigger.isEnabled) {
            Image(systemName: trigger.input.category.iconName)
                .font(AOMFont.callout.weight(.medium))
                .foregroundStyle(trigger.isEnabled ? .secondary : .tertiary)
                .help(trigger.input.category.rawValue)
        } trailing: {
            HStack(spacing: AOMSpace.xs) {
                accessory
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
                    Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled },
                                                    set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable \(trigger.displayName)")
                }
            }
        }
    }
}
