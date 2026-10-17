import AppKit
import SwiftUI

@MainActor
struct ClipboardSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var shortcuts = ClipboardShortcuts.shared
    @State private var recording: ClipboardShortcuts.Command?
    @State private var keyMonitor: Any?
    @State private var clearConfirmation = false
    @State private var recordingNote = ""

    init(store: ClipboardStore = .shared) { self.store = store }

    var body: some View {
        ScrollView {
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
                        Stepper("Maximum history: \(store.settings.maxEntries) items", value: $store.settings.maxEntries, in: 100...10000, step: 100)
                        Picker("Unpinned history storage", selection: $store.settings.maxBytes) {
                            Text("50 MB").tag(50 * 1_024 * 1_024)
                            Text("200 MB").tag(200 * 1_024 * 1_024)
                            Text("500 MB").tag(500 * 1_024 * 1_024)
                            Text("1 GB").tag(1_024 * 1_024 * 1_024)
                        }
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
                        Text("Turn off direct paste to copy only. Hold Shift while pasting to remove text formatting. Images and files keep their original clipboard representation.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Select several cards with ⌘-click to combine text, or add them to the paste stack and press ⌘V repeatedly in the destination app to insert them one at a time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                ClipboardIntelligenceSettingsView(store: store)
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
                        Text("History is encrypted on this Mac with a key stored in your login Keychain. AOM does not upload clipboard contents or sync them to an account.").font(.callout)
                        Text("Text inside copied images is indexed locally for search. Search supports phrases in quotes, type:image, from:Safari, board:Work, before:2026-01-01, after:2026-01-01 and -excluded terms.").font(.caption).foregroundStyle(.secondary)
                        Text("Clipboard data marked confidential or transient is excluded automatically. Add apps below to skip every copy from those apps.").font(.caption).foregroundStyle(.secondary)
                        Text("Excluded application bundle IDs, one per line").font(.caption.weight(.semibold))
                        TextEditor(text: Binding(
                            get: { store.settings.ignoredApps.joined(separator: "\n") },
                            set: { store.settings.ignoredApps = $0.components(separatedBy: .newlines) }
                        )).font(.system(.body, design: .monospaced)).frame(height: 90)
                            .padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                        Text("Example: com.example.passwordmanager").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(store.entries.count) saved items · \(store.boards.count) pinboards").foregroundStyle(.secondary)
                            Spacer()
                            Button("Undo Delete") { _ = store.undoDeletion() }.disabled(!store.canUndoDeletion)
                            Button("Clear Unpinned History…", role: .destructive) { clearConfirmation = true }
                        }
                        if let error = store.lastError { Text(error).foregroundStyle(.red).font(.caption) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }
        .onDisappear { stopRecording() }
        .confirmationDialog("Clear all unpinned clipboard history?", isPresented: $clearConfirmation) {
            Button("Clear Unpinned History", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Pinned items and the current system clipboard will be kept.") }
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
