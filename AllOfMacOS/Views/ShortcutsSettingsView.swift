import SwiftUI
import AppKit

/// CleanShot X-style dedicated Shortcuts Settings View.
///
/// Provides interactive keyboard shortcut configuration for all capture tools,
/// allowing individual hotkey recording, clearing, and restoring CleanShot X defaults.
struct ShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    @State private var recordingAction: CaptureShortcutAction? = nil
    @State private var eventMonitor: Any? = nil

    private let screenCaptureActions: [CaptureShortcutAction] = [
        .captureArea,
        .captureFullscreen,
        .captureWindow,
        .recordScreen,
        .capturePreviousArea,
        .scrollingCapture
    ]

    private let utilityActions: [CaptureShortcutAction] = [
        .ocr,
        .history,
        .toggleDesktopIcons,
        .pinLast
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                headerBanner

                // Screen Capture Group
                AppleSettingsGroup("Screen Capture") {
                    ForEach(Array(screenCaptureActions.enumerated()), id: \.element.id) { index, action in
                        shortcutRow(for: action, showDivider: index < screenCaptureActions.count - 1)
                    }
                }

                // Tools & Utilities Group
                AppleSettingsGroup("Tools & Utilities") {
                    ForEach(Array(utilityActions.enumerated()), id: \.element.id) { index, action in
                        shortcutRow(for: action, showDivider: index < utilityActions.count - 1)
                    }
                }

                // Bottom Controls
                HStack {
                    Button("Restore CleanShot Defaults") {
                        shortcuts.resetToDefaults()
                    }
                    .controlSize(.small)

                    Spacer()

                    Text("Tip: Disable system shortcuts in System Settings to override ⇧⌘3 / ⇧⌘4")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - Header Banner

    private var headerBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 3, y: 1.5)
                Image(systemName: "command")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture Shortcuts")
                    .font(.system(size: 14, weight: .bold))
                Text("Trigger screenshots and tools instantly from anywhere on your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.75)
        )
    }

    // MARK: - Shortcut Row

    private func shortcutRow(for action: CaptureShortcutAction, showDivider: Bool) -> some View {
        AppleSettingsRow(
            icon: action.iconName,
            iconColor: iconColor(for: action),
            title: action.displayName,
            subtitle: subtitle(for: action),
            showDivider: showDivider
        ) {
            shortcutRecorder(for: action)
        }
    }

    private func shortcutRecorder(for action: CaptureShortcutAction) -> some View {
        let isRecording = (recordingAction == action)
        let currentShortcut = shortcuts.shortcut(for: action)

        return HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(for: action)
                }
            } label: {
                if isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                        Text("Type shortcut…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
                } else if let shortcut = currentShortcut {
                    // Keycap style badges
                    HStack(spacing: 3) {
                        ForEach(modifierSymbols(for: shortcut.modifiers), id: \.self) { sym in
                            KeycapBadge(text: sym)
                        }
                        KeycapBadge(text: keyCodeToString(shortcut.keyCode))
                    }
                } else {
                    Text("Record Shortcut")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
            }
            .buttonStyle(.plain)

            // Clear button
            if !isRecording && currentShortcut != nil {
                Button {
                    shortcuts.setShortcut(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Clear Shortcut")
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

    private func iconColor(for action: CaptureShortcutAction) -> Color {
        switch action {
        case .captureArea: return .blue
        case .captureFullscreen: return .indigo
        case .captureWindow: return .cyan
        case .recordScreen: return .red
        case .pauseRecording: return .orange
        case .allInOne: return .blue
        case .openProject: return .purple
        case .capturePreviousArea: return .teal
        case .scrollingCapture: return .purple
        case .ocr: return .orange
        case .history: return .mint
        case .toggleDesktopIcons: return .gray
        case .pinLast: return .pink
        }
    }

    private func subtitle(for action: CaptureShortcutAction) -> String {
        switch action {
        case .captureArea: return "Drag a rectangular selection"
        case .captureFullscreen: return "Grab current display or screen under pointer"
        case .captureWindow: return "Capture active (frontmost) window"
        case .recordScreen: return "Record video of screen or selected area"
        case .pauseRecording: return "Pause or resume the current recording"
        case .allInOne: return "Choose capture mode in one selection overlay"
        case .openProject: return "Reopen editable screenshot annotations"
        case .capturePreviousArea: return "Repeat the last selected capture area"
        case .scrollingCapture: return "Capture tall web pages and documents"
        case .ocr: return "Extract and copy text directly to clipboard"
        case .history: return "Slide out CleanShot capture history overlay"
        case .toggleDesktopIcons: return "Hide or restore icons on the desktop"
        case .pinLast: return "Float most recent capture on top of all windows"
        }
    }
}

// MARK: - Keycap Badge

struct KeycapBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.75)
            )
    }
}
