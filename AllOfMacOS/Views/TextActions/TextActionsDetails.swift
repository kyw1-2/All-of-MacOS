import AppKit
import SwiftUI

// The detail column of the Text Actions page: the bar itself, the excluded
// apps, or one action.

/// The one or two notices the page shows when the bar cannot appear:
/// Accessibility is off, or AOM is paused. Nothing shows while all is well.
struct TextActionsStatusNotices: View {
    let isOn: Bool
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var suppression = TriggerSuppression.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Group {
            if !trusted {
                AOMNotice(.warning, "Accessibility is off, so Text Actions can't read the selection.",
                          detail: "Allow All of MacOS in Privacy & Security › Accessibility.") {
                    Button("Allow…") { _ = AOMPermission.accessibility.openSettings() }
                }
            } else if isOn && (!appState.globalEnabled || suppression.pause.isGloballyPaused) {
                AOMNotice(.info, "AOM is paused, so the bar doesn't appear.",
                          detail: Self.pauseDetail(suppression.pause)) {
                    Button("Resume") {
                        if !appState.globalEnabled { appState.toggleGlobalEnabled() }
                        TriggerSuppression.shared.resume()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityLost)) { _ in trusted = false }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityRecovered)) { _ in trusted = true }
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    /// The timed pause's end, read without touching the pause state (a view
    /// update must not publish).
    static func pauseDetail(_ pause: TriggerSuppression.PauseState) -> String? {
        if pause.indefinite { return "Paused until resumed" }
        return pause.until.map { TriggerSuppressionReason.paused(until: $0).description }
    }
}

/// "Selection Bar": the master switch, the live preview, the triggers, the
/// timing and placement, the Copy fallback and the shortcut.
struct TextActionsBarDetail: View {
    @Binding var settings: TextActionsSettings
    @State private var sample: TextActionsPreviewSample = .text
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader(settings.isOn ? "Text Actions is on" : "Text Actions is off", module: .textActions,
                          subtitle: "Actions over the text you select in any app",
                          help: "Select text in any app and a bar appears above it: copy, search, translate, look up, calculate and more. It never takes the keyboard, and it stays out of password fields and the apps you exclude.",
                          active: settings.isOn) {
                Toggle("Text Actions", isOn: $settings.isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(settings.isOn ? "Stop showing the bar over selected text" : "Show the bar over selected text")
                    .accessibilityLabel("Text Actions")
            }
            TextActionsStatusNotices(isOn: settings.isOn)

            AOMSection("Preview", footer: "Point at an item to see what it does. Some appear only for the text they fit, such as Open Link for a web address.",
                       padding: AOMSpace.cardPadding) {
                Picker("Sample", selection: $sample) {
                    ForEach(TextActionsPreviewSample.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("The kind of text the preview selects")
                .accessibilityLabel("Sample text")
            } content: {
                TextActionsPreviewBox(settings: settings, sample: sample)
            }

            AOMSection("Show the bar when") {
                AOMToggleRow("Dragging across text", isOn: $settings.showsOnDrag)
                AOMToggleRow("Double- or triple-clicking text", detail: "A word, a line or a paragraph", isOn: $settings.showsOnDoubleClick)
                AOMToggleRow("Selecting with ⇧ and the arrow keys", detail: "Once the keys rest for a moment",
                             isOn: $settings.showsOnKeyboardSelection)
            }
            .aomDependentRows(enabled: settings.isOn)

            AOMSection("Timing and position") {
                AOMSettingRow("Show after") {
                    AOMRowSlider("Show after", value: $settings.showDelay, in: TextActionsSettings.showDelayRange, step: 0.05,
                                 format: AOMRowSlider.seconds)
                }
                AOMSettingRow("Position") {
                    Picker("Position", selection: $settings.position) {
                        ForEach(TextActionBarPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("Hide after", detail: "Once the pointer is away from the bar") {
                    AOMRowSlider("Hide after", value: $settings.hideDelay, in: TextActionsSettings.hideDelayRange, step: 0.5,
                                 format: AOMRowSlider.seconds)
                }
                AOMToggleRow("Show action names", detail: "Names next to the icons", isOn: $settings.showsNames)
            }

            AOMSection("Apps that hide their selection",
                       footer: "Some web views and Electron apps don't share the selection with Accessibility. This is off until you turn it on.") {
                AOMToggleRow("Use Copy to read the selection",
                             detail: "Presses ⌘C, then puts the clipboard back; clipboard history skips it",
                             help: "Only when an app shares nothing, never in password fields or under secure keyboard entry. File selections in Finder are ignored.",
                             isOn: $settings.readsWithCopy)
            }

            AOMSection("Shortcut") {
                AOMSettingRow("Show Text Actions", detail: shortcutDetail) {
                    Button("Change…") { showShortcutSettings() }
                        .help("Set the shortcut in Settings › Shortcuts")
                }
            }
        }
    }

    private var shortcutDetail: String {
        if let shortcut = shortcuts.shortcut(for: .showTextActions) {
            return "\(shortcut.displayString) shows the bar for the selection, even with the switch off"
        }
        return "No shortcut yet; one shows the bar for the selection, even with the switch off"
    }

    private func showShortcutSettings() {
        guard !PresetManager.isUIPreview else { return }
        openSettings()
        // The Settings window listens once it exists.
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue)
            }
        }
    }
}

/// "Excluded Apps": where the bar never appears.
struct TextActionsExcludedAppsDetail: View {
    @Binding var settings: TextActionsSettings

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader("Excluded Apps", symbol: "hand.raised.fill",
                          subtitle: settings.excludedApps.isEmpty ? "The bar can appear in every app"
                                                                  : "The bar never appears in \(Self.count(settings.excludedApps.count))")
            AOMSection("Apps", footer: "Password managers start on the list. In every app the bar also stays out of password fields and secure keyboard entry, and while AOM is paused.") {
                TextActionsAppList(bundleIDs: $settings.excludedApps)
            }
        }
    }

    static func count(_ apps: Int) -> String { apps == 1 ? "1 app" : "\(apps) apps" }
}

