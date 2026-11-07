import AppKit
import UniformTypeIdentifiers

/// Folder Rules (3.4.0): Hazel-style rules for watched folders, Clop-style
/// image optimizing and Rapidmg-style app installs from disk images.
/// `AOMProductivityModules` calls `start()` at launch and collects
/// `statusMenuItems()` for the status menu's Productivity section.
@MainActor
enum FolderRulesModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {
        let engine = FolderRulesEngine.shared
        engine.start()
        FolderRulesApprovalPanel.shared.observe(engine)
    }

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] {
        let engine = FolderRulesEngine.shared
        var items: [NSMenuItem] = []
        if engine.config.rules.isEmpty {
            items.append(FolderRulesMenuItem(title: "Set Up Folder Rules…", symbol: "folder.badge.gearshape",
                                             toolTip: "Opens Folder Rules to add a rule or a template") { openPage() })
        } else {
            let run = FolderRulesMenuItem(title: "Run Folder Rules Now", symbol: "arrow.clockwise.circle",
                                          toolTip: "Checks the watched folders now") { engine.runNow() }
            run.isEnabled = engine.isActive
            items.append(run)
            let on = engine.config.isEnabled
            items.append(FolderRulesMenuItem(title: on ? "Pause Folder Rules" : "Resume Folder Rules",
                                             symbol: on ? "pause.circle" : "play.circle",
                                             toolTip: on ? "Stops watching folders until you resume" : "Starts watching folders again") {
                engine.setMasterEnabled(!on)
            })
        }
        let waiting = engine.waitingCount
        if waiting > 0 {
            items.append(FolderRulesMenuItem(title: "Review Waiting Actions (\(waiting))…", symbol: "checkmark.circle",
                                             toolTip: "Opens Folder Rules to approve or skip them") { openPage() })
        }
        items.append(FolderRulesMenuItem(title: "Install Disk Image…", symbol: "externaldrive.badge.plus",
                                         toolTip: "Installs the app from a disk image you choose") { installDiskImage() })
        return items
    }

    /// "Install Disk Image…": choose a .dmg, then its app is copied to
    /// Applications (asking before replacing one), the image is ejected and,
    /// if the box stays checked, moved to the Trash. The System Tools tile
    /// calls this too.
    static func installDiskImage() {
        let panel = NSOpenPanel()
        panel.title = "Install Disk Image"
        panel.message = "Choose a disk image. Its app is copied to Applications."
        panel.prompt = "Install"
        panel.allowedContentTypes = [.diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FolderRulesLocations.downloads
        let trashBox = NSButton(checkboxWithTitle: "Move the disk image to the Trash after installing", target: nil, action: nil)
        trashBox.state = .on
        trashBox.setAccessibilityLabel("Move the disk image to the Trash after installing")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 36))
        trashBox.frame = NSRect(x: 16, y: 8, width: 360, height: 20)
        accessory.addSubview(trashBox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        AOMOverlayActivation.activateForOverlay()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            FolderRulesEngine.shared.installDiskImage(url, trashAfter: trashBox.state == .on)
        }
    }

    /// Shows the Folder Rules page in the main window.
    static func openPage() {
        AppDelegate.current?.appState?.selectedMainTab = .folderRules
        AppDelegate.current?.showMainWindow()
    }
}

/// A status-menu item that runs a closure.
@MainActor
final class FolderRulesMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, toolTip: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.toolTip = toolTip
    }

    required init(coder: NSCoder) { fatalError("FolderRulesMenuItem is created in code only") }

    @objc private func run() { handler() }
}
