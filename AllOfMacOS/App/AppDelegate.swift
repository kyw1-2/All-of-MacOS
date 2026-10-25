import AppKit
import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// AOM's own link namespace; never claims cleanshot:// or executes arbitrary URLs.
/// A URL is a request to show native UI or perform an already user-initiated capture.
/// Unsupported parameters fail closed rather than silently changing capture behavior.
enum AOMCaptureDeepLink: Equatable {
    case allInOne, captureArea, captureFullscreen, captureWindow, previousArea
    case scrollingCapture, selfTimer, recordScreen, pauseRecording, resumeRecording, stopRecording, openProject(URL)
    case captureText(keepsLineBreaks: Bool)
    case openHistory, restoreRecentlyClosed, openSettings
    case pin, openAnnotate, openFromClipboard, addQuickAccessOverlay(URL)
    case openClipboard

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "aom",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let command = parts.host?.lowercased() else { return nil }
        let items = parts.queryItems ?? []
        // Duplicate query keys, unknown flags and unsupported remote files are
        // never interpreted as commands.
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        func exact(_ keys: Set<String> = []) -> Bool { Set(params.keys) == keys }
        switch command {
        case "all-in-one" where exact(): return .allInOne
        case "capture-area" where exact(): return .captureArea
        case "capture-fullscreen" where exact(): return .captureFullscreen
        case "capture-window" where exact(): return .captureWindow
        case "capture-previous-area" where exact(): return .previousArea
        case "scrolling-capture" where exact(): return .scrollingCapture
        case "self-timer" where exact(): return .selfTimer
        case "record-screen" where exact(): return .recordScreen
        case "pause-recording" where exact(): return .pauseRecording
        case "resume-recording" where exact(): return .resumeRecording
        case "stop-recording" where exact(): return .stopRecording
        case "open-project" where exact(["filepath"]):
            guard let path = params["filepath"], path.hasPrefix("/"), !path.contains("\0"),
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "aomannotation" else { return nil }
            return .openProject(URL(fileURLWithPath: path))
        case "capture-text" where exact(): return .captureText(keepsLineBreaks: true)
        case "capture-text" where exact(["linebreaks"]):
            guard let value = params["linebreaks"], ["true", "false"].contains(value) else { return nil }
            return .captureText(keepsLineBreaks: value == "true")
        case "open-history" where exact(): return .openHistory
        case "restore-recently-closed" where exact(): return .restoreRecentlyClosed
        case "open-settings" where exact(): return .openSettings
        case "pin" where exact(): return .pin
        case "open-annotate" where exact(): return .openAnnotate
        case "open-from-clipboard" where exact(): return .openFromClipboard
        case "open-clipboard" where exact(): return .openClipboard
        case "add-quick-access-overlay" where exact(["filepath"]):
            guard let path = params["filepath"], path.hasPrefix("/"), !path.contains("\0"),
                  ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp", "mp4"].contains(
                    URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
            return .addQuickAccessOverlay(URL(fileURLWithPath: path))
        default: return nil
        }
    }
}


