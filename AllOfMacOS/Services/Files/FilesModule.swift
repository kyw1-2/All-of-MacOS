import AppKit
import Combine

/// Files (3.4): the Open and Save dialog helper (Default Folder X), the Drop
/// Shelf (Dropover, Yoink) and recent downloads and screenshots.
/// `AOMProductivityModules` calls `start()` once at launch and
/// `statusMenuItems()` for each status-menu click; the hotkey, the status menu
/// and Workspace call `showShelf()`.
@MainActor
enum FilesModule {
    private static var started = false
    private static var cancellables: Set<AnyCancellable> = []
    private static var observers: [NSObjectProtocol] = []
    /// Set after Downloads was read once, so later launches may read it again
    /// for the Workspace count without a first-time privacy prompt at launch.
    static let downloadsReadKey = "AOMFilesDownloadsRead"

    /// Called once at launch (never in UI previews or unit tests). Starts only
    /// what the saved settings turn on.
    static func start() {
        guard !started else { return }
        started = true
        let settings = FilesSettings.shared
        settings.didChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { applySettings() } }
            .store(in: &cancellables)
        FilesShakeMonitor.shared.onShake = { point in FilesShelfPanelController.shared.show(at: point) }
        FilesDialogHelper.shared.onChange = { publishStatus() }
        FilesRecentModel.shared.onChange = {
            if FilesRecentModel.shared.downloadsReadable { settings.defaults.set(true, forKey: downloadsReadKey) }
            publishStatus()
        }
        for name in [PermissionWatchdog.accessibilityRecovered, PermissionWatchdog.accessibilityLost] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { applySettings() }
            })
        }
        AOMModuleStatusBoard.files.setOn = { on in
            settings.dialogHelper = on
            settings.shakeOpensShelf = on
        }
        _ = FilesShelfPanelController.shared
        applySettings()
        if settings.defaults.bool(forKey: downloadsReadKey) { FilesRecentModel.shared.refresh() }
    }

    /// Shows the Drop Shelf beside the pointer (hotkey, menus, Workspace).
    static func showShelf() {
        FilesShelfPanelController.shared.show()
    }

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] {
        let shelf = QuickAccessMenuAction.item("Show Drop Shelf", symbol: "tray.and.arrow.down") {
            MainActor.assumeIsolated { FilesModule.showShelf() }
        }
        shelf.toolTip = "Opens the Drop Shelf, a place to hold files while you switch apps or desktops"
        let recent = NSMenuItem(title: "Recent Downloads", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        let submenu = NSMenu(title: "Recent Downloads")
        submenu.delegate = FilesRecentDownloadsMenu.shared
        // One placeholder so the arrow shows; the delegate fills it on open.
        submenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        recent.submenu = submenu
        return [shelf, recent]
    }

    /// Opens the Files page in the main window.
    static func openPage() {
        guard let delegate = AppDelegate.current ?? (NSApp.delegate as? AppDelegate) else { return }
        delegate.appState?.selectedMainTab = .files
        delegate.showMainWindow()
    }

    /// Starts and stops the parts the settings turn on.
    static func applySettings() {
        let settings = FilesSettings.shared
        FilesDialogHelper.shared.refresh()
        if PresetManager.isUIPreview || PresetManager.isRunningTests {
            FilesShakeMonitor.shared.stop()
        } else {
            FilesShakeMonitor.shared.configure(shake: settings.shakeOpensShelf, shift: settings.shiftOpensShelf,
                                               sensitivity: settings.sensitivity,
                                               isExcluded: { settings.isExcluded($0) })
        }
        publishStatus()
    }

    /// Writes the live summary for Workspace and the sidebar.
    static func publishStatus() {
        let settings = FilesSettings.shared
        let status = AOMModuleStatusBoard.files
        let shelfCount = FilesShelfStore.shared.items.count
        let recent = FilesRecentModel.shared
        let summary = statusSummary(dialogHelper: settings.dialogHelper, shake: settings.shakeOpensShelf || settings.shiftOpensShelf,
                                    needsAccessibility: settings.dialogHelper && !AXIsProcessTrusted(),
                                    shelfCount: shelfCount, downloadsToday: recent.loaded ? recent.downloadsToday : nil)
        if status.isOn != summary.isOn { status.isOn = summary.isOn }
        if status.count != summary.count { status.count = summary.count }
        if status.unit != summary.unit { status.unit = summary.unit }
        if status.detail != summary.detail { status.detail = summary.detail }
        if status.attention != summary.attention { status.attention = summary.attention }
    }

    struct StatusSummary: Equatable {
        var isOn: Bool
        var count: Int?
        var unit: String
        var detail: String
        var attention: String?
    }

    /// The tile's values from the module's state (pure, unit-tested).
    static func statusSummary(dialogHelper: Bool, shake: Bool, needsAccessibility: Bool,
                              shelfCount: Int, downloadsToday: Int?) -> StatusSummary {
        let detail: String
        switch (dialogHelper, shake) {
        case (true, true): detail = "Dialog helper and shake to open the shelf"
        case (true, false): detail = "Folders beside Open and Save dialogs"
        case (false, true): detail = "Shake while dragging opens the shelf"
        case (false, false): detail = "Dialog helper and shake are off"
        }
        var summary = StatusSummary(isOn: dialogHelper || shake, count: nil, unit: "", detail: detail,
                                    attention: needsAccessibility ? "Needs Accessibility for Open and Save dialogs" : nil)
        if shelfCount > 0 {
            summary.count = shelfCount
            summary.unit = shelfCount == 1 ? "item on the shelf" : "items on the shelf"
        } else if let downloadsToday {
            summary.count = downloadsToday
            summary.unit = downloadsToday == 1 ? "download today" : "downloads today"
        }
        return summary
    }
}

/// Fills the status menu's Recent Downloads when it opens (not when the
/// status menu opens), so Downloads is read only when someone looks.
@MainActor
final class FilesRecentDownloadsMenu: NSObject, NSMenuDelegate {
    static let shared = FilesRecentDownloadsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = FilesRecentModel.shared
        let files = model.downloadsNow(limit: 10)
        if model.downloadsReadable { FilesSettings.shared.defaults.set(true, forKey: FilesModule.downloadsReadKey) }
        if files.isEmpty {
            let empty = NSMenuItem(title: model.downloadsReadable ? "No Recent Downloads" : "Downloads Can't Be Read",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            if !model.downloadsReadable {
                empty.toolTip = "Allow All of MacOS to read the Downloads folder in System Settings › Privacy & Security › Files and Folders"
            }
            menu.addItem(empty)
        }
        for file in files {
            let url = file.url
            let item = QuickAccessMenuAction.item(file.name, symbol: nil) {
                MainActor.assumeIsolated { _ = FilesFileActions.open([url]) }
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = "\(FilesPath.abbreviated(url.path)) · added \(AOMRelativeTime.string(file.added).lowercased())"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = model.downloadsFolder
        menu.addItem(QuickAccessMenuAction.item("Show Downloads in Finder", symbol: nil) {
            MainActor.assumeIsolated { _ = NSWorkspace.shared.open(folder) }
        })
        menu.addItem(QuickAccessMenuAction.item("Open Files…", symbol: nil) {
            MainActor.assumeIsolated { FilesModule.openPage() }
        })
    }
}
