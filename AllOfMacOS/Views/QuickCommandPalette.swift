import AppKit
import SwiftUI

/// The command palette, after Raycast's root search and Action Panel: one
/// field that is focused on open, ↑↓ to move, ↩ for the primary action, ⌘↩
/// for the secondary one, Esc to clear the query and then to close. With an
/// empty query results are grouped by kind; while searching they are one
/// ranked list. Shortcut hints are the user's real bindings.
struct QuickCommandPalette: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboardStore = ClipboardStore.shared
    @ObservedObject private var captureHistory = CaptureHistory.shared
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var isFieldFocused: Bool

    struct PaletteAction {
        let title: String
        let run: () -> Void
    }

    struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let section: Section
        var shortcut: String?
        let primary: PaletteAction
        var secondary: PaletteAction?
    }

    enum Section: String, CaseIterable {
        case commands = "Commands"
        case automations = "Automations"
        case clipboard = "Clipboard"
        case captures = "Recent Captures"
        case navigation = "Go To"
    }

    // MARK: Items

    private func close() { isPresented = false }

    private func captureKeys(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        func command(_ id: String, _ title: String, _ subtitle: String, _ icon: String, keys: String? = nil,
                     _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: id, title: title, subtitle: subtitle, icon: icon, section: .commands, shortcut: keys,
                                     primary: PaletteAction(title: "Run") { close(); run() }))
        }
        command("capture.area", "Capture Area", "Drag a region to capture", "viewfinder",
                keys: captureKeys(.captureArea)) { CaptureCoordinator.shared.captureArea() }
        command("capture.window", "Capture Window", "Pick a window to capture", "macwindow") {
            CaptureCoordinator.shared.captureWindowInteractive()
        }
        command("capture.fullscreen", "Capture Full Screen", "The display under the pointer", "display") {
            CaptureCoordinator.shared.captureFullscreen()
        }
        command("capture.text", "Capture Text", "Recognise text in a region and copy it", "text.viewfinder") {
            CaptureCoordinator.shared.captureText()
        }
        command("capture.record", "Record Screen", "Start a screen recording", "record.circle") {
            ScreenRecordingService.shared.promptAndStartRecording()
        }
        command("clipboard.shelf", "Open Clipboard Shelf", "Find and paste a copied item", "doc.on.clipboard",
                keys: ClipboardShortcuts.shared.shortcut(for: .history)?.displayString) {
            ClipboardPanelController.shared.show()
        }
        command("window.left", "Tile Window Left Half", "Move the front window to the left half", "rectangle.lefthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowLeft))
        }
        command("window.right", "Tile Window Right Half", "Move the front window to the right half", "rectangle.righthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowRight))
        }
        command("window.maximize", "Maximize Window", "Fill the visible screen", "arrow.up.left.and.arrow.down.right") {
            ActionExecutor.executeAction(TriggerAction(actionType: .maximizeWindow))
        }

        for trigger in appState.currentPreset.triggers {
            var keys: String?
            if case .keyboardShortcut(let shortcut) = trigger.input { keys = shortcut.displayString }
            var item = PaletteItem(id: "trigger.\(trigger.id.uuidString)", title: trigger.displayName,
                                   subtitle: trigger.aomRowDetail, icon: trigger.input.category.iconName,
                                   section: .automations, shortcut: keys,
                                   primary: PaletteAction(title: "Open in Editor") {
                                       close()
                                       appState.selectedActivationGroupID = trigger.activationGroupID
                                       if trigger.activationGroupID == nil {
                                           appState.selectedAppTarget = (trigger.appBundleID ?? "").isEmpty ? .allApps
                                               : appState.currentPreset.appTargets.first { $0.bundleID == trigger.appBundleID } ?? .allApps
                                       }
                                       appState.selectedTrigger = trigger
                                       appState.selectedMainTab = .gestures
                                   })
            // Never offer a list-level run for Type Text (it could type a stored password).
            if trigger.isEnabled, !trigger.actions.isEmpty, !trigger.aomTypesText {
                item.secondary = PaletteAction(title: "Run Now") {
                    close()
                    ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                                  triggerID: trigger.id)
                }
            }
            items.append(item)
        }

        for entry in clipboardStore.entries.prefix(20) {
            items.append(PaletteItem(
                id: "clipboard.\(entry.id.uuidString)", title: entry.title,
                subtitle: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                icon: entry.kind.symbol, section: .clipboard,
                primary: PaletteAction(title: "Copy") { close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: false) },
                secondary: entry.kind == .text || entry.kind == .link
                    ? PaletteAction(title: "Copy as Plain Text") { close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: true) }
                    : nil))
        }

        for capture in captureHistory.entries.prefix(6) {
            items.append(PaletteItem(
                id: "capture.\(capture.id.uuidString)", title: capture.displayName,
                subtitle: "\(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height)) · \(AOMRelativeTime.string(capture.capturedAt))",
                icon: capture.kind == .videoRecording ? "film" : "photo", section: .captures,
                primary: PaletteAction(title: "Edit") { close(); CaptureItemActions.edit(capture) },
                secondary: PaletteAction(title: "Copy") { close(); CaptureItemActions.copy(capture) }))
        }

        for tab in AOMMainTab.allCases {
            items.append(PaletteItem(id: "go.\(tab.rawValue)", title: tab.title, subtitle: "Show \(tab.title)",
                                     icon: tab.sidebarSymbol, section: .navigation,
                                     shortcut: "⌘\(tab.shortcutKey.character)",
                                     primary: PaletteAction(title: "Open") { close(); appState.selectedMainTab = tab }))
        }
        items.append(PaletteItem(id: "go.settings", title: "Settings", subtitle: "Open All of MacOS Settings",
                                 icon: "gearshape", section: .navigation, shortcut: "⌘,",
                                 primary: PaletteAction(title: "Open") { close(); openSettings() }))
        return items
    }

    /// Searching ranks one flat list: title prefix, then title, then detail.
    private var results: [PaletteItem] {
        let items = allItems
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Section.allCases.flatMap { section in items.filter { $0.section == section } }
        }
        func rank(_ item: PaletteItem) -> Int? {
            if item.title.lowercased().hasPrefix(trimmed.lowercased()) { return 0 }
            if item.title.localizedCaseInsensitiveContains(trimmed) { return 1 }
            if item.subtitle.localizedCaseInsensitiveContains(trimmed) { return 2 }
            if item.section.rawValue.localizedCaseInsensitiveContains(trimmed) { return 3 }
            return nil
        }
        return items.compactMap { item in rank(item).map { (item, $0) } }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Body

    var body: some View {
        let items = results
        let selected = items.first { $0.id == selectedID } ?? items.first
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AOMTheme.textSecondary)
                    TextField("Search commands, automations, clipboard and captures", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFieldFocused)
                        .onChange(of: query) { _, _ in selectedID = nil }
                        .accessibilityLabel("Search")
                }
                .padding(.horizontal, AOMSpace.m)
                .frame(height: 50)

                AOMDivider()

                if items.isEmpty {
                    VStack(spacing: 6) {
                        Text("No Results for “\(query)”").font(AOMType.bodyEmphasis)
                        Text("Try an automation name, an app or a word you copied.")
                            .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    if !isSearching, index == 0 || items[index - 1].section != item.section {
                                        Text(item.section.rawValue)
                                            .font(AOMType.caption.weight(.semibold))
                                            .foregroundStyle(AOMTheme.textTertiary)
                                            .padding(.horizontal, 10)
                                            .padding(.top, index == 0 ? 4 : 10)
                                            .padding(.bottom, 4)
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                    row(item, selected: item.id == selected?.id)
                                        .id(item.id)
                                }
                            }
                            .padding(6)
                        }
                        .onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id, anchor: nil) }
                        }
                    }
                }

                AOMDivider()
                actionBar(selected)
            }
            .frame(width: 640, height: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AOMTheme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand {
            // Esc goes back one level: clear the query, then close.
            if isSearching { query = "" } else { close() }
        }
        .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.downArrow) { move(1, in: items); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard let item = selected else { return .handled }
            if press.modifiers.contains(.command) {
                item.secondary?.run()
            } else {
                item.primary.run()
            }
            return .handled
        }
    }

    private func move(_ offset: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(items.count - 1, max(0, current + offset))].id
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            selectedID = item.id
            item.primary.run()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(AOMType.body.weight(.medium))
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: AOMSpace.xs)
                if isSearching {
                    Text(item.section.rawValue).font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                }
                if let keys = item.shortcut { AOMKeycap(text: keys) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? AOMTheme.track : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The selected item's actions with their keys, Raycast-style.
    private func actionBar(_ item: PaletteItem?) -> some View {
        HStack(spacing: AOMSpace.m) {
            Text(item?.section.rawValue ?? " ")
                .font(AOMType.caption)
                .foregroundStyle(AOMTheme.textTertiary)
            Spacer()
            if let item {
                actionHint(item.primary.title, keys: "↩", prominent: true) { item.primary.run() }
                if let secondary = item.secondary {
                    actionHint(secondary.title, keys: "⌘↩", prominent: false) { secondary.run() }
                }
            }
            actionHint(isSearching ? "Clear" : "Close", keys: "esc", prominent: false) {
                if isSearching { query = "" } else { close() }
            }
        }
        .padding(.horizontal, AOMSpace.s)
        .frame(height: 38)
    }

    private func actionHint(_ title: String, keys: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(AOMType.caption.weight(prominent ? .semibold : .regular))
                    .foregroundStyle(prominent ? AOMTheme.text : AOMTheme.textSecondary)
                AOMKeycap(text: keys)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(keys)")
    }
}
