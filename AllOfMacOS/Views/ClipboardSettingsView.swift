import AppKit
import SwiftUI

@MainActor
struct ClipboardSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var shortcuts = ClipboardShortcuts.shared
    @ObservedObject private var preferences = ClipboardPreferences.shared
    @State private var recording: ClipboardShortcuts.Command?
    @State private var keyMonitor: Any?
    @State private var clearConfirmation = false
    /// A smaller item limit that would delete items, waiting for confirmation.
    @State private var pendingLimit: Int?
    /// A shorter Keep History, or a smaller storage limit, that would delete
    /// items now. Paste asks before applying either; so does AOM.
    @State private var pendingRetention: Int?
    @State private var pendingBytes: Int?
    @State private var recoverConfirmation = false
    @State private var recordingNote = ""

    init(store: ClipboardStore = .shared) { self.store = store }

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            header
            historySection
            pinboardsSection
            pastingSection
            ClipboardIntelligenceSettingsView(store: store)
            shortcutsSection
            privacySection
            excludedAppsSection
            savedItemsSection
        }
        .onDisappear { stopRecording() }
        .confirmationDialog("Erase clipboard history?", isPresented: $clearConfirmation) {
            Button("Erase History", role: .destructive) { store.eraseHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(ClipboardEraseCopy.message(unpinned: store.entries.filter { $0.pinboardIDs.isEmpty }.count)) }
        .confirmationDialog("Delete the oldest items?", isPresented: Binding(get: { pendingLimit != nil },
                                                                             set: { if !$0 { pendingLimit = nil } })) {
            if let limit = pendingLimit {
                Button("Delete \(store.itemsRemoved(byMaxEntries: limit)) Items and Apply", role: .destructive) {
                    store.applyMaxEntries(limit)
                    pendingLimit = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingLimit = nil }
        } message: {
            if let limit = pendingLimit {
                Text("A limit of \(limit) items deletes the \(store.itemsRemoved(byMaxEntries: limit)) oldest unpinned items now. Pinned items are kept, and Undo Delete brings them back.")
            }
        }
        .confirmationDialog("Delete older history?", isPresented: Binding(get: { pendingRetention != nil },
                                                                          set: { if !$0 { pendingRetention = nil } })) {
            if let days = pendingRetention {
                Button("Delete \(store.itemsRemoved(byRetentionDays: days)) Items and Apply", role: .destructive) {
                    store.applyRetentionDays(days)
                    pendingRetention = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            if let days = pendingRetention {
                Text("Keeping history for \(Self.retentionTitle(days)) deletes \(store.itemsRemoved(byRetentionDays: days)) unpinned items now. Pinned items are kept, and Undo Delete brings the others back until you quit.")
            }
        }
        .confirmationDialog("Delete the oldest items?", isPresented: Binding(get: { pendingBytes != nil },
                                                                             set: { if !$0 { pendingBytes = nil } })) {
            if let bytes = pendingBytes {
                Button("Delete \(store.itemsRemoved(byMaxBytes: bytes)) Items and Apply", role: .destructive) {
                    store.applyMaxBytes(bytes)
                    pendingBytes = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingBytes = nil }
        } message: {
            if let bytes = pendingBytes {
                Text("A storage limit of \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) deletes the \(store.itemsRemoved(byMaxBytes: bytes)) oldest unpinned items now. Pinned items are kept, and Undo Delete brings them back until you quit.")
            }
        }
        .confirmationDialog("Recover clipboard storage?", isPresented: $recoverConfirmation) {
            Button("Archive Unreadable File and Resume", role: .destructive) {
                Task { await store.recoverStorage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The unreadable file is renamed and kept; AOM then starts a new history file.") }
    }

    // MARK: - Header

    private var header: some View {
        AOMPageHeader(!store.settings.enabled ? "Clipboard history is off"
                      : (store.paused ? "Clipboard history is paused" : "Clipboard history is on"),
                      module: .clipboard,
                      subtitle: "Text, links, images, files and pinboards, encrypted on this Mac",
                      active: store.settings.enabled && !store.paused) {
            // The Clipboard page's toolbar names the same panel "Open Shelf".
            Button("Open Shelf") { ClipboardPanelController.shared.show() }
        }
    }

    // MARK: - History

    private var historySection: some View {
        // What history and pinboards take on disk sits beside the title, so
        // the section needs no footer.
        AOMSection("History",
                   detail: "\(ByteCountFormatter.string(fromByteCount: Int64(store.historyBytes), countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(store.pinnedBytes), countStyle: .file)) in pinboards",
                   help: "Unpinned history is removed when its age, item count or storage limit is reached, including with Forever selected: the item and storage limits keep the encrypted history file a manageable size. Single items larger than 20 MB are skipped. File clips save references only, not file contents.") {
            AOMToggleRow("Keep clipboard history", isOn: $store.settings.enabled)
            AOMToggleRow("Pause history", indent: true, isOn: $store.paused)
                .aomDependentRows(enabled: store.settings.enabled)
            Group {
                AOMSettingRow("Keep unpinned items",
                              help: "Pinboards are exempt from age, item count and storage limits. Pinned items stay until you delete them. Removing an item from its last pinboard returns it to history; if it is older than your history limit it is deleted, and Undo Delete brings it back.") {
                    Picker("Keep unpinned items", selection: Binding(
                        get: { store.settings.retentionDays },
                        set: { value in
                            // A shorter limit that deletes items asks first.
                            if store.itemsRemoved(byRetentionDays: value) > 0 { pendingRetention = value }
                            else { store.settings.retentionDays = value }
                        })) {
                        Text("1 Day").tag(1); Text("1 Week").tag(7); Text("1 Month").tag(30); Text("3 Months").tag(90)
                        Text("1 Year").tag(365); Text("Forever").tag(0)
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("Maximum history") {
                    HStack(spacing: AOMSpace.x2) {
                        Text("\(store.settings.maxEntries.formatted()) items")
                            .font(AOMFont.body)
                            .monospacedDigit()
                            .foregroundStyle(AOMColor.textSecondary)
                            .accessibilityHidden(true)
                        Stepper("Maximum history: \(store.settings.maxEntries) items", value: Binding(
                            get: { store.settings.maxEntries },
                            set: { value in
                                // Lowering the limit below what is stored asks first.
                                if store.itemsRemoved(byMaxEntries: value) > 0 { pendingLimit = value }
                                else { store.settings.maxEntries = value }
                            }), in: 100...10000, step: 100)
                    }
                }
                AOMSettingRow("Unpinned history storage") {
                    Picker("Unpinned history storage", selection: Binding(
                        get: { store.settings.maxBytes },
                        set: { value in
                            if store.itemsRemoved(byMaxBytes: value) > 0 { pendingBytes = value }
                            else { store.settings.maxBytes = value }
                        })) {
                        Text("50 MB").tag(50 * 1_024 * 1_024)
                        Text("200 MB").tag(200 * 1_024 * 1_024)
                        Text("500 MB").tag(500 * 1_024 * 1_024)
                        Text("1 GB").tag(1_024 * 1_024 * 1_024)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Pinboards & search

    private var pinboardsSection: some View {
        AOMSection("Pinboards & search",
                   help: "Text inside copied images is indexed locally for search, and matches are highlighted in the image. In a preview, drag over an image to read or copy part of it. Search supports phrases in quotes, type:image, from:Safari, board:Work, is:pinned, before:2026-01-01, after:7d, on:yesterday and -excluded terms. Deleting a pinboard asks whether to delete its items too, as Paste does, or keep them in history; Undo Delete restores either choice until you quit.") {
            AOMToggleRow("Search all lists from a pinboard",
                         help: "On, as in Paste: searching while a pinboard is open looks through Clipboard History and every pinboard. Add board:Name to search one pinboard. Off: searches stay inside the pinboard on screen.",
                         isOn: $store.settings.searchesAllLists)
            AOMToggleRow("Keep each item on one pinboard",
                         help: "On, as in Paste: pinning an item to another pinboard moves it there. Off: an item can be on several pinboards. Items already on several pinboards stay until you pin them again.",
                         isOn: $store.settings.onePinboardPerItem)
        }
    }

    // MARK: - Pasting

    private var pastingSection: some View {
        AOMSection("Pasting",
                   help: "Select several cards with ⌘-click to combine text, or add them to the paste stack and press ⌘V repeatedly in the destination app to insert them one at a time.") {
            AOMToggleRow("Paste directly into the previous app", help: "Turn off direct paste to copy only.",
                         isOn: $store.settings.pasteDirectly)
            AOMToggleRow("Paste text without formatting by default", isOn: $store.settings.plainText)
            AOMSettingRow("Quick Paste modifier (1–9)") {
                Picker("Quick Paste modifier (1–9)", selection: $preferences.quickModifier) {
                    ForEach(ClipboardPreferences.Modifier.allCases.filter { $0 != .shift }) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Plain Text modifier",
                          help: "Hold the Plain Text modifier while pasting to remove text formatting. Images and files keep their original clipboard representation.") {
                Picker("Plain Text modifier", selection: $preferences.plainModifier) {
                    ForEach(ClipboardPreferences.Modifier.allCases.filter { $0 != .command && $0 != preferences.quickModifier }) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
            }
            AOMToggleRow("Compact clipboard shelf", isOn: $preferences.compact)
        }
    }

    // MARK: - Keyboard shortcuts

    @ViewBuilder private var shortcutsSection: some View {
        if let conflict = ShortcutConflicts.clipboardHistoryConflict(shortcut: shortcuts.shortcut(for: .history)) {
            AOMNotice(.warning, "\(conflict.appName) also uses \(conflict.shortcut.displayString)",
                      detail: "macOS sends it to \(conflict.appName), so choose another Clipboard History shortcut or quit \(conflict.appName).")
        }
        AOMSection("Keyboard shortcuts",
                   footer: recordingNote.isEmpty ? "Escape cancels recording; Delete clears a shortcut." : recordingNote) {
            ForEach(ClipboardShortcuts.Command.allCases) { command in
                AOMSettingRow(command.title) {
                    HStack(spacing: AOMSpace.x2) {
                        Button(recording == command ? "Type shortcut…" : (shortcuts.shortcut(for: command)?.displayString ?? "Record Shortcut")) {
                            if recording == command { stopRecording() } else { startRecording(command) }
                        }
                        .frame(minWidth: AOMFeatureSize.recorderMinWidth)
                        Button { shortcuts.setShortcut(nil, for: command) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AOMColor.textSecondary)
                            .disabled(shortcuts.shortcut(for: command) == nil || recording != nil)
                            .help("Disable Shortcut")
                            .accessibilityLabel("Disable \(command.title) shortcut")
                    }
                }
            }
            AOMSettingRow("Default shortcuts", help: "Puts every clipboard shortcut back to its original keys.") {
                Button("Restore Defaults") {
                    stopRecording()
                    for command in ClipboardShortcuts.Command.allCases { shortcuts.setShortcut(command.initial, for: command) }
                }
            }
        }
    }

    // MARK: - Privacy & storage

    private var privacySection: some View {
        AOMSection("Privacy & storage",
                   help: "History is encrypted on this Mac with a key stored in your login Keychain. AOM does not upload clipboard contents or sync them to an account.") {
            AOMToggleRow("Show clipboard windows in screen sharing and recording",
                         help: "When disabled, AOM requests macOS window capture exclusion. Some capture apps may ignore this policy; test with your sharing app before displaying sensitive clips.",
                         isOn: $preferences.showInScreenCapture)
            AOMToggleRow("Allow private web previews for links",
                         help: "Off by default. Opening a link preview contacts the website and may consume one-time links or send tracking parameters. Preview cookies and website data are kept only in memory; JavaScript is disabled.",
                         isOn: $preferences.networkPreviews)
            AOMToggleRow("Show page titles and images on link cards",
                         help: "Off by default, and only with web previews allowed. Each link card shown in the shelf contacts its website once per session to read the page title, site name and preview image. Links that look like they carry a password, token or signature, and links to this Mac or your local network, are never fetched. Nothing fetched is saved to disk.",
                         indent: true, isOn: $preferences.linkCards)
                .aomDependentRows(enabled: preferences.networkPreviews)
        }
    }

    private var excludedAppsSection: some View {
        AOMSection("Excluded apps",
                   help: "Clipboard data marked confidential or transient is excluded automatically. Add apps below to skip every copy from those apps. Excluded apps are also never read for suggestions — no window title, field or screen — and never receive suggestions.",
                   footer: "Excluded application bundle IDs, one per line. Example: com.example.passwordmanager") {
            TextEditor(text: Binding(
                get: { store.settings.ignoredApps.joined(separator: "\n") },
                set: {
                    store.settings.ignoredApps = $0.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            ))
            .font(AOMFont.mono)
            .scrollContentBackground(.hidden)
            .frame(height: AOMFeatureSize.textEditorShort)
            .padding(AOMSpace.x1)
            .background(AOMColor.canvas, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                .strokeBorder(AOMColor.hairline, lineWidth: 1))
            .padding(AOMSpace.x3)
            .accessibilityLabel("Excluded application bundle IDs, one per line")
        }
    }

    // MARK: - Saved items

    @ViewBuilder private var savedItemsSection: some View {
        if let warning = store.storageWarning {
            AOMNotice(.warning, warning) {
                if store.storageStatus == .unreadableArchive {
                    Button("Recover Clipboard Storage…") { recoverConfirmation = true }
                } else {
                    Button("Retry Saving Now") { Task { await store.recoverStorage() } }
                }
            }
        }
        if let error = store.lastError {
            AOMNotice(.error, error)
        }
        AOMSection("Saved items", detail: Self.savedItemsCount(items: store.entries.count, pinboards: store.boards.count)) {
            AOMSettingRow("Undo the last deletion", detail: "Works until you quit AOM") {
                Button("Undo Delete") { _ = store.undoLastDeletion() }.disabled(!store.canUndoDeletion)
            }
            AOMSettingRow("Erase history", detail: "Pinned items are kept") {
                Button("Erase History…", role: .destructive) { clearConfirmation = true }
                    .aomDestructive()
            }
        }
    }

    /// "12 items · 1 pinboard": the title already says "saved items", and one
    /// is never "1 pinboards".
    static func savedItemsCount(items: Int, pinboards: Int) -> String {
        "\(items.formatted()) item\(items == 1 ? "" : "s") · \(pinboards.formatted()) pinboard\(pinboards == 1 ? "" : "s")"
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: return "forever"
        case 1: return "1 day"
        case 7: return "1 week"
        case 30: return "1 month"
        case 90: return "3 months"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }

    private func startRecording(_ command: ClipboardShortcuts.Command) {
        stopRecording()
        recording = command
        recordingNote = ""
        KeyboardMonitor.beginShortcutRecording()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { shortcuts.setShortcut(nil, for: command); stopRecording(); return nil }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
            guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
                recordingNote = "Include Command, Option or Control."
                return nil
            }
            if let duplicate = ClipboardShortcuts.Command.allCases.first(where: {
                $0 != command && shortcuts.shortcut(for: $0)?.keyCode == event.keyCode && shortcuts.shortcut(for: $0)?.modifiers == modifiers
            }) {
                recordingNote = "Already assigned to \(duplicate.title)."
                return nil
            }
            shortcuts.setShortcut(KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers), for: command)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if recording != nil { KeyboardMonitor.endShortcutRecording() }
        recording = nil
    }
}
