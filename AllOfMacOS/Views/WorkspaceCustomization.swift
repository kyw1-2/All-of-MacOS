import AppKit
import SwiftUI

// Workspace customization (docs/design-3.4.0.md b.15): which parts, module
// tiles and quick actions Workspace shows, and the order of the quick
// actions. Control Center's Edit Controls and CARROT's layout editor let
// people choose and arrange (#222, #253); every change here is undoable
// (#103–#106). Needs attention and the status line can't be hidden.

/// The built-in quick actions, in their default order.
enum WorkspaceQuickActionKind: String, CaseIterable, Identifiable {
    case captureArea, captureWindow, recordScreen, copyText, clipboardHistory
    case measureScreen, dropShelf, focusSession, muteMicrophone, windowSwitcher

    var id: String { rawValue }
    var layoutID: String { "qa." + rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .recordScreen: return "Record Screen"
        case .copyText: return "Copy Text"
        case .clipboardHistory: return "Clipboard History"
        case .measureScreen: return "Measure Screen"
        case .dropShelf: return "Drop Shelf"
        case .focusSession: return "Focus Session"
        case .muteMicrophone: return "Mute Microphone"
        case .windowSwitcher: return "Window Switcher"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: return "viewfinder"
        case .captureWindow: return "macwindow"
        case .recordScreen: return "record.circle"
        case .copyText: return "text.viewfinder"
        case .clipboardHistory: return "doc.on.clipboard"
        case .measureScreen: return "ruler"
        case .dropShelf: return "tray.and.arrow.down"
        case .focusSession: return "timer"
        case .muteMicrophone: return "mic.slash"
        case .windowSwitcher: return "rectangle.stack"
        }
    }

    /// The module whose hue the tile wears and whose page explains it.
    var module: AOMModule {
        switch self {
        case .captureArea, .captureWindow, .recordScreen, .copyText, .measureScreen: return .capture
        case .clipboardHistory: return .clipboard
        case .dropShelf: return .files
        case .focusSession: return .focus
        case .muteMicrophone: return .audio
        case .windowSwitcher: return .tiling
        }
    }

    /// What the tooltip says the tile does (HIG Offering help: the action,
    /// not the control's name).
    var help: String {
        switch self {
        case .captureArea: return "Captures a part of the screen you select"
        case .captureWindow: return "Captures the window you click"
        case .recordScreen: return "Starts or stops a screen recording"
        case .copyText: return "Copies the text in a part of the screen you select"
        case .clipboardHistory: return "Opens the clipboard shelf"
        case .measureScreen: return "Measures distances on the screen under the pointer"
        case .dropShelf: return "Opens a shelf to collect files while you drag"
        case .focusSession: return "Starts a focus session, or ends the running one"
        case .muteMicrophone: return "Mutes or unmutes the microphone"
        case .windowSwitcher: return "Shows every open window to switch to"
        }
    }

    /// The global shortcut shown under the name.
    @MainActor var shortcut: String? {
        let capture: CaptureShortcutAction?
        switch self {
        case .captureArea: capture = .captureArea
        case .captureWindow: capture = .captureWindow
        case .recordScreen: capture = .recordScreen
        case .copyText: capture = .ocr
        case .measureScreen: capture = .measureScreen
        case .dropShelf: capture = .showDropShelf
        case .focusSession: capture = .toggleFocusSession
        case .muteMicrophone: capture = .toggleMicMute
        case .clipboardHistory: return ClipboardShortcuts.shared.shortcut(for: .history)?.displayString
        case .windowSwitcher: capture = nil
        }
        return capture.flatMap { CaptureShortcuts.shared.shortcut(for: $0)?.displayString }
    }

    /// Runs the same entry point as the hotkey and the menus.
    @MainActor func run() {
        switch self {
        case .captureArea: CaptureCoordinator.shared.captureArea()
        case .captureWindow: CaptureCoordinator.shared.captureWindowInteractive()
        case .recordScreen: ScreenRecordingService.shared.toggleRecording()
        case .copyText: CaptureCoordinator.shared.captureText()
        case .clipboardHistory: ClipboardPanelController.shared.show()
        case .measureScreen: ScreenRulerModule.measure()
        case .dropShelf: FilesModule.showShelf()
        case .focusSession: FocusModule.toggleSession()
        case .muteMicrophone: MicMuteModule.toggleMute()
        case .windowSwitcher: WindowSwitcherController.shared.show()
        }
    }
}

