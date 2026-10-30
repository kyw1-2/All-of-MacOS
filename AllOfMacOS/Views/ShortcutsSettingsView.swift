import SwiftUI
import AppKit

/// CleanShot X-style dedicated Shortcuts Settings View.
///
/// Provides interactive keyboard shortcut configuration for all capture tools,
/// allowing individual hotkey recording, clearing, and restoring CleanShot X defaults.
struct ShortcutsSettingsView: View {
    /// The page header; Settings' own pane header names the page there.
    var showsBanner = true
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    @State private var recordingAction: CaptureShortcutAction? = nil
    @State private var eventMonitor: Any? = nil

    /// Derived from the enum's own category metadata, so a new action can
    /// never ship registered-but-invisible again (the audit's completeness gap:
    /// pauseRecording, allInOne and openProject were missing from the lists).
    private static let groupOrder = ["Screen Capture", "Tools & Utilities", "Always on Top", "System & Switching"]

    private var groups: [(name: String, actions: [CaptureShortcutAction])] {
        Self.groupOrder.compactMap { name in
            let actions = CaptureShortcutAction.allCases.filter { $0.categoryName == name }
            return actions.isEmpty ? nil : (name, actions)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                if showsBanner { headerBanner }

                // Restore sits on the first section's title row, the recorder
                // tips under the last card; no separate Defaults card.
                ForEach(groups, id: \.name) { group in
                    AOMSection(group.name,
                               detail: "\(group.actions.filter { shortcuts.shortcut(for: $0) != nil }.count) of \(group.actions.count) set",
                               footer: group.name == groups.last?.name ? Self.recorderTips : nil,
                               accessory: {
                                   if group.name == groups.first?.name { restoreDefaultsLink }
                               }) {
                        ForEach(group.actions) { action in
                            shortcutRow(for: action)
                        }
                    }
                }
            }
            .frame(maxWidth: AOMSize.readableWidth - AOMSpace.pageMargin * 2, alignment: .leading)
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.top, AOMSpace.x3)
            .padding(.bottom, AOMSpace.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private static let recorderTips = "Escape cancels recording; Delete clears a shortcut. To use ⇧⌘3 or ⇧⌘4, "
        + "turn them off in System Settings › Keyboard › Keyboard Shortcuts."

    /// Scoped: Screen Capture and Tools & Utilities only; pinning, switching
    /// and Keep Awake assignments survive (`resetCaptureDefaults`).
    private var restoreDefaultsLink: some View {
        AOMCardLink("Restore Capture Defaults", symbol: nil) {
            shortcuts.resetCaptureDefaults()
        }
        .accessibilityHint("Pinning, switching and Keep Awake keep their keys")
    }

    // MARK: - Header

    private var headerBanner: some View {
        AOMPageHeader("Capture shortcuts", symbol: "command",
                      subtitle: "Trigger screenshots and tools instantly from anywhere on your Mac",
                      help: "Click a shortcut, then press the new keys with at least one modifier. Escape cancels, and Delete clears the shortcut.")
    }

    // MARK: - Shortcut Row

    private func shortcutRow(for action: CaptureShortcutAction) -> some View {
        AOMInlineSettingRow(action.displayName, detail: subtitle(for: action), symbol: action.iconName) {
            shortcutRecorder(for: action)
        }
    }

    private func shortcutRecorder(for action: CaptureShortcutAction) -> some View {
        let isRecording = (recordingAction == action)
        let currentShortcut = shortcuts.shortcut(for: action)
        let shape = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)

        return HStack(spacing: AOMSpace.x2) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(for: action)
                }
            } label: {
                if isRecording {
                    HStack(spacing: AOMSpace.x1) {
                        Circle()
                            .fill(AOMColor.accent)
                            .frame(width: AOMIcon.dot, height: AOMIcon.dot)
                        Text("Type shortcut…")
                            .font(AOMFont.caption.weight(.medium))
                            .foregroundStyle(AOMColor.accent)
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x1)
                    .background(shape.fill(AOMColor.accent.opacity(0.12)))
                    .overlay(shape.strokeBorder(AOMColor.accent, lineWidth: 1.5))
                } else if let shortcut = currentShortcut {
                    // One keycap per key, the shared keycap style.
                    HStack(spacing: AOMSpace.x0_5 + 1) {
                        ForEach(modifierSymbols(for: shortcut.modifiers), id: \.self) { sym in
                            KeycapBadge(text: sym)
                        }
                        KeycapBadge(text: keyCodeToString(shortcut.keyCode))
                    }
                } else {
                    Text("Record Shortcut")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, AOMSpace.x2)
                        .padding(.vertical, AOMSpace.x1)
                        .background(shape.fill(AOMColor.track))
                }
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new shortcut, or Escape to cancel" : "Click to record a new shortcut")

            // Clear button
            if !isRecording && currentShortcut != nil {
                Button {
                    shortcuts.setShortcut(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear Shortcut")
                .accessibilityLabel("Clear the \(action.displayName) shortcut")
            }
        }
    }

    // MARK: - Recording Logic

    private func startRecording(for action: CaptureShortcutAction) {
        stopRecording()
        recordingAction = action
        KeyboardMonitor.beginShortcutRecording()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // ESC cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Backspace or Delete clears shortcut
            if event.keyCode == 51 || event.keyCode == 117 {
                shortcuts.setShortcut(nil, for: action)
                stopRecording()
                return nil
            }

            let cleanMods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            // Only accept when at least one modifier key is pressed
            if !cleanMods.isEmpty {
                let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: cleanMods)
                shortcuts.setShortcut(shortcut, for: action)
                stopRecording()
                return nil
            }

            return nil
        }
    }

    private func stopRecording() {
        if recordingAction != nil { KeyboardMonitor.endShortcutRecording() }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingAction = nil
    }

    // MARK: - Helpers

    private func modifierSymbols(for flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("⌃") }
        if flags.contains(.option) { result.append("⌥") }
        if flags.contains(.shift) { result.append("⇧") }
        if flags.contains(.command) { result.append("⌘") }
        if flags.contains(.function) { result.append("fn") }
        return result
    }

    private func subtitle(for action: CaptureShortcutAction) -> String {
        switch action {
        case .captureArea: return "Drag a rectangular selection"
        case .captureFullscreen: return "The display under the pointer"
        case .captureWindow: return "Pick a window to capture"
        case .recordScreen: return "Record the screen or an area"
        case .pauseRecording: return "Pause or resume the current recording"
        case .allInOne: return "Choose the capture mode in one overlay"
        case .openProject: return "Reopen editable screenshot annotations"
        case .capturePreviousArea: return "Repeat the last selected capture area"
        case .scrollingCapture: return "Capture tall web pages and documents"
        case .ocr: return "Recognize text in a region and copy it"
        case .history: return "Slide out the capture history overlay"
        case .toggleDesktopIcons: return "Hide or restore icons on the desktop"
        case .pinLast: return "Float the latest capture above all windows"
        case .choosePinnedWindow: return "Pick a live window from thumbnail previews"
        case .selectPinnedWindow: return "Point at a window, then click to pin or unpin"
        case .togglePinFrontWindow: return "Keep the front window on top, or release it"
        case .togglePinWindowUnderCursor: return "Keep the window under the pointer on top, or release it"
        case .unpinAllWindows: return "Release every pinned window; the windows stay open"
        case .windowSwitcher: return "Switch windows with thumbnails"
        case .keepAwake: return "Keep the Mac awake, or let it sleep again"
        case .appAudioMixer: return "Per-app volume and mute panel (macOS 14.2+)"
        case .muteFrontAppAudio: return "Mute or unmute the front app's audio"
        }
    }
}

// MARK: - Keycap Badge

/// A key in a shortcut. Renders the one shared keycap (`AOMKeycap`), so
/// shortcuts look the same in Settings, the ⌘K palette and Workspace.
struct KeycapBadge: View {
    let text: String

    var body: some View {
        AOMKeycap(text: text)
    }
}
