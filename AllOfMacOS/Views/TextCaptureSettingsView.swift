import SwiftUI
import AppKit

/// Settings › Capture › Text Recognition.
///
/// Languages (Automatic or an ordered list of every Vision language, named
/// in the user's locale), output options, feedback, and the Capture Text
/// shortcuts.
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
        VStack(spacing: 18) {
            languagesGroup
            outputGroup
            feedbackGroup
            shortcutsGroup
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Languages

    private var languagesGroup: some View {
        AppleSettingsGroup("Text Recognition") {
            AppleSettingsRow(icon: "globe", iconColor: .blue, title: "Automatic Languages",
                             subtitle: automaticSubtitle, showDivider: true) {
                Toggle("", isOn: Binding(get: { settings.usesAutomaticLanguages },
                                         set: { settings.setAutomaticLanguages($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Automatic languages")
            }
            if !settings.usesAutomaticLanguages {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(settings.selectedLanguages.enumerated()), id: \.element) { index, code in
                        HStack(spacing: 8) {
                            Text("\(index + 1).").font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            Text(TextCaptureLanguages.displayName(for: code)).font(.system(size: 12))
                            Text(code).font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
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
                    HStack {
                        Menu("Add Language") {
                            ForEach(addableLanguages, id: \.self) { code in
                                Button(TextCaptureLanguages.displayName(for: code)) { settings.addLanguage(code) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                        Text("Earlier languages win when scripts look alike; other languages stay available.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            AppleSettingsRow(icon: "bolt.fill", iconColor: .yellow, title: "Instant Recognition",
                             subtitle: "One fast pass like TextSniper; mixed scripts still get the full multi-pass read",
                             showDivider: true) {
                toggle(\.prefersFastRecognition, "Instant recognition")
            }
            AppleSettingsRow(icon: "cpu", iconColor: .purple, title: "Engine",
                             subtitle: "Automatic reads each script separately and cross-checks with Live Text",
                             showDivider: true) {
                Picker("", selection: Binding(get: { settings.engine }, set: { settings.engine = $0 })) {
                    ForEach(TextRecognitionEngineMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 230)
            }
            AppleSettingsRow(icon: "character.book.closed", iconColor: .teal, title: "Language Correction",
                             subtitle: "Fixes likely misreads in prose; turn off for code and serial numbers",
                             showDivider: settings.usesLanguageCorrection) {
                toggle(\.usesLanguageCorrection, "Language correction")
            }
            if settings.usesLanguageCorrection {
                AppleSettingsRow(icon: "text.book.closed", iconColor: .indigo, title: "Custom Words",
                                 subtitle: "Comma-separated names and jargon to prefer", showDivider: false) {
                    TextField("AOM, TextSniper, …", text: $customWords)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit { settings.customWordsText = customWords }
                        .onChange(of: customWords) { _, value in settings.customWordsText = value }
                        .accessibilityLabel("Custom words")
                }
            }
        }
    }

    private var automaticSubtitle: String {
        let names = TextCaptureLanguages.automaticPriority().prefix(3).map { TextCaptureLanguages.displayName(for: $0) }
        let head = names.isEmpty ? "System languages" : names.joined(separator: ", ")
        return settings.usesAutomaticLanguages ? "\(head), then every other language" : "Your order below, then every other language"
    }

    // MARK: Output

    private var outputGroup: some View {
        AppleSettingsGroup("Recognized Text") {
            AppleSettingsRow(icon: "text.alignleft", iconColor: .green, title: "Keep Line Breaks",
                             subtitle: "Off re-flows lines into paragraphs (no spaces added between CJK lines)",
                             showDivider: true) { toggle(\.keepsLineBreaks, "Keep line breaks") }
            AppleSettingsRow(icon: "minus", iconColor: .gray, title: "Join Hyphenated Words",
                             subtitle: "“infor-” + “mation” becomes “information”", showDivider: true) {
                toggle(\.joinsHyphenatedWords, "Join hyphenated words")
            }
            AppleSettingsRow(icon: "text.badge.plus", iconColor: .orange, title: "Additive Clipboard",
                             subtitle: "Append each capture to the text already on the clipboard", showDivider: true) {
                toggle(\.additiveClipboard, "Additive clipboard")
            }
            AppleSettingsRow(icon: "link", iconColor: .blue, title: "Detect Links",
                             subtitle: "Show detected web and mail links in the result HUD", showDivider: true) {
                toggle(\.detectsLinks, "Detect links")
            }
            AppleSettingsRow(icon: "qrcode", iconColor: .brown, title: "Read QR Codes and Barcodes",
                             subtitle: "Add code payloads found in the selection", showDivider: false) {
                toggle(\.readsBarcodes, "Read QR codes and barcodes")
            }
        }
    }

    // MARK: Feedback

    private var feedbackGroup: some View {
        AppleSettingsGroup("Text Capture Feedback") {
            AppleSettingsRow(icon: "speaker.wave.2", iconColor: .green, title: "Play Sound",
                             subtitle: "Confirm success or “nothing found” with a sound", showDivider: true) {
                toggle(\.playsSound, "Play sound")
            }
            AppleSettingsRow(icon: "rectangle.and.text.magnifyingglass", iconColor: .indigo, title: "Show Result HUD",
                             subtitle: "Preview with Copy, Edit, Speak and Share; hover to keep it open",
                             showDivider: true) {
                HStack(spacing: 8) {
                    if settings.showsResultHUD {
                        Picker("", selection: Binding(get: { Int(settings.hudDuration) },
                                                      set: { settings.hudDuration = Double($0) })) {
                            ForEach([3, 6, 10, 20], id: \.self) { Text("\($0) s").tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 70)
                        .accessibilityLabel("HUD duration")
                    }
                    toggle(\.showsResultHUD, "Show result HUD")
                }
            }
            AppleSettingsRow(icon: "waveform", iconColor: .pink, title: "Speak Result",
                             subtitle: "Read the text aloud in its detected language", showDivider: false) {
                toggle(\.speaksResult, "Speak result")
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsGroup: some View {
        AppleSettingsGroup("Text Capture Shortcuts") {
            AppleSettingsRow(icon: "text.viewfinder", iconColor: .orange, title: "Capture Text",
                             subtitle: "Select an area and copy its text", showDivider: true) {
                recorder(id: "ocr", current: captureShortcuts.shortcut(for: .ocr)) {
                    captureShortcuts.setShortcut($0, for: .ocr)
                }
            }
            ForEach(Array(TextCaptureShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                AppleSettingsRow(icon: action.iconName, iconColor: .orange, title: action.displayName,
                                 subtitle: subtitle(for: action),
                                 showDivider: index < TextCaptureShortcutAction.allCases.count - 1) {
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
        HStack(spacing: 6) {
            Button {
                if recording == id { stopRecording() } else { startRecording(id: id, set: set) }
            } label: {
                Text(recording == id ? "Type shortcut…" : (current?.displayString ?? "Record Shortcut"))
                    .font(.system(size: 11, weight: recording == id ? .medium : .regular))
                    .foregroundStyle(recording == id ? Color.accentColor : (current == nil ? .secondary : .primary))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut")
            if current != nil, recording != id {
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
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

    private func toggle(_ keyPath: ReferenceWritableKeyPath<TextCaptureSettings, Bool>, _ label: String) -> some View {
        Toggle("", isOn: Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(label)
    }
}
