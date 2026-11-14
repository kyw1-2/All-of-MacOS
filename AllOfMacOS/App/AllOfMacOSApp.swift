import SwiftUI
import AppKit

@main
enum AOMLauncher {
    private static var instanceLease: SingleInstanceLease?
    static func main() {
        let args = ProcessInfo.processInfo.arguments
        // AI tools launch `AllOfMacOS --mcp` as a stdio MCP server; it only
        // bridges to the running app and never starts a second UI instance.
        if args.contains("--mcp") { ClipboardMCPBridge.run(arguments: args) }
        // A malformed preview launch must never fall back to the real preset.
        if (args.contains("--aom-ui-preview") || Bundle.main.bundleIdentifier == "com.kyw.allofmacos.preview") && !PresetManager.isUIPreview {
            fputs("UI preview requires an isolated temporary directory.\n", stderr); exit(2)
        }
        if let i = args.firstIndex(of: "--aom-restore-audio"), args.indices.contains(i + 1) {
            let before = AudioOutputRestore.defaultOutputUID() ?? ""
            let restored = AudioOutputRestore.restoreIfNeeded(reason: "command line")
            let after = AudioOutputRestore.defaultOutputUID() ?? ""
            let result: [String: Any] = ["restored": restored, "before": before, "after": after]
            writeCheck(result, path: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--aom-select-audio"), args.indices.contains(i + 2) {
            _ = NSApplication.shared
            let name = args[i + 1]
            var completed = false; var success = false
            let before = AudioOutputService.currentDeviceID()
            AudioOutputService.shared.select(name: name, uid: nil) { ok in success = ok; completed = true }
            let deadline = Date().addingTimeInterval(20)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let result: [String: Any] = ["requested": name, "success": success && completed,
                "accessibility": AXIsProcessTrusted(), "before": before.map(Int.init) ?? -1,
                "after": AudioOutputService.currentDeviceID().map(Int.init) ?? -1]
            writeCheck(result, path: args[i + 2]); exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-adjust-volume"), args.indices.contains(i + 2), let delta = Double(args[i + 1]), abs(delta) <= 6 {
            _ = NSApplication.shared
            let before = AudioOutputService.currentVolume()
            var completed = false; var success = false
            AudioOutputService.shared.adjustVolume(percentagePoints: delta) { ok in success = ok; completed = true }
            let deadline = Date().addingTimeInterval(3)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            writeCheck(["success": success && completed, "deltaPercentagePoints": delta,
                        "before": before.map(Double.init) ?? -1, "after": AudioOutputService.currentVolume().map(Double.init) ?? -1], path: args[i + 2])
            exit(success && completed ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--aom-check-xpc"), args.indices.contains(i + 1) {
            _ = NSApplication.shared
            let cases: [(String, String, Double, Int32, Bool)] = [
                ("shell", "sleep 0.2; printf xpc-ok", 2, 0, false),
                ("applescript", "return \"xpc-apple-ok\"", 2, 0, false),
                ("shell", "exit 7", 2, 7, false),
                ("shell", "yes x | head -c 200000", 2, 0, false),
                ("shell", "sleep 30 & echo $!; wait", 0.2, 137, true),
                ("shell", "kill -KILL $PPID", 2, -1, false),
                ("shell", "printf recovered", 2, 0, false)]
            var reports: [[String: Any]] = []; var done = false; var ticks = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in ticks += 1 }
            func step(_ index: Int) {
                guard index < cases.count else { done = true; return }
                let (kind, source, timeout, expected, expectedTimeout) = cases[index]
                ScriptRunnerClient.shared.run(kind: kind, source: source, timeout: timeout) { code, output, timedOut in
                    var ok = code == expected && timedOut == expectedTimeout
                    if index == 0 { ok = ok && output == "xpc-ok" }
                    if index == 1 { ok = ok && output.trimmingCharacters(in: .whitespacesAndNewlines) == "xpc-apple-ok" }
                    if index == 3 { ok = ok && output.utf8.count == 65536 }
                    if index == 6 { ok = ok && output == "recovered" }
                    reports.append(["case": index, "success": ok, "exitCode": code, "timedOut": timedOut, "outputBytes": output.utf8.count])
                    step(index + 1)
                }
            }
            step(0)
            let deadline = Date().addingTimeInterval(35)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            timer.invalidate()
            let success = done && ticks >= 10 && reports.allSatisfy { $0["success"] as? Bool == true }
            writeCheck(["success": success, "mainRunLoopTicks": ticks, "cases": reports], path: args[i + 1])
            exit(success ? 0 : 1)
        }
        // A test host is not a second running copy: it must neither take the
        // input-owner lease nor defer to the installed app, or the suite can
        // never start while AOM is running.
        if !PresetManager.isUIPreview && !PresetManager.isRunningTests {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("allofmacos-input-owner.lock").path
            guard let lease = SingleInstanceLease(path: path) else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.kyw.allofmacos")
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate(options: [])
                return
            }
            instanceLease = lease
            // Older builds did not take the lease, so also honor a running older copy.
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kyw.allofmacos")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching }) {
                other.activate(options: []); return
            }
        } else { ActionExecutor.onActionExecuted = { _ in } }
        AllOfMacOSApp.main()
    }

    private static func writeCheck(_ result: [String: Any], path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { fputs("Check report failed: \(error)\n", stderr); exit(2) }
    }
}

