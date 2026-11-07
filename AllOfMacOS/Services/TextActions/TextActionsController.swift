import AppKit
import Carbon
import Combine

/// The saved Text Actions settings, published for the page and the engine.
/// Tests and isolated UI previews get a store that never touches a defaults
/// domain, so a preview flag never leaks into the next preview run.
@MainActor
final class TextActionsPreferences: ObservableObject {
    static let shared = TextActionsPreferences()

    @Published var settings: TextActionsSettings {
        didSet {
            guard settings != oldValue, !reloading, let defaults else { return }
            settings.save(to: defaults)
        }
    }

    private let defaults: UserDefaults?
    private var reloading = false
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults? = (PresetManager.isRunningTests || PresetManager.isUIPreview) ? nil : .standard) {
        self.defaults = defaults
        settings = defaults.map(TextActionsSettings.load(from:)) ?? TextActionsSettings()
        // Reset Preferences and a restored backup rewrite the stored value.
        observer = NotificationCenter.default.addObserver(forName: .aomSettingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard let defaults else { return }
        let stored = TextActionsSettings.load(from: defaults)
        guard stored != settings else { return }
        reloading = true
        settings = stored
        reloading = false
    }
}

/// Runs Text Actions: watches for the end of a selection while the master
/// switch is on, reads it off the main thread, shows the bar, runs the
/// clicked action, and keeps the Workspace tile and the status menu current.
/// Nothing is installed while it is off, and nothing runs in previews or tests.
@MainActor
final class TextActionsController {
    static let shared = TextActionsController()

    let preferences: TextActionsPreferences
    let bar = TextActionBarController()
    private let monitor = TextSelectionMonitor()
    private(set) var isRunning = false
    /// Bumped by every mouse down and every new read, so a late answer for an
    /// older selection is dropped.
    private var generation = 0
    private var anchorBox: TextSelectionAnchorBox?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var automationOn = AutomationGate.isOn

    init(preferences: TextActionsPreferences? = nil) {
        self.preferences = preferences ?? .shared
        bar.onPerform = { [weak self] item, variant, alternate in
            self?.perform(item, variant: variant, alternate: alternate)
        }
        self.preferences.$settings
            .removeDuplicates()
            .sink { [weak self] _ in
                // `$settings` fires before the value is stored: act on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged() } }
            }
            .store(in: &cancellables)
        AOMModuleStatusBoard.textActions.setOn = { [weak self] on in self?.setOn(on) }
        updateStatus()
    }

    // MARK: Entry points