class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The running delegate, for AppleScript commands that reuse URL handling.
    @MainActor static weak var current: AppDelegate?
    var statusItem: NSStatusItem?
    var appState: AppState?
    private weak var mainWindow: NSWindow?
    private var menuBarObserver: NSKeyValueObservation?
    private var suppressionObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.current = self
        AOMScrollChromePolicy.shared.start()
        if !PresetManager.isRunningTests && !PresetManager.isUIPreview { startMissionControlOverlay() }
        if !PresetManager.isUIPreview { Task { @MainActor in AOMTouchBar.shared.start() } }
        let showIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if showIcon {
            setupMenuBarIcon()
        }
        observeMenuBarSetting()
        // Reflect Pause AOM in the menu-bar icon whenever the pause state changes.
        suppressionObserver = TriggerSuppression.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatusIcon() }
        if PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-clipboard-preview") {
            Task { @MainActor in
                let store = ClipboardStore.shared
                await store.ready()
                let board = store.createBoard(name: "Important", color: "green")
                for text in ["A calm place for everything you copy.", "https://developer.apple.com/swift/", "#4A90D9", "Meeting notes\nDesign review at 10:30\nRefine the clipboard cards\nKeep existing shortcuts", "Hello, clipboard.\n안녕하세요, 클립보드."] {
                    if let entry = store.createTextItem(text) { store.pin(entryID: entry.id, boardID: board.id) }
                }
                // Keep some items unpinned in the isolated preview so the
                // Important tab is distinguishable from Clipboard History.
                _ = store.createTextItem("Recent clipboard entry — not pinned")
                _ = store.createTextItem("Draft text available only in Clipboard History")
                // Image, file and link samples from real app identities, so
                // header colours, file icons and size pills can be reviewed.
                let samples: [(String, String, (NSPasteboard) -> Void)] = [
                    ("Safari", "com.apple.Safari", { $0.setString("https://www.apple.com/macos/", forType: .string) }),
                    ("Finder", "com.apple.finder", { $0.writeObjects([URL(fileURLWithPath: "/Applications/Safari.app") as NSURL]) }),
                    ("Finder", "com.apple.finder", { $0.writeObjects([URL(fileURLWithPath: "/System/Library/Desktop Pictures") as NSURL,
                                                                      URL(fileURLWithPath: "/etc/hosts") as NSURL]) }),
                    ("Preview", "com.apple.Preview", { board in
                        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
                            NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: rect, angle: 35)
                            return true
                        }
                        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            board.setData(png, forType: .png)
                        }
                    }),
                    ("Terminal", "com.apple.Terminal", { $0.setString("swift build -c release -j 2\ngit status --short", forType: .string) }),
                ]
                for (name, bundleID, write) in samples {
                    store.seedIsolatedPasteboard(sourceName: name, sourceBundleID: bundleID, write)
                    try? await Task.sleep(for: .milliseconds(80))
                }
                await store.finishPendingCaptures()
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--aom-clipboard-preview-select") {
                    let state = ClipboardPanelController.shared.state
                    let ids = state.results(in: store).map(\.id)
                    if ids.count > 2 { state.select(ids[1], in: state.results(in: store)); state.select(ids[2], in: state.results(in: store), toggle: true) }
                    state.commandHeld = true
                    state.status = "Copied to clipboard."
                }
                if args.contains("--aom-mcp-preview") {
                    // Isolated MCP round-trip check: prints a one-off token.
                    let token = (try? ClipboardMCPSettings.shared.connect(name: "Preview", client: "Custom Tool")) ?? ""
                    print("AOM_MCP_PREVIEW_TOKEN=\(token)"); fflush(stdout)
                }
                if args.contains("--aom-clipboard-preview-filters") {
                    let state = ClipboardPanelController.shared.state
                    state.searchExpanded = true
                    state.query = "apple"
                    try? await Task.sleep(for: .milliseconds(600))
                    state.filtersExpanded = true
                }
                // `--aom-clipboard-preview-data` seeds the store without opening the shelf.
                if !args.contains("--aom-clipboard-preview-data") { ClipboardPanelController.shared.show() }
            }
        }

        if !PresetManager.isUIPreview {
            ClipboardMCPServer.shared.refresh()
            requestAccessibilityPermissions()
            Task { @MainActor in WindowPinRestoration.recover() }
            GestureHUD.shared.start()
            NSApp.servicesProvider = self
            NSUpdateDynamicServices()
            Task { @MainActor in ScreenRecordingService.shared.offerInterruptedRecordingRecovery() }
            // A clipboard manager launched later can take the shelf shortcut.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                              object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier?.hasPrefix("com.wiheads.paste") == true else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { ShortcutConflicts.resolveIfNeeded() } }
            }
            // Warm the OCR model and ScreenCaptureKit so the first Capture
            // Text of a session is as instant as later ones.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                TextRecognitionEngine.prewarm()
                ScreenCaptureService.shared.prewarm()
                AOMSystemSound.prewarm()
                ShortcutConflicts.resolveIfNeeded()
                DispatchQueue.global(qos: .utility).async { _ = TextPostProcessor.linkDetector }
                TextCaptureHUDController.shared.prewarm()
            }
        }
        // Monitor start-up is owned by AppState (see AppState.init) — it runs
        // whether or not a window is ever shown, which is what an LSUIElement
        // menu-bar app needs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.minSize = NSSize(width: 1040, height: 650)
                mainWindow = window
                window.delegate = self
            }
            // Isolated previews can be reviewed as the active app, so window
            // chrome, selection and glass render in their key-window state.
            if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-activate") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }

    // Action names follow the public screenshot-workflow terminology; the
    // namespace remains AOM-only to avoid hijacking another app's URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !PresetManager.isUIPreview else { return }
        for link in urls.prefix(8) {
            if let request = AOMSharedImages.parse(link) {
                Task { @MainActor in
                    for file in request.files {
                        if request.mode == .annotate { self.openLocalDocument(file) }
                        else if let entry = AnnotationEditorController.entry(fromImageAt: file) {
                            PinnedScreenshotController.shared.pin(entry: entry, url: file)
                        }
                    }
                }
                continue
            }
            if link.isFileURL {
                Task { @MainActor in self.openLocalDocument(link) }
                continue
            }
            if let command = AOMAutomationLink.parse(link) {
                Task { @MainActor in
                    switch command {
                    case .trigger(let name): ActionExecutor.executeNamedTrigger(name)
                    case .showMenu(let name):
                        if !FloatingMenuController.shared.show(name) {
                            GestureHUD.shared.show(title: "Menu Not Found", detail: name)
                        }
                    case .editMenus: FloatingMenuController.shared.edit()
                    case .hideMenus: FloatingMenuController.shared.hideAll()
                    }
                }
                continue
            }
            guard let command = AOMCaptureDeepLink.parse(link) else { continue }
            Task { @MainActor [weak self] in
                self?.handleCaptureDeepLink(command)
            }
        }
    }

    @MainActor
    private func handleCaptureDeepLink(_ command: AOMCaptureDeepLink) {
        switch command {
        case .allInOne: CaptureCoordinator.shared.captureAllInOne()
        case .captureArea: CaptureCoordinator.shared.captureArea()
        case .captureFullscreen: CaptureCoordinator.shared.captureFullscreen()
        case .captureWindow: CaptureCoordinator.shared.captureWindowFromPicker()
        case .previousArea: CaptureCoordinator.shared.capturePreviousArea()
        case .scrollingCapture: CaptureCoordinator.shared.captureScrolling()
        case .selfTimer: CaptureCoordinator.shared.captureWithSelfTimer()
        case .recordScreen: ScreenRecordingService.shared.promptAndStartRecording()
        case .pauseRecording: ScreenRecordingService.shared.pauseRecording()
        case .resumeRecording: ScreenRecordingService.shared.resumeRecording()
        case .stopRecording:
            Task { @MainActor in
                do { _ = try await ScreenRecordingService.shared.stopRecording() }
                catch { GestureHUD.shared.show(title: "Recording", detail: error.localizedDescription) }
            }
        case .openProject(let url): AnnotationEditorController.shared.openProject(at: url)
        case .captureText(let keepsLineBreaks):
            CaptureCoordinator.shared.captureText(keepsLineBreaks: keepsLineBreaks)
        case .openHistory: CaptureHistoryWindowController.shared.present()
        case .openClipboard: ClipboardPanelController.shared.toggle()
        case .restoreRecentlyClosed: CaptureCoordinator.shared.restoreRecentlyClosedOverlay()
        case .openSettings: openSettings()
        case .pin: CaptureActions.pinLastCapture()
        case .openAnnotate: AnnotationEditorController.shared.openMostRecent()
        case .openFromClipboard:
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                GestureHUD.shared.show(title: "No Image", detail: "Copy an image first.")
                return
            }
            let entry = CaptureHistoryEntry(image: cg, kind: .area, capturedAt: Date(), windowTitle: nil, fileURL: nil)
            AnnotationEditorController.shared.open(capture: entry, url: nil)
        case .addQuickAccessOverlay(let url):
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? Int.max) <= 200_000_000 else {
                GestureHUD.shared.show(title: "Import Rejected", detail: "Select a regular media file up to 200 MB.")
                return
            }
            CaptureCoordinator.shared.importQuickAccessFiles([url])
        }
    }

    @MainActor
    private func openLocalDocument(_ url: URL) {
        if url.pathExtension.lowercased() == "aomannotation" {
            AnnotationEditorController.shared.openProject(at: url)
            return
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 200_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let entry = CaptureHistoryEntry(image: image, kind: .area, capturedAt: Date(),
                                        windowTitle: url.lastPathComponent, fileURL: url)
        AnnotationEditorController.shared.open(capture: entry, url: url)
    }

    @objc func annotateFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        for url in urls.prefix(8) where url.isFileURL {
            Task { @MainActor in self.openLocalDocument(url) }
        }
    }

    @objc private func editFloatingMenus() {
        MainActor.assumeIsolated { FloatingMenuController.shared.edit() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// A software dim lives in the display's gamma table, which outlives the
    /// process. Without this, quitting while dimmed would leave the screen dark
    /// until the user changed the resolution or logged out.
    func applicationWillTerminate(_ notification: Notification) {
        ActionExecutor.cancelAllSequences()
        MainActor.assumeIsolated {
            WindowPinningService.shared.unpinAll()
            ClipboardMCPServer.shared.stopForTermination()
            GestureStatistics.shared.flushPendingWrites()
            appState?.flushPendingWrites()
        }
        DisplayControlService.clearAllSoftwareDims()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc private func toggleSnapping() {
        MainActor.assumeIsolated { if let appState { appState.setSnappingEnabled(!appState.currentPreset.snappingEnabled) } }
    }

    // MARK: - Capture actions
    //
    // Each of these forwards to the coordinator, which owns the capture path
    // itself. They are separate selectors rather than one dispatching method
    // because `NSMenuItem` identifies its action by selector, not by an argument.

    @objc func quickAccessDiagnosticsAction() {
        MainActor.assumeIsolated { QuickAccessDiagnosticsController.shared.present() }
    }

    @objc func importQuickAccessFileAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.chooseQuickAccessFiles() }
    }

    @objc func restoreRecentQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.restoreRecentlyClosedOverlay() }
    }

    @objc func toggleQuickAccessVisibilityAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.toggleQuickAccessVisibility() }
    }

    @objc func saveAllQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.saveAllQuickAccess() }
    }

    @objc func closeAllQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.closeAllQuickAccess() }
    }

    @objc func captureAllInOneAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureAllInOne() } }
    @objc func captureAreaAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureArea() } }
    @objc func captureFullscreenAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureFullscreen() } }
    @objc func captureWindowAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWindowFromPicker() } }
    @objc func captureActiveWindowAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureActiveWindow() } }
    @objc func pauseRecordingAction() { MainActor.assumeIsolated { ScreenRecordingService.shared.togglePause() } }
    @objc func openAnnotationProjectAction() { MainActor.assumeIsolated { AnnotationEditorController.shared.chooseProject() } }
    @objc func recordScreenAction() { MainActor.assumeIsolated { ScreenRecordingService.shared.toggleRecording() } }
    @objc func recordFullscreenAction() { MainActor.assumeIsolated { ScreenRecordingService.shared.recordFullscreenUnderPointer() } }
    @objc func captureWindowUnderCursorAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWindowUnderCursor() } }
    @objc func capturePreviousAreaAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.capturePreviousArea() } }
    @objc func captureScrollingAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureScrolling() } }
    @objc func captureScrollingHorizontalAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureScrollingHorizontal() } }
    @objc func captureAllDisplaysAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureAllDisplays() } }
    @objc func captureTextWithBreaksAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureText(keepsLineBreaks: true) } }
    @objc func captureTextWithoutBreaksAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureText(keepsLineBreaks: false) } }
    @objc func captureSelfTimerAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWithSelfTimer() } }
    @objc func annotateLastAction() { MainActor.assumeIsolated { AnnotationEditorController.shared.openMostRecent() } }
    @objc func pinLastAction() { MainActor.assumeIsolated { CaptureActions.pinLastCapture() } }
    @objc func copyLastAction() { MainActor.assumeIsolated { CaptureActions.copyLastCapture() } }
    @objc func saveLastAction() { MainActor.assumeIsolated { CaptureActions.saveLastCapture() } }
    @objc func ocrLastAction() { MainActor.assumeIsolated { CaptureActions.copyTextFromLastCapture() } }
    @objc func captureHistoryAction() { MainActor.assumeIsolated { CaptureHistoryWindowController.shared.present() } }
    @objc func unpinAllAction() { MainActor.assumeIsolated { PinnedScreenshotController.shared.unpinAll() } }
    @objc func toggleCaptureOverlayAction() {
        MainActor.assumeIsolated {
            CaptureSettings.overlayEnabled.toggle()
            GestureHUD.shared.show(title: "Quick Access Overlay",
                                   detail: CaptureSettings.overlayEnabled ? "On" : "Off")
        }
    }

    @objc private func showCheatSheet() { GestureHUD.shared.toggleCheatSheet() }
    @objc private func toggleHUD() {
        let enabled = UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true
        UserDefaults.standard.set(!enabled, forKey: "AOMHUDEnabled")
    }
    @objc private func testHUD() {
        GestureHUD.shared.show(title: "Three Finger Swipe Up", detail: "Mission Control")
    }
    // MARK: - Menu Bar

    private func setupMenuBarIcon() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "hand.point.up.braille", accessibilityDescription: "All of MacOS")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func removeMenuBarIcon() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func observeMenuBarSetting() {
        menuBarObserver = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                if change.newValue == true {
                    self?.setupMenuBarIcon()
                } else {
                    self?.removeMenuBarIcon()
                }
            }
        }
    }

    /// The status menu, grouped by tool with the most-used block first
    /// (CleanShot leads with its capture modes; HIG: verbs, sections, toggles
    /// that show their state, one level of submenus). The version lives in
    /// Settings › About instead of heading the menu.
    @objc private func statusItemClicked() {
        let menu = makeStatusMenu()
        // Show the menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear the menu after it closes so the next click triggers statusItemClicked again
        DispatchQueue.main.async {
            self.statusItem?.menu = nil
        }
    }

    /// Builds the status menu fresh for each click (state, frontmost app).
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        func entry(_ title: String, _ symbol: String?, _ selector: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return item
        }

        // Capture — the everyday modes, then every tool one level down.
        menu.addItem(.sectionHeader(title: "Capture"))
        for item in MainActor.assumeIsolated({ CaptureMenu.quickItems() }) { menu.addItem(item) }
        if let capture = MainActor.assumeIsolated({ CaptureMenu.build() }) {
            capture.title = "All Capture Tools"
            capture.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            menu.addItem(capture)
        }
        menu.addItem(.separator())

        // Clipboard
        menu.addItem(.sectionHeader(title: "Clipboard"))
        menu.addItem(entry("Clipboard Shelf", "rectangle.bottomthird.inset.filled", #selector(showClipboard)))
        menu.addItem(entry("Paste Stack", "square.stack.3d.down.right", #selector(showClipboardStack)))
        menu.addItem(entry("Paste Next in Stack", "arrow.down.doc", #selector(pasteNextClipboard)))
        let paused = MainActor.assumeIsolated { ClipboardStore.shared.paused }
        menu.addItem(entry(paused ? "Resume Clipboard History" : "Pause Clipboard History",
                           paused ? "play.circle" : "pause.circle", #selector(toggleClipboardPause)))
        menu.addItem(.separator())

        // System — Keep Awake ▸ durations, mirroring the Pause AOM grammar.
        menu.addItem(.sectionHeader(title: "System"))
        let awakeMenuItem = MainActor.assumeIsolated { keepAwakeMenu() }
        menu.addItem(awakeMenuItem)
        menu.addItem(entry("App Audio Mixer", "slider.horizontal.3", #selector(showAudioMixer)))
        menu.addItem(entry("Mute Front App", "speaker.minus", #selector(muteFrontAppAudioAction)))
        menu.addItem(MainActor.assumeIsolated { appAudioMenu() })
        menu.addItem(.separator())

        // Automation — the engine, snapping, pausing and what the app in front
        // of you has bound.
        menu.addItem(.sectionHeader(title: "Automation"))
        let enabled = MainActor.assumeIsolated { appState?.globalEnabled ?? true }
        let engine = entry("Gestures & Shortcuts", "bolt", #selector(toggleEnabled))
        engine.state = enabled ? .on : .off
        menu.addItem(engine)
        let snapping = MainActor.assumeIsolated { appState?.currentPreset.snappingEnabled ?? false }
        let snapItem = entry("Drag to Snap", "rectangle.split.2x2", #selector(toggleSnapping))
        snapItem.state = snapping ? .on : .off
        menu.addItem(snapItem)
        menu.addItem(MainActor.assumeIsolated { WindowPinningService.shared.statusMenuItem() })
        menu.addItem(pauseMenuItem())
        if let appState = MainActor.assumeIsolated({ self.appState }),
           let triggers = MainActor.assumeIsolated({ TriggerMenu.build(from: appState) }) {
            menu.addItem(triggers)
        }
        // Displays are settings you adjust directly rather than gestures you
        // bind, so they live here permanently instead of in the action list.
        if let displays = MainActor.assumeIsolated({ DisplayMenu.build() }) {
            menu.addItem(displays)
        }
        menu.addItem(.separator())

        menu.addItem(entry("Open All of MacOS", "macwindow", #selector(showMainWindow)))
        menu.addItem(entry("Settings…", "gearshape", #selector(openSettings), key: ","))
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        let moreMenu = NSMenu(title: "More")
        moreMenu.addItem(entry("Floating Menus & Widgets…", "square.grid.2x2", #selector(editFloatingMenus)))
        moreMenu.addItem(entry("Show Cheat Sheet", "list.bullet.rectangle", #selector(showCheatSheet)))
        let hudItem = entry("Gesture HUD", "rectangle.on.rectangle", #selector(toggleHUD))
        hudItem.state = (UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true) ? .on : .off
        moreMenu.addItem(hudItem)
        moreMenu.addItem(entry("Test HUD Overlay", "sparkles", #selector(testHUD)))
        moreMenu.addItem(.separator())
        moreMenu.addItem(entry("Restart All of MacOS", "arrow.clockwise", #selector(restartApp)))
        more.submenu = moreMenu
        menu.addItem(more)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit All of MacOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
        return menu
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        MainActor.assumeIsolated {
            appState?.toggleGlobalEnabled()
        }
        updateStatusIcon()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Find and invoke the Settings menu item from the app menu
        if let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu {
            for item in appMenu.items {
                if item.title.contains("Settings") || item.title.contains("Preferences") {
                    _ = item.target?.perform(item.action, with: item)
                    return
                }
            }
        }
        // Fallback: try the known selector directly
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }


    // MARK: - Window management

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Find any suitable window
            for window in NSApp.windows where window.canBecomeMain {
                mainWindow = window
                window.delegate = self
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    // MARK: - Mission Control buttons

    /// The overlay polls the Dock's AX tree only while the setting is on.
    func startMissionControlOverlay() {
        MainActor.assumeIsolated {
            if UserDefaults.standard.object(forKey: "AOMMissionControlButtons") as? Bool ?? true {
                MissionControlOverlayService.shared.start()
            }
        }
    }

    // MARK: - Keep Awake

    /// Keep Awake ▸ Indefinitely / 30 minutes / 1 hour / 2 hours / Turn Off.
    @MainActor private func keepAwakeMenu() -> NSMenuItem {
        let service = KeepAwakeService.shared
        let item = NSMenuItem(title: service.isActive ? "Keep Awake (on)" : "Keep Awake",
                              action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: service.isActive ? "flask.fill" : "flask", accessibilityDescription: nil)
        let submenu = NSMenu()
        func duration(_ title: String, _ minutes: Int?) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = service.isActive && service.currentMinutes == minutes ? .on : .off
            entry.tag = minutes ?? -1
            return entry
        }
        submenu.addItem(duration("Indefinitely", nil))
        submenu.addItem(duration("30 Minutes", 30))
        submenu.addItem(duration("1 Hour", 60))
        submenu.addItem(duration("2 Hours", 120))
        // Offer Turn Off while any assertion exists — even one whose deadline
        // already passed — so the state can always be cleared from the menu.
        if service.hasAssertion {
            submenu.addItem(.separator())
            let off = NSMenuItem(title: "Turn Off", action: #selector(keepAwakeOff), keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
        }
        item.submenu = submenu
        return item
    }

    @objc func keepAwakeFor(_ sender: NSMenuItem) {
        let minutes = sender.tag >= 0 ? sender.tag : nil
        MainActor.assumeIsolated { KeepAwakeService.shared.start(minutes: minutes, keepDisplay: false) }
    }

    @objc func keepAwakeOff() { MainActor.assumeIsolated { KeepAwakeService.shared.stop() } }
    @objc func showAudioMixer() { MainActor.assumeIsolated { AppAudioMixerService.shared.showPanel() } }

    /// App Audio ▸ EQ on/off, presets and the output devices — the menu-bar
    /// control surface SoundSource users expect.
    @MainActor private func appAudioMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "App Audio", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        let submenu = NSMenu()
        let mixer = AppAudioMixerService.shared
        let eq = NSMenuItem(title: "Equalizer", action: #selector(toggleAudioEQ), keyEquivalent: "")
        eq.target = self
        eq.state = mixer.eqEnabled ? .on : .off
        submenu.addItem(eq)
        let presets = NSMenuItem(title: "EQ Preset", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu()
        for name in AudioEQ.presets.keys.sorted() {
            let entry = NSMenuItem(title: name, action: #selector(chooseAudioEQPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = mixer.eqPreset == name ? .on : .off
            entry.representedObject = name
            presetMenu.addItem(entry)
        }
        presets.submenu = presetMenu
        submenu.addItem(presets)
        submenu.addItem(.separator())
        let outputs = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        let outputMenu = NSMenu()
        let devices = AudioOutputService.devices()
        let currentUID = AudioOutputService.currentDeviceID().map { String($0) }
        for device in devices {
            let entry = NSMenuItem(title: device.name, action: #selector(chooseAudioOutput(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = device.uid == currentUID ? .on : .off
            entry.representedObject = device.uid
            outputMenu.addItem(entry)
        }
        outputs.submenu = outputMenu
        submenu.addItem(outputs)
        item.submenu = submenu
        return item
    }

    @objc func toggleAudioEQ() {
        MainActor.assumeIsolated { AppAudioMixerService.shared.eqEnabled.toggle() }
    }

    @objc func chooseAudioEQPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { AppAudioMixerService.shared.eqPreset = name }
    }

    @objc func chooseAudioOutput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let device = AudioOutputService.devices().first(where: { $0.uid == uid }) else { return }
        AudioOutputService.shared.select(name: device.name, uid: device.uid, completion: { _ in })
    }
    @objc func muteFrontAppAudioAction() { MainActor.assumeIsolated { AppAudioMixerService.shared.toggleMuteFront() } }

    // MARK: - Pause AOM (TriggerSuppression)

    /// "Pause AOM ▸ for 5 min / 1 h / until resumed · Pause for <App> · Resume".
    private func pauseMenuItem() -> NSMenuItem {
        let suppression = TriggerSuppression.shared
        let item = NSMenuItem(title: suppression.isPaused ? "Pause AOM (active)" : "Pause AOM", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: suppression.isPaused ? "pause.circle.fill" : "pause.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        if let status = suppression.statusDescription {
            let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            submenu.addItem(.separator())
        }
        for (title, seconds) in AppDelegate.pauseDurations {
            let entry = NSMenuItem(title: title, action: #selector(pauseForDuration(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = NSNumber(value: seconds)
            submenu.addItem(entry)
        }
        let untilResumed = NSMenuItem(title: "Until Resumed", action: #selector(pauseUntilResumed), keyEquivalent: "")
        untilResumed.target = self
        submenu.addItem(untilResumed)
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            submenu.addItem(.separator())
            let paused = suppression.pause.appBundleIDs.contains(id)
            let name = front.localizedName ?? id
            let appItem = NSMenuItem(title: paused ? "Resume for \(name)" : "Pause for \(name)",
                                     action: #selector(togglePauseForApp(_:)), keyEquivalent: "")
            appItem.target = self; appItem.representedObject = id
            appItem.state = paused ? .on : .off
            submenu.addItem(appItem)
        }
        // Apps paused earlier but no longer frontmost stay reachable.
        for id in suppression.pause.appBundleIDs.sorted() where id != NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            let entry = NSMenuItem(title: "Resume for \(name)", action: #selector(togglePauseForApp(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = id; entry.state = .on
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let resume = NSMenuItem(title: "Resume", action: #selector(resumeTriggers), keyEquivalent: "")
        resume.target = self
        resume.isEnabled = suppression.isPaused || !suppression.pause.appBundleIDs.isEmpty
        submenu.addItem(resume)
        item.submenu = submenu
        return item
    }

    static let pauseDurations: [(String, TimeInterval)] = [("for 5 Minutes", 300), ("for 1 Hour", 3600)]

    @objc private func pauseForDuration(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        TriggerSuppression.shared.pause(for: seconds)
        ActionExecutor.cancelAllSequences()
    }
    @objc private func pauseUntilResumed() {
        TriggerSuppression.shared.pauseUntilResumed()
        ActionExecutor.cancelAllSequences()
    }
    @objc private func togglePauseForApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        TriggerSuppression.shared.toggleApp(id)
    }
    @objc private func resumeTriggers() { TriggerSuppression.shared.resume() }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let enabled = MainActor.assumeIsolated { appState?.globalEnabled ?? true }
        let paused = TriggerSuppression.shared.isPaused
        let symbolName = !enabled ? "hand.raised.slash" : (paused ? "pause.circle" : "hand.point.up.braille")
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "All of MacOS")
    }

    @objc private func showClipboard() { MainActor.assumeIsolated { ClipboardPanelController.shared.show() } }
    @objc private func showClipboardStack() { MainActor.assumeIsolated { ClipboardPanelController.shared.showStack() } }
    @objc private func pasteNextClipboard() { MainActor.assumeIsolated { ClipboardPanelController.shared.pasteNext() } }
    @objc private func toggleClipboardPause() { MainActor.assumeIsolated { ClipboardStore.shared.paused.toggle() } }

    // MARK: - Permissions

    // There is deliberately no automation (Apple Events) request here. Nothing
    // the app does needs it: keystrokes go out as CGEvents and the one action
    // that used to drive System Events now toggles Appearance in-process. The
    // old check sent an Apple Event on every launch just to probe the grant,
    // which made macOS raise the Automation consent prompt each time — and
    // because an ad-hoc signature gives the app a new identity on every build,
    // re-granting never stuck.

    private func requestAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSLog("[AOM] Accessibility NOT granted — prompt requested")
        } else {
            NSLog("[AOM] Accessibility already granted")
        }
    }
}

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        return object(forKey: "showMenuBarIcon") as? Bool ?? true
    }
}
