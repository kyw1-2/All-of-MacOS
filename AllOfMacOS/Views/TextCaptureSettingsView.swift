import SwiftUI
import AppKit

/// Settings › Capture › Text Recognition.
///
/// Languages (Automatic or an ordered list of every Vision language, named
/// in the user's locale), output options, feedback, and the Capture Text
/// shortcuts. 3.3.3: standard sections and rows, ⓘ help instead of caption
/// lines, dependent options indented and disabled under their parent.
struct TextCaptureSettingsSection: View {
    @ObservedObject private var settings = TextCaptureSettings.shared
    @ObservedObject private var textShortcuts = TextCaptureShortcuts.shared
    @ObservedObject private var captureShortcuts = CaptureShortcuts.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var customWords = TextCaptureSettings.shared.customWordsText

    private var addableLanguages: [String] {
        TextCaptureLanguages.pickerOrder().filter { !settings.selectedLanguages.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            languagesGroup
            outputGroup
            feedbackGroup
            shortcutsGroup
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Languages

    private var languagesGroup: some View {
        AOMSection("Text Recognition") {
            AOMSettingRow("Automatic Languages", detail: automaticSubtitle, symbol: "globe") {
                Toggle("Automatic languages", isOn: Binding(get: { settings.usesAutomaticLanguages },
                                                             set: { settings.setAutomaticLanguages($0) }))
                    .accessibilityLabel("Automatic languages")
            }
            if !settings.usesAutomaticLanguages { languageList }
            AOMSettingRow("Instant Recognition", symbol: "bolt.fill",
                          help: "Copy after one recognition. Turn off for slower, detailed mixed-script recognition.") {
                toggle(\.prefersFastRecognition, "Instant recognition")
            }
            AOMSettingRow("Engine", symbol: "cpu",
                          help: "Automatic uses Live Text for Korean, Chinese and Japanese primary languages.") {
                Picker("Engine", selection: Binding(get: { settings.engine }, set: { settings.engine = $0 })) {
                    ForEach(TextRecognitionEngineMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Language Correction", symbol: "character.book.closed",
                          help: "Fixes likely misreads in prose. Turn off for code and serial numbers.") {
                toggle(\.usesLanguageCorrection, "Language correction")
            }
            AOMSettingRow("Custom Words", symbol: "text.book.closed", indent: true,
                          help: "Comma-separated names and jargon to prefer.") {
                TextField("AOM, TextSniper, …", text: $customWords)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: AOMRowControlMetrics.fieldWidth)
                    .onSubmit { settings.customWordsText = customWords }
                    .onChange(of: customWords) { _, value in settings.customWordsText = value }
                    .accessibilityLabel("Custom words")
            }
            .aomDependentRows(enabled: settings.usesLanguageCorrection)
        }
    }

    /// The ordered languages, indented under Automatic Languages while it is off.
    private var languageList: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            ForEach(Array(settings.selectedLanguages.enumerated()), id: \.element) { index, code in
                HStack(spacing: AOMSpace.x2) {
                    Text("\(index + 1).")
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row, alignment: .trailing)
                    Text(TextCaptureLanguages.displayName(for: code)).font(AOMFont.callout)
                    Text(code).font(AOMFont.badge).foregroundStyle(AOMColor.textTertiary)
                    Spacer(minLength: AOMSpace.x2)
                    Button { settings.moveLanguage(code, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).accessibilityLabel("Move \(code) up")
                    Button { settings.moveLanguage(code, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == settings.selectedLanguages.count - 1)
                        .accessibilityLabel("Move \(code) down")
                    Button { settings.removeLanguage(code) } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove \(code)")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            HStack(spacing: AOMSpace.x1) {
                Menu("Add Language") {
                    ForEach(addableLanguages, id: \.self) { code in
                        Button(TextCaptureLanguages.displayName(for: code)) { settings.addLanguage(code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                AOMInfoButton("Earlier languages win when scripts look alike; other languages stay available.",
                              topic: "language order")
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, AOMSpace.rowSymbolInset + AOMSpace.x5)
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x5) }
    }

    private var automaticSubtitle: String {
        let names = TextCaptureLanguages.automaticPriority().prefix(3).map { TextCaptureLanguages.displayName(for: $0) }
        let head = names.isEmpty ? "System languages" : names.joined(separator: ", ")
        return settings.usesAutomaticLanguages ? "\(head), then every other language" : "Your order below, then every other language"
    }

    // MARK: Output

    private var outputGroup: some View {
        AOMSection("Recognized Text") {
            AOMSettingRow("Keep Line Breaks", symbol: "text.alignleft",
                          help: "Off re-flows lines into paragraphs (no spaces added between CJK lines).") {
                toggle(\.keepsLineBreaks, "Keep line breaks")
            }
            AOMSettingRow("Join Hyphenated Words", symbol: "minus", help: "“infor-” + “mation” becomes “information”.") {
                toggle(\.joinsHyphenatedWords, "Join hyphenated words")
            }
            AOMSettingRow("Additive Clipboard", symbol: "text.badge.plus",
                          help: "Append each capture to the text already on the clipboard.") {
                toggle(\.additiveClipboard, "Additive clipboard")
            }
            AOMSettingRow("Detect Links", symbol: "link", help: "Show detected web and mail links in the result HUD.") {
                toggle(\.detectsLinks, "Detect links")
            }
            AOMSettingRow("Read QR Codes and Barcodes", symbol: "qrcode",
                          help: "Add code payloads found in the selection.") {
                toggle(\.readsBarcodes, "Read QR codes and barcodes")
            }
        }
    }

    // MARK: Feedback

    private var feedbackGroup: some View {
        AOMSection("Text Capture Feedback") {
            AOMSettingRow("Play Sound", symbol: "speaker.wave.2",
                          help: "Confirm success or “nothing found” with a sound.") {
                toggle(\.playsSound, "Play sound")
            }
            AOMSettingRow("Show Result HUD", symbol: "rectangle.and.text.magnifyingglass",
                          help: "A preview with Copy, Edit, Speak and Share. Hover to keep it open.") {
                toggle(\.showsResultHUD, "Show result HUD")
            }
            AOMSettingRow("HUD Duration", symbol: "timer", indent: true) {
                Picker("HUD duration", selection: Binding(get: { Int(settings.hudDuration) },
                                                          set: { settings.hudDuration = Double($0) })) {
                    ForEach([3, 6, 10, 20], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("HUD duration")
            }
            .aomDependentRows(enabled: settings.showsResultHUD)
            AOMSettingRow("Speak Result", symbol: "waveform", help: "Read the text aloud in its detected language.") {
                toggle(\.speaksResult, "Speak result")
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsGroup: some View {
        AOMSection("Text Capture Shortcuts") {
            AOMSettingRow("Capture Text", symbol: "text.viewfinder", help: "Select an area and copy its text.") {
                recorder(id: "ocr", current: captureShortcuts.shortcut(for: .ocr)) {
                    captureShortcuts.setShortcut($0, for: .ocr)
                }
            }
            ForEach(TextCaptureShortcutAction.allCases, id: \.self) { action in
                AOMSettingRow(action.displayName, symbol: action.iconName, help: subtitle(for: action)) {
                    recorder(id: action.rawValue, current: textShortcuts.shortcut(for: action)) {
                        textShortcuts.setShortcut($0, for: action)
                    }
                }
            }
        }
    }

    private func subtitle(for action: TextCaptureShortcutAction) -> String {
        switch action {
        case .captureTextToggledLineBreaks:
            return settings.keepsLineBreaks ? "Captures with lines joined" : "Captures keeping line breaks"
        case .captureTextFromClipboard: return "Recognize the image currently on the clipboard"
        case .readQRCode: return "Select an area and copy QR / barcode contents"
        }
    }

    private func recorder(id: String, current: KeyboardShortcut?,
                          set: @escaping (KeyboardShortcut?) -> Void) -> some View {
        HStack(spacing: AOMSpace.x1) {
            Button {
                if recording == id { stopRecording() } else { startRecording(id: id, set: set) }
            } label: {
                Text(recording == id ? "Type shortcut…" : (current?.displayString ?? "Record Shortcut"))
                    .font(recording == id ? AOMFont.caption.weight(.medium) : AOMFont.caption)
                    .foregroundStyle(recording == id ? AOMColor.accent : (current == nil ? AOMColor.textSecondary : AOMColor.text))
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x1)
                    .background(AOMColor.track, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut")
            if current != nil, recording != id {
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary)
                }
                .buttonStyle(.plain).help("Clear Shortcut").accessibilityLabel("Clear shortcut")
            }
        }
    }

    private func startRecording(id: String, set: @escaping (KeyboardShortcut?) -> Void) {
        stopRecording()
        recording = id
        KeyboardMonitor.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { set(nil); stopRecording(); return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if !mods.isEmpty {
                set(KeyboardShortcut(keyCode: event.keyCode, modifiers: mods))
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if recording != nil { KeyboardMonitor.endShortcutRecording() }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// A row switch (the row draws it as the standard mini switch).
    private func toggle(_ keyPath: ReferenceWritableKeyPath<TextCaptureSettings, Bool>, _ label: String) -> some View {
        Toggle(label, isOn: Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }))
            .accessibilityLabel(label)
    }
}
