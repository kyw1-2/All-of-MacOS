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
    @State private var recoverConfirmation = false
    @State private var recordingNote = ""

    init(store: ClipboardStore = .shared) { self.store = store }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "clipboard.fill").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AOM Clipboard").font(.title2.weight(.semibold))
                        Text("A local clipboard workspace for text, links, images, files and pinboards.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Clipboard") { ClipboardPanelController.shared.show() }
                }
                GroupBox("History") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Keep clipboard history", isOn: $store.settings.enabled)
                        Toggle("Pause collection", isOn: $store.paused).disabled(!store.settings.enabled)
                        Picker("Keep unpinned items", selection: $store.settings.retentionDays) {
                            Text("1 Day").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30); Text("90 Days").tag(90); Text("Indefinitely").tag(0)
                        }
                        Stepper("Maximum history: \(store.settings.maxEntries) items", value: Binding(
                            get: { store.settings.maxEntries },
                            set: { value in
                                // Lowering the limit below what is stored asks first.
                                if store.itemsRemoved(byMaxEntries: value) > 0 { pendingLimit = value }
                                else { store.settings.maxEntries = value }
                            }), in: 100...10000, step: 100)
                        Picker("Unpinned history storage", selection: $store.settings.maxBytes) {
                            Text("50 MB").tag(50 * 1_024 * 1_024)
                            Text("200 MB").tag(200 * 1_024 * 1_024)
                            Text("500 MB").tag(500 * 1_024 * 1_024)
                            Text("1 GB").tag(1_024 * 1_024 * 1_024)
                        }
                        Text("Unpinned history is removed when its age, item count or storage limit is reached, including with Indefinitely selected. Single items larger than 20 MB are skipped. File clips save references only, not file contents.").font(.caption).foregroundStyle(.secondary)
                        Text("Pinboards are exempt from age, item count and storage limits. Pinned items stay until you delete them.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("History: \(ByteCountFormatter.string(fromByteCount: Int64(store.historyBytes), countStyle: .file)) · Pinboards: \(ByteCountFormatter.string(fromByteCount: Int64(store.pinnedBytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Pasting") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Paste directly into the previous app", isOn: $store.settings.pasteDirectly)
                        Toggle("Paste text without formatting by default", isOn: $store.settings.plainText)
                        Picker("Quick Paste modifier (1–9)", selection: $preferences.quickModifier) {
                            ForEach(ClipboardPreferences.Modifier.allCases.filter { $0 != .shift }) { Text($0.symbol).tag($0) }
                        }
                        Picker("Plain Text modifier", selection: $preferences.plainModifier) {
                            ForEach(ClipboardPreferences.Modifier.allCases.filter { $0 != .command && $0 != preferences.quickModifier }) { Text($0.symbol).tag($0) }
                        }
                        Toggle("Compact clipboard shelf", isOn: $preferences.compact)
                        Text("Turn off direct paste to copy only. Hold the Plain Text modifier while pasting to remove text formatting. Images and files keep their original clipboard representation.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Select several cards with ⌘-click to combine text, or add them to the paste stack and press ⌘V repeatedly in the destination app to insert them one at a time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                ClipboardIntelligenceSettingsView(store: store)
                if let conflict = ShortcutConflicts.clipboardHistoryConflict(shortcut: shortcuts.shortcut(for: .history)) {
                    Label("\(conflict.appName) also uses \(conflict.shortcut.displayString). macOS sends it to \(conflict.appName), so choose another Clipboard History shortcut or quit \(conflict.appName).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(AOMTheme.warning)
                }
                GroupBox("Keyboard Shortcuts") {
                    VStack(spacing: 12) {
                        ForEach(ClipboardShortcuts.Command.allCases) { command in
                            HStack {
                                Text(command.title)
                                Spacer()
                                Button(recording == command ? "Type shortcut…" : (shortcuts.shortcut(for: command)?.displayString ?? "Record Shortcut")) {
                                    if recording == command { stopRecording() } else { startRecording(command) }
                                }.frame(minWidth: 130)
                                Button { shortcuts.setShortcut(nil, for: command) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).disabled(shortcuts.shortcut(for: command) == nil || recording != nil).help("Disable Shortcut")
                            }
                        }
                        HStack {
                            Button("Restore Defaults") {
                                stopRecording()
                                for command in ClipboardShortcuts.Command.allCases { shortcuts.setShortcut(command.initial, for: command) }
                            }
                            Spacer()
                            Text(recordingNote.isEmpty ? "Escape cancels recording; Delete clears a shortcut." : recordingNote)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10)
                }
                GroupBox("Privacy & Storage") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show clipboard windows in screen sharing and recording", isOn: $preferences.showInScreenCapture)
                        Text("When disabled, AOM requests macOS window capture exclusion. Some capture apps may ignore this policy; test with your sharing app before displaying sensitive clips.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow private web previews for links", isOn: $preferences.networkPreviews)
                        Text("Off by default. Opening a link preview contacts the website and may consume one-time links or send tracking parameters. Preview cookies and website data are kept only in memory; JavaScript is disabled.").font(.caption).foregroundStyle(.secondary)
                        Text("History is encrypted on this Mac with a key stored in your login Keychain. AOM does not upload clipboard contents or sync them to an account.").font(.callout)
                        Text("Text inside copied images is indexed locally for search. Search supports phrases in quotes, type:image, from:Safari, board:Work, before:2026-01-01, after:2026-01-01 and -excluded terms.").font(.caption).foregroundStyle(.secondary)
                        Text("Clipboard data marked confidential or transient is excluded automatically. Add apps below to skip every copy from those apps. Excluded apps are also never read for suggestions — no window title, field or screen — and never receive suggestions.").font(.caption).foregroundStyle(.secondary)
                        Text("Excluded application bundle IDs, one per line").font(.caption.weight(.semibold))
                        TextEditor(text: Binding(
                            get: { store.settings.ignoredApps.joined(separator: "\n") },
                            set: {
                                store.settings.ignoredApps = $0.components(separatedBy: .newlines)
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        )).font(.system(.body, design: .monospaced)).frame(height: 90)
                            .padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                        Text("Example: com.example.passwordmanager").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(store.entries.count) saved items · \(store.boards.count) pinboards").foregroundStyle(.secondary)
                            Spacer()
                            Button("Undo Delete") { _ = store.undoDeletion() }.disabled(!store.canUndoDeletion)
                            Button("Erase History…", role: .destructive) { clearConfirmation = true }
                        }
                        if let warning = store.storageWarning {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AOMTheme.warning)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(warning).font(.caption)
                                    if store.storageStatus == .unreadableArchive {
                                        Button("Recover Clipboard Storage…") { recoverConfirmation = true }
                                            .controlSize(.small)
                                    } else {
                                        Button("Retry Saving Now") { Task { await store.recoverStorage() } }
                                            .controlSize(.small)
                                    }
                                }
                            }
                        }
                        if let error = store.lastError { Text(error).foregroundStyle(AOMTheme.danger).font(.caption) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
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
        .confirmationDialog("Recover clipboard storage?", isPresented: $recoverConfirmation) {
            Button("Archive Unreadable File and Resume", role: .destructive) {
                Task { await store.recoverStorage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The unreadable file is renamed and kept; AOM then starts a new history file.") }
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
