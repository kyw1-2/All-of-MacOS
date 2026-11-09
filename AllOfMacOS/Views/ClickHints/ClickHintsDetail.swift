import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Text Actions › Click Hints: what it does and its shortcut, the keys, the
/// options, enhanced accessibility per app and the excluded apps, with a
/// Try It button. Self-contained: no environment objects, so it works as the
/// detail of any list + detail page.
struct ClickHintsDetail: View {
    @AppStorage(ClickHintsSettings.alphabetKey) private var alphabetRaw = ClickHintsAlphabet.homeRow.rawValue
    @AppStorage(ClickHintsSettings.sizeKey) private var sizeRaw = ClickHintsSize.regular.rawValue
    @AppStorage(ClickHintsSettings.menuBarKey) private var includesMenuBar = false
    @AppStorage(ClickHintsSettings.dockKey) private var includesDock = false
    @AppStorage(ClickHintsSettings.startInSearchKey) private var startsInSearch = false
    @AppStorage(AutomationGate.masterSwitchKey) private var masterSwitchOn = true
    @StateObject private var apps = ClickHintsAppLists()
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    @ObservedObject private var suppression = TriggerSuppression.shared
    @State private var trusted = AXIsProcessTrusted()
    @State private var tryPending = false
    @Environment(\.openSettings) private var openSettings

    /// For renders: forces the Accessibility state shown by the notice.
    var accessibilityOverride: Bool?

    init(accessibilityOverride: Bool? = nil) {
        self.accessibilityOverride = accessibilityOverride
    }

    private var alphabet: Binding<ClickHintsAlphabet> {
        Binding(get: { ClickHintsAlphabet(rawValue: alphabetRaw) ?? .homeRow }, set: { alphabetRaw = $0.rawValue })
    }

    private var size: Binding<ClickHintsSize> {
        Binding(get: { ClickHintsSize(rawValue: sizeRaw) ?? .regular }, set: { sizeRaw = $0.rawValue })
    }

    private var isTrusted: Bool { accessibilityOverride ?? trusted }

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader("Click Hints", symbol: ClickHintsModule.symbol,
                          subtitle: "Click buttons and links by typing the letters on them",
                          help: "Press the shortcut and every button, link, field, tab and row in the front window gets a one- or two-letter label. Type a label to click it. Hints read the window through Accessibility, stay out of password fields and excluded apps, and cost nothing while they are off.") {
                Button(tryPending ? "Starting…" : "Try It") { tryIt() }
                    .disabled(tryPending)
                    .help("Shows hints over this window in a moment; Esc hides them")
            }
            notices

            AOMSection("Preview", footer: "Typing \(previewPrefix) leaves the hints that start with it; the next letter clicks.",
                       padding: AOMSpace.cardPadding) {
                ClickHintsPreviewStrip(alphabet: alphabet.wrappedValue, size: size.wrappedValue)
            }

            AOMSection("Shortcut") {
                AOMSettingRow(ClickHintsModule.title, detail: shortcutDetail) {
                    HStack(spacing: AOMSpace.x2) {
                        if let shortcut = currentShortcut { AOMShortcutKeys(shortcut: shortcut) }
                        Button("Change…") { showShortcutSettings() }
                            .help("Set the shortcut in Settings › Shortcuts")
                    }
                }
            }

            AOMSection("Keys", footer: "Labels never start one another, so a whole label clicks at once.") {
                keyRow("Click", detail: "Type the letters on a hint", keys: ["F", "J"])
                keyRow("Right-click", detail: "Opens the item's menu", keys: ["⇧", "+", "letters"])
                keyRow("⌘-click", detail: "Opens a link in a new tab", keys: ["⌘", "+", "letters"])
                keyRow("Move the pointer there", detail: "Without clicking", keys: ["⌥", "+", "letters"])
                keyRow("Search by name", detail: "Type part of a name, ↩ clicks the highlighted one", keys: ["/"])
                keyRow("Click the only hint left", keys: ["Space", "↩"])
                keyRow("Remove a letter", keys: ["⌫"])
                keyRow("Cancel", detail: "Clicking anywhere or switching apps also cancels", keys: ["esc"])
            }

