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
            Image(systemName: AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category))
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

// MARK: - 6.2 list row

/// One automation in the 6.2 list (the owner: rows were cut off, hard to read,
/// and the selection a grey block). The input's mark, the name on up to two
/// lines (never cut), what it does on one line, its keys; the switch appears
/// under the pointer or when selected, "Off" otherwise marks a disabled one.
/// Selected: a raised card with an accent edge (Things, Linear).
struct AutomationListRow: View, Equatable {
    let trigger: Trigger
    let isSelected: Bool
    var lastRun: Date?
    var scope: String?
    let setEnabled: (Bool) -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trigger == rhs.trigger && lhs.isSelected == rhs.isSelected
            && lhs.lastRun == rhs.lastRun && lhs.scope == rhs.scope
    }

    /// 6.11: the gesture itself for trackpad and mouse rows (BTT), the
    /// category's mark for the rest.
    private var symbol: String {
        let glyph = AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category)
        return glyph == trigger.input.category.iconName ? AddTriggerSheet.railSymbol(trigger.input.category) : glyph
    }

    /// What it does, then where and when — never the input again when the
    /// name already says it.
    private var detail: String {
        // The input → what it does (the input is left out when the name is
        // the input itself, and for shortcuts, whose keys show as caps).
        var parts = [trigger.aomRowDetail]
        if let scope, !scope.isEmpty { parts.append(scope) }
        if let ran = AOMAutomationRow.lastRunText(lastRun) { parts.append(ran) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let enabled = trigger.isEnabled
        HStack(alignment: .top, spacing: AOMSpace.x2 + AOMSpace.x0_5) {
            AOMAppIcon(AOMIdentity(symbol: symbol, color: AOMModule.automation.hue), size: 28, active: enabled)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x1) {
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AOMModule.automation.hue)
                            .accessibilityLabel("Pinned")
                    }
                    Text(trigger.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(enabled ? AOMColor.text : AOMColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: AOMSpace.x1) {
                if hovering || isSelected {
                    Toggle("Enabled", isOn: Binding(get: { enabled }, set: setEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable \(trigger.displayName)")
                } else if !enabled {
                    Text("Off")
                        .font(AOMFont.caption.weight(.semibold))
                        .foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                if case .keyboardShortcut(let shortcut) = trigger.input {
                    AOMShortcutKeys(shortcut: shortcut)
                }
            }
        }
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
        .padding(.vertical, AOMSpace.x2)
        .background {
            if isSelected {
                shape.fill(AOMColor.surface)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    .overlay(alignment: .leading) {
                        Capsule().fill(activeState == .inactive ? AOMColor.textTertiary : AOMColor.accent)
                            .frame(width: 3)
                            .padding(.vertical, AOMSpace.x2)
                    }
                shape.strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.accent.opacity(0.35),
                                   lineWidth: contrast == .increased ? 1 : 0.75)
            } else if hovering {
                shape.fill(AOMColor.rowHover)
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trigger.displayName)
        .accessibilityValue("\(enabled ? "On" : "Off"), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}


/// 6.11 (BTT's trigger list): the gesture itself, not one hand for every
/// trackpad row — swipe direction, pinch, rotation, corner, tap, force click.
enum AOMTriggerGlyph {
    static func symbol(name: String, category: TriggerCategory) -> String {
        guard category == .trackpad || category == .normalMouse else { return category.iconName }
        let n = name.lowercased()
        func has(_ part: String) -> Bool { n.contains(part) }
        if has("corner") {
            if has("top left") { return "arrow.up.left.square" }
            if has("top right") { return "arrow.up.right.square" }
            if has("bottom left") { return "arrow.down.left.square" }
            if has("bottom right") { return "arrow.down.right.square" }
        }
        if has("pinch in") { return "arrow.down.right.and.arrow.up.left" }
        if has("pinch out") { return "arrow.up.left.and.arrow.down.right" }
        if has("rotate left") { return "arrow.counterclockwise" }
        if has("rotate") { return "arrow.clockwise" }
        if has("swipe up") { return "arrow.up" }
        if has("swipe down") { return "arrow.down" }
        if has("swipe left") { return "arrow.left" }
        if has("swipe right") { return "arrow.right" }
        if has("tiptap") { return has("left") ? "hand.point.left" : has("right") ? "hand.point.right" : "hand.point.up.left" }
        if has("force") { return "hand.point.up.braille" }
        if has("double tap") || has("double click") { return "hand.tap.fill" }
        if has("tap") { return "hand.tap" }
        if has("click") { return "cursorarrow.click" }
        if has("scroll") { return "scroll" }
        return category.iconName
    }
}