/// One action: its switch, what it does, its options and a preview with a
/// sample that brings it out.
struct TextActionDetail: View {
    let id: TextActionID
    @Binding var settings: TextActionsSettings
    @ObservedObject private var clipboard = ClipboardStore.shared

    private var isOn: Binding<Bool> {
        Binding(get: { settings.isOn(id) }, set: { settings.setAction(id, isOn: $0) })
    }

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader(id.title, symbol: id.symbol, subtitle: id.detail, active: settings.isOn(id)) {
                Toggle(id.title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(settings.isOn(id) ? "Leave \(id.title) off the bar" : "Put \(id.title) on the bar")
                    .accessibilityLabel(id.title)
            }
            AOMSection("Preview", footer: previewFooter, padding: AOMSpace.cardPadding) {
                TextActionsPreviewBox(settings: previewSettings, sample: TextActionsPreviewSample.best(for: id))
            }
            options
        }
    }

    /// The preview shows the bar with this action on, so an action that is
    /// off can be seen before it is switched on.
    private var previewSettings: TextActionsSettings {
        var preview = settings
        preview.setAction(id, isOn: true)
        return preview
    }

    private var previewFooter: String {
        let when = Self.appearsWhen(id)
        return settings.isOn(id) ? when : "\(when) Shown here as if it were on."
    }

    @ViewBuilder
    private var options: some View {
        switch id {
        case .search:
            AOMSection("Search with") {
                AOMSettingRow("Search engine") {
                    Picker("Search engine", selection: $settings.searchEngine) {
                        ForEach(TextSearchEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if settings.searchEngine == .custom {
                    AOMSettingRow("Address", detail: customDetail) {
                        TextField("Address", text: $settings.customSearchURL, prompt: Text("https://example.com/?q={query}"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: AOMRowControlMetrics.fieldWidth)
                    }
                }
            }
        case .translate:
            AOMSection("Translate with", footer: "With Detect Language, text already in the target language goes to English (or from English to the other language you use).") {
                AOMSettingRow("Translator") {
                    Picker("Translator", selection: $settings.translator) {
                        ForEach(TextTranslator.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("From") {
                    Picker("From", selection: $settings.translateFrom) {
                        Text(TextTranslateLanguage.automatic.name).tag(TextTranslateLanguage.automatic.code)
                        Divider()
                        ForEach(TextTranslateLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("To") {
                    Picker("To", selection: $settings.translateTo) {
                        ForEach(TextTranslateLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                }
            }
        case .pinToClipboard:
            AOMSection("Pin to", footer: "The text is kept as a Clipboard item on this pinboard, even when Clipboard history is paused. Apps Clipboard never records stay unrecorded.") {
                AOMSettingRow("Pinboard") {
                    Picker("Pinboard", selection: $settings.pinboardID) {
                        Text("Text Actions (made when needed)").tag(UUID?.none)
                        if !clipboard.boards.isEmpty { Divider() }
                        ForEach(clipboard.boards) { board in Text(board.name).tag(Optional(board.id)) }
                    }
                    .pickerStyle(.menu)
                }
            }
        case .askChatGPT:
            AOMSection("ChatGPT", footer: "The selected text is never uploaded automatically. Click Ask ChatGPT, review the clipboard, then paste. Leave the instruction empty to copy the original selection.") {
                AOMSettingRow("ChatGPT app", detail: TextActionPerformer.chatGPTApplicationURL() == nil
                              ? "Not installed: the action appears once it is" : "Installed") {
                    EmptyView()
                }
                AOMSettingRow("Custom AI instruction", detail: "Use {text} where the selection should appear. Without it, text is appended.") {
                    TextField("e.g. Explain in Korean: {text}", text: $settings.customChatGPTPrompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMRowControlMetrics.fieldWidth)
                }
            }
        case .calculate:
            AOMSection("Result") {
                AOMSettingRow("Click", detail: "Copies the result") { EmptyView() }
                AOMSettingRow("⌥-click", detail: "Replaces the selection with the result, in text you can edit") { EmptyView() }
            }
        case .changeCase, .formatJSON, .urlCoding, .base64, .markdown:
            AOMSection("Result", footer: "In text you can't edit, the result is copied instead.") {
                AOMSettingRow("Click", detail: "Replaces the selection") { EmptyView() }
                AOMSettingRow("⌥-click", detail: "Copies the result and leaves the text as it is") { EmptyView() }
            }
        default:
            EmptyView()
        }
    }

    private var customDetail: String {
        settings.customSearchURL.isEmpty || TextActionURLs.isValidTemplate(settings.customSearchURL)
            ? "{query} becomes the selected text"
            : "Needs {query} and no spaces"
    }

    /// When an action shows on the bar.
    static func appearsWhen(_ id: TextActionID) -> String {
        switch id {
        case .cut, .paste: return "Appears in text you can edit."
        case .openLink: return "Appears when the selection is a web address, such as naver.com or https://…"
        case .newEmail: return "Appears when the selection is an email address."
        case .lookUp: return "Appears for a word or a short phrase."
        case .translate: return "Appears for text with letters."
        case .calculate: return "Appears for a sum or a unit conversion, such as 12 × 7 or 10 km to mi."
        case .askChatGPT: return "Appears when the ChatGPT app is installed."
        case .changeCase: return "Appears for text with upper- and lowercase letters."
        case .formatJSON: return "Appears when the selection is valid JSON."
        case .urlCoding: return "Decode appears when the text holds %-escapes."
        case .base64: return "Decode appears when the text is Base64."
        default: return "Appears for any selected text."
        }
    }
}