/// What Workspace shows and in which order. Stored under `AOMWorkspaceHidden`
/// (the hidden part, tile and quick-action ids) and `AOMWorkspaceQuickActions`
/// (the quick actions in order), so Reset Preferences restores the default.
@MainActor
final class AOMWorkspaceLayout: ObservableObject {
    static let shared = AOMWorkspaceLayout()
    static let hiddenKey = "AOMWorkspaceHidden"
    static let quickActionsKey = "AOMWorkspaceQuickActions"

    /// The sections that can be hidden.
    enum Part: String, CaseIterable, Identifiable {
        case tools, productivity, quickActions, recent, today, thisMac
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tools: return "Tools"
            case .productivity: return "Productivity"
            case .quickActions: return "Quick actions"
            case .recent: return "Recent activity"
            case .today: return "Today"
            case .thisMac: return "This Mac"
            }
        }
        var symbol: String {
            switch self {
            case .tools: return "square.grid.2x2"
            case .productivity: return "folder.badge.gearshape"
            case .quickActions: return "bolt.horizontal"
            case .recent: return "clock.arrow.circlepath"
            case .today: return "chart.bar"
            case .thisMac: return "laptopcomputer"
            }
        }
    }

    /// A restorable copy, for undo.
    struct State: Equatable {
        var hidden: Set<String>
        var order: [WorkspaceQuickActionKind]
    }

    @Published private(set) var hidden: Set<String>
    @Published private(set) var order: [WorkspaceQuickActionKind]
    /// View › Customize Workspace… asks the Workspace page to open its sheet
    /// (it may not be on screen yet when the menu item runs).
    @Published var customizeRequested = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        order = Self.normalized(defaults.stringArray(forKey: Self.quickActionsKey) ?? [])
    }

    /// Saved ids in order, unknown ones dropped and new ones appended in
    /// their default place, so an update never loses or duplicates a tile.
    static func normalized(_ saved: [String]) -> [WorkspaceQuickActionKind] {
        var result: [WorkspaceQuickActionKind] = []
        for id in saved {
            if let kind = WorkspaceQuickActionKind(rawValue: id), !result.contains(kind) { result.append(kind) }
        }
        for kind in WorkspaceQuickActionKind.allCases where !result.contains(kind) { result.append(kind) }
        return result
    }

    var state: State { State(hidden: hidden, order: order) }
    var isDefault: Bool { hidden.isEmpty && order == WorkspaceQuickActionKind.allCases }

    func shows(_ part: Part) -> Bool { !hidden.contains(part.rawValue) }
    func shows(_ module: AOMModule) -> Bool { !hidden.contains(Self.tileID(module)) }
    func shows(_ kind: WorkspaceQuickActionKind) -> Bool { !hidden.contains(kind.layoutID) }
    static func tileID(_ module: AOMModule) -> String { "module." + module.rawValue }

    /// The quick actions Workspace shows, in order.
    var visibleQuickActions: [WorkspaceQuickActionKind] { order.filter(shows) }

    func setHidden(_ id: String, _ hide: Bool) {
        var next = hidden
        if hide { next.insert(id) } else { next.remove(id) }
        guard next != hidden else { return }
        hidden = next
        save()
    }

    /// Moves a quick action one place earlier (-1) or later (+1) among the
    /// ones Workspace shows.
    func move(_ kind: WorkspaceQuickActionKind, by offset: Int) {
        let visible = visibleQuickActions
        guard let index = visible.firstIndex(of: kind) else { return }
        let target = index + offset
        guard visible.indices.contains(target) else { return }
        move(kind, before: offset < 0 ? visible[target] : (visible.indices.contains(target + 1) ? visible[target + 1] : nil))
    }

    /// Puts `kind` in front of `target` (nil: at the end).
    func move(_ kind: WorkspaceQuickActionKind, before target: WorkspaceQuickActionKind?) {
        guard kind != target else { return }
        var next = order
        next.removeAll { $0 == kind }
        if let target, let index = next.firstIndex(of: target) {
            next.insert(kind, at: index)
        } else {
            next.append(kind)
        }
        guard next != order else { return }
        order = next
        save()
    }

    func canMove(_ kind: WorkspaceQuickActionKind, by offset: Int) -> Bool {
        let visible = visibleQuickActions
        guard let index = visible.firstIndex(of: kind) else { return false }
        return visible.indices.contains(index + offset)
    }

    func restore(_ state: State) {
        guard state != self.state else { return }
        hidden = state.hidden
        order = state.order
        save()
    }

    func reset() { restore(State(hidden: [], order: WorkspaceQuickActionKind.allCases)) }

    private func save() {
        if hidden.isEmpty { defaults.removeObject(forKey: Self.hiddenKey) } else {
            defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
        }
        if order == WorkspaceQuickActionKind.allCases { defaults.removeObject(forKey: Self.quickActionsKey) } else {
            defaults.set(order.map(\.rawValue), forKey: Self.quickActionsKey)
        }
    }

    /// Applies a change as one undoable step named `name` ("Hide Tile").
    func change(_ name: String, undoManager: UndoManager?, _ body: (AOMWorkspaceLayout) -> Void) {
        let before = state
        body(self)
        let after = state
        guard before != after else { return }
        AOMUndo.perform(name, undoManager: undoManager,
                        perform: { [weak self] in self?.restore(after) },
                        revert: { [weak self] in self?.restore(before) })
    }
}