struct AllOfMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var history = AOMNavigationHistory.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .accentColor(appState.accentColorChoice.color)
                .tint(appState.accentColorChoice.color)
                .frame(minWidth: AOMSize.windowMinWidth, minHeight: AOMSize.windowMinHeight)
                .task {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        // aom:// links and opened files are handled by AppDelegate; without
        // this every link (Raycast, Shortcuts, Alfred) opened another window.
        .handlesExternalEvents(matching: [])
        .commands {
            SidebarCommands()
            // View: Back, Forward, every page, Search…, Customize Workspace…
            // (System Settings' View menu; HIG The menu bar, design-3.4.0 b.14).
            CommandGroup(before: .sidebar) {
                Button("Back") {
                    appDelegate.showMainWindow()
                    history.goBack(appState)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!history.canGoBack)
                Button("Forward") {
                    appDelegate.showMainWindow()
                    history.goForward(appState)
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!history.canGoForward)
                Divider()
                ForEach(AOMMainTab.allCases) { tab in
                    Button(tab.title) {
                        appState.selectedMainTab = tab
                        appDelegate.showMainWindow()
                    }
                    .keyboardShortcut(tab.shortcutKey.map { SwiftUI.KeyboardShortcut($0, modifiers: .command) })
                }
                Divider()
                let palette = AOMPaletteShortcut.keyEquivalent(AOMPaletteShortcut.current(appState.currentPreset))
                Button("Search…") {
                    appDelegate.showMainWindow()
                    appState.showingCommandPalette = true
                }
                .keyboardShortcut(palette.0, modifiers: palette.1)
                Button("Customize Workspace…") {
                    appDelegate.showMainWindow()
                    appState.selectedMainTab = .home
                    AOMWorkspaceLayout.shared.customizeRequested = true
                }
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Show Welcome Again") {
                    appDelegate.showMainWindow()
                    appState.showTutorialRequested = true
                }
            }
            TriggerEditorCommands()
            WorkflowVariableCommands()
            CommandGroup(after: .newItem) {
                Button("Open Annotation Project…") { AnnotationEditorController.shared.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit All of MacOS") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Window("Workflow Variables", id: "workflow-variables") {
            WorkflowVariablesView()
                .scrollIndicators(.hidden)
        }
        .defaultSize(width: 620, height: 440)
        // aom:// links must not open this window (AppDelegate handles them).
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .scrollIndicators(.hidden)
                .environmentObject(appState)
                .accentColor(appState.accentColorChoice.color)
                .tint(appState.accentColorChoice.color)
        }
        // One toolbar row: the pane title sits at the leading edge as in
        // System Settings, instead of a centred title over an empty bar.
        .windowToolbarStyle(.unified)
    }
}

struct SettingsView: View {
    var body: some View {
        SettingsHubView()
    }
}