            AOMSection("Hints") {
                AOMSettingRow("Label letters", detail: alphabet.wrappedValue.sample) {
                    Picker("Label letters", selection: alphabet) {
                        ForEach(ClickHintsAlphabet.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Home Row keeps labels on the keys under your fingers")
                }
                AOMSettingRow("Hint size") {
                    Picker("Hint size", selection: size) {
                        ForEach(ClickHintsSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMToggleRow("Include the menu bar", detail: "The front app's menus get hints too", isOn: $includesMenuBar)
                AOMToggleRow("Include the Dock", detail: "Dock items get hints too", isOn: $includesDock)
                AOMToggleRow("Start in search", detail: "Type part of a name first; / switches to labels", isOn: $startsInSearch)
            }

            AOMSection("Enhanced accessibility",
                       help: "Chrome, Edge, Brave, Arc and Electron apps such as VS Code, Slack, Discord and Notion build their accessibility tree only when an assistive app asks. For the apps listed here, AOM asks before reading: Electron apps through AXManualAccessibility, which has no side effects; other Chromium apps through AXEnhancedUserInterface, the flag VoiceOver uses, which can slow their window moves, so AOM sets it only while hints are shown and puts it back.",
                       footer: "Add an app only when its buttons get no hints. The first hints in it can take a moment longer.") {
                ClickHintsAppList(bundleIDs: $apps.enhanced, noun: "Enhanced", emptySymbol: "sparkles",
                                  emptyMessage: "No apps yet. Add one whose buttons get no hints.", prefersWebApps: true)
            }

            AOMSection("Excluded apps",
                       footer: "Password managers start here. Hints never cover password fields and stay off under secure input, on the lock screen and while AOM is paused.") {
                ClickHintsAppList(bundleIDs: $apps.excluded, noun: "Excluded", emptySymbol: "hand.raised",
                                  emptyMessage: "No excluded apps. Hints can appear in every app.", prefersWebApps: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityLost)) { _ in trusted = false }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityRecovered)) { _ in trusted = true }
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    // MARK: Parts

    @ViewBuilder
    private var notices: some View {
        if !isTrusted {
            AOMNotice(.warning, "Accessibility is off, so Click Hints can't see buttons and links.",
                      detail: "Allow All of MacOS in Privacy & Security › Accessibility.") {
                Button("Allow…") { _ = AOMPermission.accessibility.openSettings() }
            }
        } else if !masterSwitchOn {
            AOMNotice(.info, "AOM is paused, so hints don't appear.", detail: "Resume AOM from the menu bar.")
        } else if suppression.pause.isGloballyPaused {
            AOMNotice(.info, "AOM is paused, so hints don't appear.",
                      detail: suppression.pause.indefinite ? "Paused until resumed"
                          : suppression.pause.until.map { TriggerSuppressionReason.paused(until: $0).description }) {
                Button("Resume") { TriggerSuppression.shared.resume() }
            }
        }
    }

    private func keyRow(_ title: String, detail: String? = nil, keys: [String]) -> some View {
        AOMSettingRow(title, detail: detail) {
            HStack(spacing: AOMSpace.x1) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if key == "+" {
                        Text("+").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    } else {
                        AOMKeycap(text: key)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.filter { $0 != "+" }.joined(separator: " plus "))
        }
    }

    private var previewPrefix: String {
        let labels = ClickHintsPreviewStrip.labels(for: alphabet.wrappedValue)
        return labels.last.map { String($0.prefix(1)).uppercased() } ?? ""
    }

    private var currentShortcut: KeyboardShortcut? {
        ClickHintsModule.shortcutAction.flatMap { shortcuts.shortcut(for: $0) }
    }

    private var shortcutDetail: String {
        if let shortcut = currentShortcut {
            return "\(shortcut.displayString) shows hints over the front window; press it again to hide them"
        }
        return "No shortcut yet; set one in Settings › Shortcuts"
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

    /// Runs hint mode on this window after a short pause, so the click on
    /// the button has ended and the window is settled.
    private func tryIt() {
        tryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            tryPending = false
            ClickHintsModule.showHints()
        }
    }
}

// MARK: - Preview strip

/// A small sample drawn with the real pill images at the chosen size and
/// letters: every hint, then what is left after typing the first letter of
/// the two-letter ones.
struct ClickHintsPreviewStrip: View {
    let alphabet: ClickHintsAlphabet
    let size: ClickHintsSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    /// Six of the labels for one more target than the alphabet has letters:
    /// four single letters and the two that share a prefix (with Home Row:
    /// F J D K, then HF and HJ).
    static func labels(for alphabet: ClickHintsAlphabet) -> [String] {
        let count = alphabet.baseCharacters.count + 1
        let all = ClickHintsLabels.make(count: count, alphabet: alphabet)
        return Array(all.prefix(4)) + Array(all.suffix(2))
    }

    private static let samples: [(title: String, symbol: String)] = [
        ("Back", "chevron.left"), ("Forward", "chevron.right"), ("Share", "square.and.arrow.up"),
        ("Search", "magnifyingglass"), ("Bookmarks", "bookmark"), ("Downloads", "arrow.down.circle")
    ]

    var body: some View {
        let style = ClickHintsPillStyle.resolve(dark: colorScheme == .dark, increasedContrast: contrast == .increased, size: size)
        let labels = Self.labels(for: alphabet)
        let prefix = labels.last.map { String($0.prefix(1)).uppercased() } ?? ""
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            row("Hints", labels: labels, typed: 0, visible: Array(labels.indices), style: style)
            row("After \(prefix)", labels: labels, typed: 1, visible: [4, 5], style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ caption: String, labels: [String], typed: Int, visible: [Int], style: ClickHintsPillStyle) -> some View {
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            Text(caption)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .frame(width: AOMSpace.x12 + AOMSpace.x4, alignment: .leading)
            HStack(spacing: AOMSpace.x3) {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { index, sample in
                    sampleItem(sample, label: labels.indices.contains(index) ? labels[index] : nil,
                               typed: typed, shown: visible.contains(index), style: style)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func sampleItem(_ sample: (title: String, symbol: String), label: String?, typed: Int, shown: Bool,
                            style: ClickHintsPillStyle) -> some View {
        let scale = max(1, displayScale)
        let inset = (style.height / 2).rounded()
        return ZStack(alignment: .topLeading) {
            Image(systemName: sample.symbol)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AOMIcon.hitArea + AOMSpace.x2, height: AOMIcon.hitArea)
                .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                        .strokeBorder(AOMColor.hairline, lineWidth: 0.5)
                }
                .padding(.top, inset)
                .padding(.leading, inset)
            if shown, let label,
               let image = ClickHintsPillRenderer.image(label: label, typed: typed, highlighted: false, style: style, scale: scale) {
                // Where the overlay puts it: on the corner, 3 pt up and left.
                Image(decorative: image, scale: scale)
                    .shadow(color: style.halo.map { Color(cgColor: $0) } ?? .clear, radius: 2)
                    .padding(.leading, inset + ClickHintsPlacement.cornerOffset.x)
                    .padding(.top, inset + ClickHintsPlacement.cornerOffset.y)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown && label != nil ? "\(sample.title), hint \(label!.uppercased())" : sample.title)
    }
}

// MARK: - App lists

/// The two app lists, saved as soon as they change.
@MainActor
final class ClickHintsAppLists: ObservableObject {
    private let settings: ClickHintsSettings
    @Published var excluded: [String] { didSet { if excluded != oldValue { settings.excludedApps = excluded } } }
    @Published var enhanced: [String] { didSet { if enhanced != oldValue { settings.enhancedApps = enhanced } } }

    init(defaults: UserDefaults = .standard) {
        settings = ClickHintsSettings(defaults: defaults)
        excluded = settings.excludedApps
        enhanced = settings.enhancedApps
    }
}

/// An app's name and icon, from its bundle identifier.
enum ClickHintsAppInfo {
    /// Names for the default exclusions when the app isn't installed.
    static let knownNames = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                             "com.bitwarden.desktop": "Bitwarden", "com.apple.keychainaccess": "Keychain Access",
                             "com.apple.Passwords": "Passwords"]

    static func url(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static func isInstalled(_ bundleID: String) -> Bool { url(bundleID) != nil }

    static func name(_ bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        guard let url = url(bundleID) else { return knownNames[bundleID] ?? bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage {
        if let url = url(bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// Chromium-based browsers and apps on Electron or the Chromium Embedded
    /// Framework: the ones that may need enhanced accessibility.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium"
    ]

    static func usesWebEngine(bundleID: String?, bundleURL: URL?) -> Bool {
        if let bundleID, chromiumBundleIDs.contains(bundleID) { return true }
        guard let frameworks = bundleURL?.appendingPathComponent("Contents/Frameworks", isDirectory: true) else { return false }
        let manager = FileManager.default
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
            manager.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        }
    }
}

/// A list of apps (icon, name, identifier, remove) with Add Running App…
/// and Add App…; every change is undoable.
struct ClickHintsAppList: View {
    @Binding var bundleIDs: [String]
    /// "Excluded" or "Enhanced", for undo names.
    let noun: String
    let emptySymbol: String
    let emptyMessage: String
    /// Chromium and Electron apps come first in Add Running App….
    let prefersWebApps: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if bundleIDs.isEmpty {
            AOMInlineEmpty(symbol: emptySymbol, message: emptyMessage)
        }
        ForEach(bundleIDs, id: \.self) { id in
            ClickHintsAppRow(bundleID: id) { remove(id) }
        }
        HStack(spacing: AOMSpace.x2) {
            Button("Add Running App…") { showRunningApps() }
                .help("Choose one of the apps that are open now")
            Button("Add App…") { chooseApps() }
                .help("Choose an app in Applications")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .frame(minHeight: AOMSize.rowStandard + AOMSpace.x2)
        .overlay(alignment: .top) { AOMRowDivider() }
    }

    private func change(_ name: String, to new: [String]) {
        let before = bundleIDs
        let after = ClickHintsSettings.cleaned(new)
        guard after != before else { return }
        AOMUndo.perform(name, undoManager: undoManager, perform: { bundleIDs = after }, revert: { bundleIDs = before })
    }

    private func remove(_ id: String) {
        change("Remove \(noun) App", to: bundleIDs.filter { $0 != id })
    }

    private func add(_ ids: [String]) {
        change(ids.count == 1 ? "Add \(noun) App" : "Add \(noun) Apps", to: bundleIDs + ids)
    }

    /// The running apps as a menu at the pointer, built only when asked.
    private func showRunningApps() {
        let own = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return id != own && !bundleIDs.contains(id)
        }
        .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        let menu = NSMenu()
        func entry(_ app: NSRunningApplication) -> NSMenuItem {
            let id = app.bundleIdentifier ?? ""
            let item = QuickAccessMenuAction.item(app.localizedName ?? id, symbol: nil) { add([id]) }
            // A copy: the running app's icon is shared.
            let icon = (app.icon?.copy() as? NSImage) ?? ClickHintsAppInfo.icon(id)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }
        if candidates.isEmpty {
            let none = NSMenuItem(title: "No Other Apps Are Open", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else if prefersWebApps {
            let web = candidates.filter { ClickHintsAppInfo.usesWebEngine(bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL) }
            let rest = candidates.filter { app in !web.contains { $0 == app } }
            if !web.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "Chromium and Electron Apps"))
                web.forEach { menu.addItem(entry($0)) }
                menu.addItem(.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: "Other Apps"))
            }
            rest.forEach { menu.addItem(entry($0)) }
        } else {
            candidates.forEach { menu.addItem(entry($0)) }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message = noun == "Excluded" ? "Choose the apps where hints never appear." : "Choose the apps to ask for their accessibility tree."
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        if !ids.isEmpty { add(ids) }
    }
}

/// One app: its icon, name and identifier, and a remove button.
struct ClickHintsAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let name = ClickHintsAppInfo.name(bundleID)
        let installed = ClickHintsAppInfo.isInstalled(bundleID)
        HStack(spacing: AOMSpace.x2) {
            Group {
                if installed {
                    Image(nsImage: ClickHintsAppInfo.icon(bundleID))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(AOMColor.textTertiary)
                }
            }
            .frame(width: AOMIcon.row, height: AOMIcon.row)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                Text(installed ? bundleID : "Not installed · \(bundleID)")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AOMSpace.x3)
            AOMIconButton("minus.circle", label: "Remove \(name)", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove") { remove() }
            if let url = ClickHintsAppInfo.url(bundleID) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bundleID, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

// MARK: - For the Text Actions list

/// The Click Hints row for the Text Actions page's list: the title and the
/// live shortcut.
struct ClickHintsListRow: View {
    @ObservedObject private var shortcuts = CaptureShortcuts.shared

    var body: some View {
        AOMListRow("Click Hints", detail: ClickHintsModule.shortcutAction.flatMap { shortcuts.shortcut(for: $0)?.displayString }
            ?? "Click with the keyboard") {
            Image(systemName: ClickHintsModule.symbol)
        }
    }
}