// MARK: - Customize sheet

/// Customize Workspace (HIG Sheets: a reasonable size, Done as the default,
/// Escape closes it). Switches show or hide each part, tile and quick
/// action; quick actions move with ↑ ↓ (or by dragging them on Workspace).
struct WorkspaceCustomizeSheet: View {
    @ObservedObject var layout: AOMWorkspaceLayout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: "slider.horizontal.3", size: AOMIcon.tileBadge)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("Customize Workspace")
                        .font(AOMFont.title)
                        .foregroundStyle(AOMColor.text)
                    Text("Choose what Workspace shows. The status line and Needs attention always show.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(AOMSpace.x5)
            AOMDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    AOMSection("Sections") {
                        ForEach(AOMWorkspaceLayout.Part.allCases) { part in
                            AOMToggleRow(part.title, symbol: part.symbol, isOn: binding(part.rawValue, name: "Section"))
                        }
                    }
                    moduleSection("Tools", modules: [.automation, .tiling, .capture, .clipboard, .audio, .systemTools],
                                  part: .tools)
                    moduleSection("Productivity", modules: [.folderRules, .textActions, .files, .focus], part: .productivity)
                    AOMSection("Quick actions", footer: "Drag a quick action on Workspace to move it, too.") {
                        ForEach(layout.order) { kind in
                            quickActionRow(kind)
                        }
                    }
                    .disabled(!layout.shows(.quickActions))
                }
                .padding(AOMSpace.x5)
            }
            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                Button("Reset Layout") {
                    layout.change("Reset Layout", undoManager: undoManager) { $0.reset() }
                }
                .disabled(layout.isDefault)
                .help("Shows every part and puts the quick actions back in their first order")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AOMSpace.x5)
            .padding(.vertical, AOMSpace.x3)
        }
        .frame(width: 560, height: 640)
        .background(AOMColor.canvas)
    }

    private func moduleSection(_ title: String, modules: [AOMModule], part: AOMWorkspaceLayout.Part) -> some View {
        AOMSection("\(title) tiles") {
            ForEach(modules) { module in
                AOMToggleRow(module.title, symbol: module.symbol,
                             isOn: binding(AOMWorkspaceLayout.tileID(module), name: "Tile"))
            }
        }
        .disabled(!layout.shows(part))
    }

    private func quickActionRow(_ kind: WorkspaceQuickActionKind) -> some View {
        AOMSettingRow(kind.title, detail: kind.shortcut, symbol: kind.symbol) {
            HStack(spacing: AOMSpace.x1) {
                AOMIconButton("chevron.up", label: "Move \(kind.title) Up") {
                    layout.change("Move Quick Action", undoManager: undoManager) { $0.move(kind, by: -1) }
                }
                .disabled(!layout.shows(kind) || !layout.canMove(kind, by: -1))
                AOMIconButton("chevron.down", label: "Move \(kind.title) Down") {
                    layout.change("Move Quick Action", undoManager: undoManager) { $0.move(kind, by: 1) }
                }
                .disabled(!layout.shows(kind) || !layout.canMove(kind, by: 1))
                Toggle(kind.title, isOn: binding(kind.layoutID, name: "Quick Action"))
            }
        }
    }

    /// A switch that shows (on) or hides (off) one id, as an undoable step.
    private func binding(_ id: String, name: String) -> Binding<Bool> {
        Binding(get: { !layout.hidden.contains(id) },
                set: { show in
                    layout.change(show ? "Show \(name)" : "Hide \(name)", undoManager: undoManager) {
                        $0.setHidden(id, !show)
                    }
                })
    }
}