struct BackupSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var backupsEnabled = PresetManager.backupsEnabled
    @State private var customPath = UserDefaults.standard.string(forKey: "AOMBackupPath") ?? ""
    @State private var maxBackups = Double(PresetManager.maxBackups)
    @State private var backups: [(date: Date, size: Int64, url: URL)] = []

    /// Built once, not on every render of the sheet.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        // The same sections and rows as the other Settings sheets
        // (Permissions, Shortcuts): monochrome symbols, no coloured squircles.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                AOMSection("Automatic backups") {
                    AOMToggleRow("Enable automatic backups",
                                 detail: "A copy of your automations, profiles and settings each time they change",
                                 symbol: "clock.arrow.circlepath", isOn: $backupsEnabled)
                    AOMSettingRow("Backups to keep", detail: "Older snapshots are removed automatically",
                                  symbol: "archivebox") {
                        // The shared row slider (track and value widths of
                        // every settings slider). Twenty steps would draw a
                        // dotted rule of ticks, so it slides freely and the
                        // binding rounds, as Settings' own sliders do.
                        AOMRowSlider("Backups to keep", value: Binding(
                            get: { maxBackups },
                            set: { maxBackups = $0.rounded() }), in: 1...20, format: { "\(Int($0))" })
                    }
                    AOMSettingRow("Backup folder", detail: customPath.isEmpty ? "Default (~/.allofmacos_backups)" : customPath,
                                  symbol: "folder") {
                        HStack(spacing: AOMSpace.x2) {
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    customPath = url.path
                                    UserDefaults.standard.set(url.path, forKey: "AOMBackupPath")
                                }
                            }
                            if !customPath.isEmpty {
                                Button("Reset") {
                                    customPath = ""
                                    UserDefaults.standard.removeObject(forKey: "AOMBackupPath")
                                }
                            }
                        }
                    }
                }
                .onChange(of: backupsEnabled) { _, newValue in PresetManager.backupsEnabled = newValue }
                .onChange(of: maxBackups) { _, newValue in PresetManager.maxBackups = Int(newValue) }

                // What a backup holds, stated where backups are restored
                // (audit 2026-10-28 F07).
                Text("Each backup holds your automations, app-specific sets, activation groups and snap layouts, plus the settings of the same moment: gestures and their timing, title-bar snap, key remapping, pausing rules, shortcuts, capture, text capture and recording, clipboard preferences, audio and appearance. Restoring them puts back exactly those settings, including the ones that were still at their defaults. Not included: clipboard history, captures and recordings, the backup and capture folders, the backup options, whether automation is paused, and AI tool or screen-reading access.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AOMSpace.x0_5)

                AOMSection("Existing backups", detail: backups.isEmpty ? nil : "\(backups.count)") {
                    Button {
                        NSWorkspace.shared.open(PresetManager.backupDirectory)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Open the backup folder in Finder")
                } content: {
                    if backups.isEmpty {
                        AOMInlineEmpty(symbol: "doc.badge.clock", message: "No backups found yet.")
                    } else {
                        ForEach(Array(backups.enumerated()), id: \.offset) { _, backup in
                            AOMSettingRow(Self.dateFormatter.string(from: backup.date), detail: backupSubtitle(backup),
                                          symbol: "doc.badge.clock") {
                                HStack(spacing: AOMSpace.x2) {
                                    Button("Restore…") { confirmRestore(backup.url, date: backup.date) }
                                        .accessibilityLabel("Restore the backup from \(Self.dateFormatter.string(from: backup.date))")
                                    Button("Reveal") {
                                        NSWorkspace.shared.selectFile(backup.url.path, inFileViewerRootedAtPath: "")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .aomSettingsSheetContent()
        }
        .onAppear { backups = PresetManager.listBackups() }
    }

    private func backupSubtitle(_ backup: (date: Date, size: Int64, url: URL)) -> String {
        let size = ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file)
        let name = backup.url.deletingPathExtension().lastPathComponent
        if name.contains("-before-import") { return "\(size) · kept before an import" }
        if name.contains("-before-restore") { return "\(size) · kept before a restore" }
        return size
    }

    /// One backup restores the automations, and — when it was saved with
    /// them — the settings of the same moment (e.g. on a new Mac).
    private func confirmRestore(_ url: URL, date: Date) {
        // What would change, before anything does.
        guard let preview = PresetManager.restorePreview(of: url, current: appState.currentPreset) else {
            appState.presetOperationReporter("Could Not Read the Backup",
                                             "\(url.lastPathComponent) is not a readable AOM backup. Nothing was changed.", .failure)
            return
        }
        // Offered only when the settings file was actually read.
        let hasSettings = preview.hasSettings
        let alert = NSAlert()
        alert.messageText = "Restore the backup from \(Self.dateFormatter.string(from: date))?"
        alert.informativeText = preview.summary + "\n\n"
            + "It replaces your current automations, app profiles and snap layouts"
            + (hasSettings ? ", and optionally your settings" : "")
            + ". What it replaces is kept as a backup first."
        alert.addButton(withTitle: "Restore Automations")
        if hasSettings { alert.addButton(withTitle: "Restore Automations and Settings") }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: appState.restorePresetBackup(url)
        case .alertSecondButtonReturn where hasSettings: appState.restorePresetBackup(url, includeSettings: true)
        default: return
        }
        backups = PresetManager.listBackups()
    }
}