    func start() {
        guard !isRunning, !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        isRunning = true
        monitor.onMouseDown = { [weak self] point, clickCount in self?.mouseDown(at: point, clickCount: clickCount) }
        monitor.onGesture = { [weak self] gesture in self?.selectionEnded(gesture) }
        // Pause AOM, the master switch and Accessibility can change at any time.
        TriggerSuppression.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.environmentChanged() } }
            }
            .store(in: &cancellables)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AutomationGate.isOn != self.automationOn else { return }
                self.automationOn = AutomationGate.isOn
                self.environmentChanged()
            }
        })
        for name in [PermissionWatchdog.accessibilityLost, PermissionWatchdog.accessibilityRecovered] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            })
        }
        applyMonitors()
        updateStatus()
    }

    func setOn(_ on: Bool) {
        preferences.settings.isOn = on
    }

    /// The shortcut: the bar for whatever is selected in the front app, with
    /// or without the master switch, by Accessibility or (when the app shares
    /// nothing) by ⌘C with the clipboard put back.
    func showForCurrentSelection() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if let block = TextActionsGate.check(environment(for: app), settings: preferences.settings, automatic: false) {
            notify(block)
            return
        }
        generation &+= 1
        read(app: app, pointer: nil, automatic: false, anchor: nil, token: generation)
    }

    func statusMenuItems() -> [NSMenuItem] {
        let on = preferences.settings.isOn
        let item = TextActionsMenuAction.item("Text Actions", symbol: "character.cursor.ibeam") { [weak self] in
            self?.setOn(!on)
        }
        item.state = on ? .on : .off
        item.toolTip = on ? "Stop showing actions over selected text" : "Show actions over selected text"
        return [item]
    }

    // MARK: Status

    func updateStatus() {
        let settings = preferences.settings
        let status = AOMModuleStatusBoard.textActions
        let paused = !AutomationGate.isOn || TriggerSuppression.shared.isPaused
        status.isOn = settings.isOn
        status.count = nil
        status.detail = Self.statusDetail(settings, paused: paused)
        status.attention = settings.isOn && !AXIsProcessTrusted() ? "Needs Accessibility to read the selection" : nil
    }

    /// "10 actions · not in 5 apps", "Paused with AOM" or "Off".
    nonisolated static func statusDetail(_ settings: TextActionsSettings, paused: Bool) -> String {
        guard settings.isOn else { return "Off" }
        if paused { return "Paused with AOM" }
        let actions = settings.enabledActions.count
        let apps = settings.excludedBundleIDs.count
        var parts = ["\(actions) \(actions == 1 ? "action" : "actions")"]
        if apps > 0 { parts.append("not in \(apps) \(apps == 1 ? "app" : "apps")") }
        return parts.joined(separator: " · ")
    }

    private func settingsChanged() {
        if isRunning { applyMonitors() }
        if !preferences.settings.isOn, bar.isVisible { bar.dismiss(.action) }
        updateStatus()
    }

    private func environmentChanged() {
        if isRunning { applyMonitors() }
        if bar.isVisible, !AutomationGate.isOn || TriggerSuppression.shared.isPaused { bar.dismiss(.paused) }
        updateStatus()
    }

    /// Monitors only while the master switch and AOM are on.
    private func applyMonitors() {
        let settings = preferences.settings
        let active = settings.isOn && AutomationGate.isOn
        monitor.update(.init(drag: active && settings.showsOnDrag,
                             clicks: active && settings.showsOnDoubleClick,
                             keyboard: active && settings.showsOnKeyboardSelection,
                             keyboardDelay: max(0.35, settings.showDelay + 0.3)))
    }

    private func environment(for app: NSRunningApplication) -> TextActionsEnvironment {
        let suppression = TriggerSuppression.shared
        return TextActionsEnvironment(isTrusted: AXIsProcessTrusted(), automationOn: AutomationGate.isOn,
                                      paused: suppression.isPaused || suppression.isPaused(forApp: app.bundleIdentifier),
                                      secureInput: IsSecureEventInputEnabled(), screenLocked: ScreenLock.isLocked,
                                      bundleID: app.bundleIdentifier)
    }

    // MARK: Reading the selection

    private func mouseDown(at point: CGPoint, clickCount: Int) {
        generation &+= 1
        // A double or triple click is compared with the selection before its first click.
        guard TextSelectionMonitor.startsNewAnchor(clickCount: clickCount) || anchorBox == nil else { return }
        anchorBox = nil
        let settings = preferences.settings
        guard settings.showsOnDrag || settings.showsOnDoubleClick, let app = NSWorkspace.shared.frontmostApplication,
              TextActionsGate.check(environment(for: app), settings: settings, automatic: true) == nil else { return }
        let box = TextSelectionAnchorBox()
        anchorBox = box
        let pid = app.processIdentifier
        TextSelectionReader.queue.async {
            box.pid = pid
            box.anchor = TextSelectionReader.readAnchor(pid: pid)
        }
    }

    private func selectionEnded(_ gesture: TextSelectionMonitor.Gesture) {
        if gesture.kind == .keyboard { generation &+= 1 }
        let token = generation
        let settings = preferences.settings
        guard let app = NSWorkspace.shared.frontmostApplication,
              TextActionsGate.check(environment(for: app), settings: settings, automatic: true) == nil else { return }
        let anchor = TextSelectionMonitor.comparesWithMouseDown(gesture.kind) ? anchorBox : nil
        let delay = TextSelectionMonitor.settledDelay(kind: gesture.kind, userDelay: settings.showDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.read(app: app, pointer: gesture.pointer, automatic: true, anchor: anchor,
                          token: token, gesture: gesture.kind)
            }
        }
    }

    private func read(app: NSRunningApplication, pointer: CGPoint?, automatic: Bool,
                      anchor: TextSelectionAnchorBox?, token: Int, attempt: Int = 0,
                      gesture: TextSelectionMonitor.Gesture.Kind? = nil) {
        let pid = app.processIdentifier
        // NSScreen is main-actor state; capture the coordinate transform here.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        TextSelectionReader.queue.async { [weak self] in
            let read = TextSelectionReader.readAttributes(pid: pid, pointer: pointer, primaryHeight: primaryHeight)
            var unchanged = false
            if let anchor, anchor.pid == pid, let read {
                unchanged = TextActionsGate.isUnchangedSelection(anchor: anchor.anchor?.range, final: read.attributes.range,
                                                                 sameElement: anchor.anchor?.element.isSame(as: read.element) ?? false,
                                                                 initialText: anchor.anchor?.selectedText,
                                                                 finalText: read.attributes.selectedText)
            }
            var traits: TextSelectionTraits?
            if let read, TextActionsGate.check(read.attributes) == nil, let text = read.attributes.selectedText {
                traits = TextSelectionClassifier.classify(text)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishRead(app: app, read: read, traits: traits, unchanged: unchanged, pointer: pointer,
                                     automatic: automatic, token: token, attempt: attempt,
                                     anchor: anchor, gesture: gesture)
                }
            }
        }
    }

    private func finishRead(app: NSRunningApplication, read: (attributes: TextSelectionAttributes, element: TextSelectionElement)?,
                            traits: TextSelectionTraits?, unchanged: Bool, pointer: CGPoint?, automatic: Bool,
                            token: Int, attempt: Int, anchor: TextSelectionAnchorBox?,
                            gesture: TextSelectionMonitor.Gesture.Kind?) {
        guard generation == token else { return }
        let settings = preferences.settings
        let environment = environment(for: app)
        // The rules again on the main thread: the app, the pause or secure input may have changed.
        guard TextActionsGate.check(environment, settings: settings, automatic: automatic) == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        if let attributes = read?.attributes,
           TextActionsGate.isForbiddenSelectionTarget(role: attributes.role, subrole: attributes.subrole) {
            if !automatic { notify(TextActionsGate.isPasswordField(role: attributes.role, subrole: attributes.subrole) ? .passwordField : .notText) }
            return
        }
        if unchanged { return }
        // A plain double-click never proves a selection: media fullscreen,
        // window zoom and empty-space clicks would otherwise resurrect stale
        // AXWebArea text. Keep this proof check before presenting the panel.
        if automatic && (gesture == .doubleClick || gesture == .tripleClick) {
            let before = anchor?.pid == app.processIdentifier ? anchor?.anchor : nil
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let bounds = read?.attributes.bounds.map {
                TextActionBarPlacement.appKitRect($0, primaryHeight: primaryHeight)
            }
            guard TextActionsGate.confirmedClickSelection(
                gesture: gesture, anchorAvailable: before != nil,
                sameElement: before?.element.isSame(as: read?.element) ?? false,
                initialRange: before?.range, finalRange: read?.attributes.range,
                initialText: before?.selectedText,
                finalText: read?.attributes.selectedText,
                finalBounds: bounds, pointer: pointer) else { return }
        }
        if let read, let traits, let text = read.attributes.selectedText {
            present(TextSelection(text: text, traits: traits, attributes: read.attributes, element: read.element,
                                  pid: app.processIdentifier, bundleID: app.bundleIdentifier, appName: app.localizedName,
                                  source: .accessibility),
                    pointer: pointer, automatic: automatic)
            return
        }
        // Chromium can publish its selection after the mouse-up callback.
        // Retry AX exactly once before synthesizing a copy. A new selection or
        // app switch invalidates the token; no continuous polling is used.
        if automatic && attempt == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, self.generation == token,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self.read(app: app, pointer: pointer, automatic: true, anchor: anchor,
                          token: token, attempt: 1, gesture: gesture)
            }
            return
        }
        guard TextActionsGate.mayUseCopyFallback(automatic: automatic, gesture: gesture),
              TextActionsGate.mayReadWithCopy(read?.attributes, settings: settings, automatic: automatic,
                                              environment: environment) else {
            if !automatic { notify(.noSelection) }
            return
        }
        TextActionPasteboard.readSelectionWithCopy(in: app) { [weak self] text in
            guard let self, self.generation == token else { return }
            guard let text else {
                if !automatic { self.notify(.noSelection) }
                return
            }
            TextSelectionReader.queue.async { [weak self] in
                let traits = TextSelectionClassifier.classify(text)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == token else { return }
                        let selection = TextSelection(text: text, traits: traits, attributes: read?.attributes ?? TextSelectionAttributes(),
                                                      element: read?.element, pid: app.processIdentifier,
                                                      bundleID: app.bundleIdentifier, appName: app.localizedName, source: .copy)
                        self.present(selection, pointer: pointer ?? NSEvent.mouseLocation, automatic: automatic)
                    }
                }
            }
        }
    }

    /// Builds the bar for a selection and shows it next to the text.
    private func present(_ selection: TextSelection, pointer: CGPoint?, automatic: Bool) {
        let settings = preferences.settings
        let traits = selection.traits
        let context = TextActionContext(
            editability: selection.editability,
            calculation: settings.isOn(.calculate) && traits.isCalculatorCandidate ? AOMCalculator.evaluate(traits.text) : nil,
            chatGPTInstalled: settings.isOn(.askChatGPT) && TextActionPerformer.chatGPTApplicationURL() != nil,
            clipboardHasContent: !settings.isOn(.paste) || NSPasteboard.general.types?.isEmpty == false)
        let actions = TextActionApplicability.actions(settings: settings, traits: traits, context: context)
        let items = TextActionBarItems.make(actions, traits: traits, context: context, speaking: TextCaptureSpeech.shared.isSpeaking)
        guard !items.isEmpty else {
            if !automatic { GestureHUD.shared.show(title: "No Actions", detail: "None of the switched-on actions apply to this text.") }
            return
        }
        let screens = NSScreen.screens.map { TextActionScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let bounds = selection.attributes.bounds.map { TextActionBarPlacement.appKitRect($0, primaryHeight: primaryHeight) }
        // The shortcut places the bar at the selection wherever the pointer is;
        // without bounds every trigger falls back to the pointer.
        let place: CGPoint? = bounds == nil ? (pointer ?? NSEvent.mouseLocation) : (automatic ? pointer : nil)
        guard let anchor = TextActionBarPlacement.anchor(selection: bounds, pointer: place, screens: screens) else { return }
        bar.show(items, for: selection, context: context, anchor: anchor, pointer: place, settings: settings)
    }

    // MARK: Running actions

    private func perform(_ item: TextActionBarItem, variant: TextTransformVariant?, alternate: Bool) {
        // The preview bar acts on nothing: no clipboard, no keys, no links.
        guard !PresetManager.isUIPreview else { bar.dismiss(.action); return }
        guard let selection = bar.selection else { return }
        let settings = preferences.settings
        let context = bar.context
        guard let app = NSRunningApplication(processIdentifier: selection.pid), !app.isTerminated else {
            bar.dismiss(.action)
            return
        }
        // The privacy rules once more, at the moment of the click.
        if let block = TextActionsGate.check(environment(for: app), settings: settings, automatic: false) {
            bar.dismiss(.paused)
            notify(block)
            return
        }
        if TextActionPerformer.hidesBarFirst(item, variant: variant, alternate: alternate, editability: selection.editability) {
            bar.dismiss(.action)
        }
        TextActionPerformer.perform(item, variant: variant, alternate: alternate, selection: selection, context: context,
                                    settings: settings) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .done:
                self.bar.dismiss(.action)
            case .confirmed(let word):
                if self.bar.isVisible { self.bar.confirm(word) }
            case .failed(let title, let detail):
                self.bar.dismiss(.action)
                GestureHUD.shared.show(title: title, detail: detail)
            }
        }
    }

    /// Why the shortcut showed nothing, in a HUD (it never takes focus).
    private func notify(_ block: TextActionsBlock) {
        let detail: String
        switch block {
        case .noSelection:
            detail = preferences.settings.readsWithCopy
                ? "Select some text first."
                : "Select some text first. If the app hides its selection, turn on Use Copy to Read the Selection."
        case .noAccessibility:
            detail = "Allow All of MacOS in System Settings › Privacy & Security › Accessibility."
        default:
            detail = block.description + "."
        }
        GestureHUD.shared.show(title: "Text Actions", detail: detail)
    }

    /// Isolated UI previews only: the real floating bar over a sample
    /// selection near the bottom of the main screen, so the panel itself can
    /// be checked in a screenshot. Its items run nothing (`perform`).
    func showPreviewBar(sample: String) {
        guard PresetManager.isUIPreview, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        var settings = preferences.settings
        settings.hideDelay = TextActionsSettings.hideDelayRange.upperBound
        let traits = TextSelectionClassifier.classify(sample)
        var attributes = TextSelectionAttributes()
        attributes.selectedText = sample
        attributes.isSettable = true
        let selection = TextSelection(text: sample, traits: traits, attributes: attributes, element: nil,
                                      pid: ProcessInfo.processInfo.processIdentifier, bundleID: nil, appName: "Preview",
                                      source: .accessibility)
        let context = TextActionContext(editability: .editable, calculation: nil,
                                        chatGPTInstalled: TextActionPerformer.chatGPTApplicationURL() != nil,
                                        clipboardHasContent: true)
        let items = TextActionBarItems.make(TextActionApplicability.actions(settings: settings, traits: traits, context: context),
                                            traits: traits, context: context, speaking: false)
        let visible = screen.visibleFrame
        let anchor = CGRect(x: visible.midX - 140, y: visible.minY + visible.height * 0.22, width: 280, height: 18)
        bar.show(items, for: selection, context: context, anchor: anchor, pointer: CGPoint(x: anchor.midX, y: anchor.midY),
                 settings: settings)
    }
}

/// A menu item that keeps its closure (NSMenuItem holds its target weakly).
final class TextActionsMenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: Any?) { handler() }

    static func item(_ title: String, symbol: String?, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = TextActionsMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}
