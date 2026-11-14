import SwiftUI

/// The System Tools page's sections, in page order.
enum SystemToolGroup: String, CaseIterable, Identifiable {
    case toggles, display, power, apps, storage, network, homebrew, fixIt, tweaks

    var id: String { rawValue }

    var name: String {
        switch self {
        case .toggles: return "Quick Toggles"
        case .display: return "Display"
        case .power: return "Power & Session"
        case .apps: return "Apps"
        case .storage: return "Storage"
        case .network: return "Network"
        case .homebrew: return "Homebrew"
        case .fixIt: return "Fix It"
        case .tweaks: return "Tweaks"
        }
    }

    /// The section's SF Symbol, for section headers.
    var symbol: String {
        switch self {
        case .toggles: return "switch.2"
        case .display: return "display"
        case .power: return "power"
        case .apps: return "app.badge"
        case .storage: return "internaldrive"
        case .network: return "network"
        case .homebrew: return "mug"
        case .fixIt: return "wrench.and.screwdriver"
        case .tweaks: return "slider.horizontal.3"
        }
    }

    /// The glyph hue for the section's tiles.
    var tint: Color {
        switch self {
        case .toggles: return .blue
        case .display: return .pink
        case .power: return .purple
        case .apps: return .red
        case .storage: return .brown
        case .network: return .green
        case .homebrew: return .orange
        case .fixIt: return .indigo
        case .tweaks: return .cyan
        }
    }
}

/// How a tool is drawn: a live switch, a one-shot command, or a control that
/// opens a sheet, menu or alert (and shows its value when it has one).
enum SystemToolKind {
    case toggle, command, sheet
}

/// Every tool on the page. Raw values are persisted ids: favorites and the
/// recent list keep them, so kept tools never change theirs. Ids of merged
/// and removed tools are handled by `migratedID` and `storedTools`.
enum SystemToolID: String, CaseIterable, Identifiable {
    // Quick Toggles
    case darkMode, keepAwake, hideMenuBar, dockAutoHide, hidden, desktop, wifi, bluetooth, lowPower, keyboardClean
    // Display
    case resolution, brightness, metalHUD
    // Power & Session
    case lockScreen, sleep, sleepDisplays, sleepTimer, awakeWhileApp, batteryDetails, restart, shutDown, logOut, quitAll
    // Apps
    case activity, forceQuit, relaunchApp, uninstall, loginItems, awakeReasons, resetSavedState
    // Storage
    case freeUpSpace, eject, timeMachine, snapshots, verifyDisk, installDMG
    // Network
    case networkInfo, speedTest, ping, ports, vpn, dns, renewDHCP
    // Homebrew
    case homebrew
    // Fix It
    case finder, restartDock, restartMenuBar, launchServices, spotlight, fontCaches
    // Tweaks
    case extensions, pathbar, statusbar, posixtitle, showLibrary, dockactive, dockdelay, dockrecents
    case shotshadow, shotformat, shotfolder, startupChime

    var id: String { rawValue }
}

/// Ids 3.4.x persisted that 3.5.0 merged into one tool. Favorites and the
/// recent list pass through this table before they are filtered.
enum SystemToolMigration {
    static let map: [String: SystemToolID] = [
        "topCPU": .activity, "topMemory": .activity,
        "ejectAll": .eject, "ejectDisk": .eject,
        "backupNow": .timeMachine, "backupStatus": .timeMachine,
        "portLookup": .ports, "listeningPorts": .ports,
        "copyIP": .networkInfo, "publicIP": .networkInfo, "wifiDetails": .networkInfo, "dnsServers": .networkInfo,
        "brewOutdated": .homebrew, "brewUpgradeAll": .homebrew, "brewInstalled": .homebrew, "brewUpdate": .homebrew,
        "brewCleanup": .homebrew, "brewDoctor": .homebrew, "brewServices": .homebrew, "brewSearch": .homebrew,
        "cache": .freeUpSpace, "trash": .freeUpSpace, "largeFiles": .freeUpSpace, "oldDownloads": .freeUpSpace,
        "devJunk": .freeUpSpace, "duplicates": .freeUpSpace, "folderSizes": .freeUpSpace,
        "tailscale": .vpn, "openVPN": .vpn
    ]

    /// Ids that no longer name a tool: removed in 3.5.0, or moved to Files.
    /// Merged ids are not listed here; they already name a tool through `map`.
    static let removed: Set<String> = [
        // Audio page duplicates
        "muteSound", "muteMic", "alertVolume", "soundOutput", "soundInput", "volume",
        // macOS already offers these
        "reduceTransparency", "reduceMotion", "screenSaver", "hideOthers", "aboutMac", "copySerial",
        "settingsPane", "airDropSettings", "bluetoothSettings", "bootReasons",
        // Removed features
        "focus", "wallpaper", "dsstore", "lockFiles", "hideFiles", "copyFinderPath",
        "newTextFile", "terminalHere", "freeMemory",
        // Moved to the Files page
        "pdfmerge", "pdfcompress", "pdfSplit", "pdfExtract", "pdfRemovePages", "pdfRotate", "pdfReorder",
        "imagesToPDF", "pdfToImages", "pdfProtect", "pdfUnlock", "pdfPageNumbers",
        "imageconvert", "videoconvert", "qr", "rename", "whoLocks", "fileHash"
    ]
}

/// What a tool needs on this Mac to be offered at all.
enum SystemToolRequirement: Equatable {
    case homebrew

    var isMet: Bool {
        switch self {
        case .homebrew: return SystemToolAvailability.shared.hasHomebrew
        }
    }
}

/// Which optional commands exist, looked up at most every 10 s (the page asks
/// on every redraw).
final class SystemToolAvailability: @unchecked Sendable {
    static let shared = SystemToolAvailability()
    private let lock = NSLock()
    private var checkedAt: TimeInterval = -.infinity
    private var value = false

    var hasHomebrew: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if now - checkedAt < 10 { let cached = value; lock.unlock(); return cached }
        lock.unlock()
        let fresh = Homebrew.locate() != nil
        lock.lock(); value = fresh; checkedAt = now; lock.unlock()
        return fresh
    }

    func invalidate() {
        lock.lock(); checkedAt = -.infinity; lock.unlock()
    }
}

/// What a tile shows and searches: name, glyph, section, search keywords,
/// the one-line tooltip, and how it is drawn.
struct SystemToolInfo: Identifiable {
    let id: SystemToolID
    let title: String
    let symbol: String
    let group: SystemToolGroup
    let keywords: [String]
    let help: String
    var kind: SystemToolKind = .command
    /// Offered only when this is met (an app or command is installed).
    var requirement: SystemToolRequirement?

    var isAvailable: Bool { requirement?.isMet ?? true }
    var isToggle: Bool { kind == .toggle }

    /// Title, section name, keywords and the tooltip all count.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([title, group.name, help] + keywords).contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum SystemToolCatalog {
    static func info(_ id: SystemToolID) -> SystemToolInfo { byID[id]! }

    /// Every tool of the section, offered on this Mac or not.
    static func tools(in group: SystemToolGroup) -> [SystemToolInfo] { all.filter { $0.group == group } }

    /// The tools the page shows: everything whose requirement is met.
    static var available: [SystemToolInfo] { all.filter(\.isAvailable) }

    static func availableTools(in group: SystemToolGroup) -> [SystemToolInfo] { available.filter { $0.group == group } }

    static let byID: [SystemToolID: SystemToolInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let all: [SystemToolInfo] = [
        // Quick Toggles
        .init(id: .darkMode, title: "Dark Mode", symbol: "circle.lefthalf.filled", group: .toggles, keywords: ["appearance", "light", "theme"], help: "Switches macOS between light and dark appearance.", kind: .toggle),
        .init(id: .keepAwake, title: "Keep Awake", symbol: "cup.and.saucer", group: .toggles, keywords: ["caffeine", "sleep", "prevent"], help: "Keeps the Mac awake for a chosen time or until turned off.", kind: .toggle),
        .init(id: .hideMenuBar, title: "Hide Menu Bar", symbol: "rectangle.topthird.inset.filled", group: .toggles, keywords: ["menu bar", "auto-hide", "full screen"], help: "Hides the menu bar until the pointer reaches the top.", kind: .toggle),
        .init(id: .dockAutoHide, title: "Dock Auto-Hide", symbol: "dock.rectangle", group: .toggles, keywords: ["dock", "hide"], help: "Turns Dock hiding on or off.", kind: .toggle),
        .init(id: .hidden, title: "Hidden Files", symbol: "eye.trianglebadge.exclamationmark", group: .toggles, keywords: ["finder", "dotfiles", "invisible"], help: "Shows or hides hidden files in Finder.", kind: .toggle),
        .init(id: .desktop, title: "Desktop Icons", symbol: "menubar.rectangle", group: .toggles, keywords: ["finder", "clean desktop"], help: "Shows or hides the icons on the desktop.", kind: .toggle),
        .init(id: .wifi, title: "Wi-Fi", symbol: "wifi", group: .toggles, keywords: ["network", "wireless"], help: "Turns Wi-Fi on or off.", kind: .toggle),
        .init(id: .bluetooth, title: "Bluetooth Device", symbol: "airpods", group: .toggles, keywords: ["airpods", "headphones", "connect"], help: "Connects or disconnects a paired Bluetooth device.", kind: .toggle),
        .init(id: .lowPower, title: "Low Power Mode", symbol: "battery.25percent", group: .toggles, keywords: ["energy", "pmset", "battery saver"], help: "Turns Low Power Mode on or off.", kind: .toggle),
        .init(id: .keyboardClean, title: "Lock Keyboard", symbol: "keyboard.badge.ellipsis", group: .toggles, keywords: ["clean", "cleaning", "wipe"], help: "Ignores every key for up to two minutes while you clean the keyboard.", kind: .toggle),
        // Display
        .init(id: .resolution, title: "Resolution", symbol: "arrow.up.left.and.arrow.down.right", group: .display, keywords: ["display", "refresh rate", "hz", "scaled"], help: "Switches a display's resolution or refresh rate.", kind: .sheet),
        .init(id: .brightness, title: "Brightness", symbol: "sun.max", group: .display, keywords: ["display", "dim", "monitorcontrol"], help: "Sets a display's brightness, hardware where the display allows it.", kind: .sheet),
        .init(id: .metalHUD, title: "Metal HUD", symbol: "gauge.with.dots.needle.67percent", group: .display, keywords: ["fps", "frame rate", "gpu", "games", "performance"], help: "Shows Apple's performance HUD in apps you open afterwards.", kind: .toggle),
        // Power & Session
        .init(id: .lockScreen, title: "Lock Screen", symbol: "lock", group: .power, keywords: ["away", "security"], help: "Locks the screen now."),
        .init(id: .sleep, title: "Sleep", symbol: "moon.zzz", group: .power, keywords: ["suspend", "power"], help: "Puts the Mac to sleep."),
        .init(id: .sleepDisplays, title: "Sleep Displays", symbol: "display", group: .power, keywords: ["screen off", "monitor"], help: "Turns the displays off without sleeping the Mac."),
        .init(id: .sleepTimer, title: "Sleep Timer", symbol: "timer", group: .power, keywords: ["sleep in", "countdown", "bedtime"], help: "Puts the Mac to sleep after a delay you choose.", kind: .sheet),
        .init(id: .awakeWhileApp, title: "Awake While App Runs", symbol: "app.badge.checkmark", group: .power, keywords: ["keep awake", "prevent sleep", "app"], help: "Keeps the Mac awake until an app you pick quits.", kind: .sheet),
        .init(id: .batteryDetails, title: "Battery Details", symbol: "battery.100percent", group: .power, keywords: ["cycle count", "health", "capacity", "temperature", "condition"], help: "Shows charge, cycle count, condition, capacity and temperature."),
        .init(id: .restart, title: "Restart…", symbol: "restart", group: .power, keywords: ["reboot", "power"], help: "Asks first, then restarts the Mac."),
        .init(id: .shutDown, title: "Shut Down…", symbol: "power", group: .power, keywords: ["power off", "turn off"], help: "Asks first, then shuts the Mac down."),
        .init(id: .logOut, title: "Log Out…", symbol: "rectangle.portrait.and.arrow.right", group: .power, keywords: ["sign out", "session"], help: "Asks first, then logs you out."),
        .init(id: .quitAll, title: "Quit All Apps…", symbol: "xmark.app", group: .power, keywords: ["close", "apps", "clean slate"], help: "Asks every app except Finder and All of MacOS to quit."),
        // Apps
        .init(id: .activity, title: "Activity…", symbol: "gauge.with.dots.needle.33percent", group: .apps, keywords: ["activity monitor", "processes", "cpu", "memory", "ram", "ps"], help: "Lists the busiest processes by CPU or memory, with Quit.", kind: .sheet),
        .init(id: .forceQuit, title: "Force Quit App…", symbol: "xmark.octagon", group: .apps, keywords: ["kill", "frozen", "not responding", "beachball"], help: "Stops an open app at once; its unsaved work is lost."),
        .init(id: .relaunchApp, title: "Relaunch App", symbol: "arrow.clockwise.circle", group: .apps, keywords: ["restart app", "reopen"], help: "Quits an open app and opens it again.", kind: .sheet),
        .init(id: .uninstall, title: "Uninstall App…", symbol: "xmark.bin", group: .apps, keywords: ["leftovers", "remove", "residue", "cleanup"], help: "Lists an app with the files it left in ~/Library before anything moves to the Trash."),
        .init(id: .loginItems, title: "Login Items", symbol: "person.crop.circle.badge.clock", group: .apps, keywords: ["startup", "launch agents", "open at login"], help: "Lists apps that open at login and launch agents."),
        .init(id: .awakeReasons, title: "What's Keeping Awake", symbol: "eye", group: .apps, keywords: ["assertions", "pmset", "insomnia"], help: "Lists what stops the Mac or its display from sleeping now."),
        .init(id: .resetSavedState, title: "Reset Window State…", symbol: "rectangle.stack.badge.minus", group: .apps, keywords: ["saved application state", "reopen windows"], help: "Trashes saved window state so apps open without their old windows."),
        // Storage
        .init(id: .freeUpSpace, title: "Free Up Space…", symbol: "externaldrive.badge.minus", group: .storage, keywords: ["cleanup", "trash", "caches", "large files", "duplicates", "xcode", "folder sizes", "downloads", "space"], help: "Finds folder sizes, large files, old downloads, duplicates, Xcode data, caches and Trash items."),
        .init(id: .eject, title: "Eject…", symbol: "eject", group: .storage, keywords: ["usb", "drive", "disk image", "unmount", "external"], help: "Ejects a volume you pick, or every external disk.", kind: .sheet),
        .init(id: .timeMachine, title: "Time Machine", symbol: "clock.arrow.2.circlepath", group: .storage, keywords: ["backup", "tmutil", "latest backup"], help: "Shows the backup state and starts one.", kind: .sheet),
        .init(id: .snapshots, title: "Local Snapshots", symbol: "camera.on.rectangle", group: .storage, keywords: ["apfs", "tmutil", "purgeable", "space"], help: "Lists the startup disk's APFS local snapshots."),
        .init(id: .verifyDisk, title: "Verify Startup Disk", symbol: "checkmark.shield", group: .storage, keywords: ["diskutil", "first aid", "fsck"], help: "Checks the startup volume without changing it."),
        .init(id: .installDMG, title: "Install Disk Image…", symbol: "externaldrive.badge.plus", group: .storage, keywords: ["dmg", "install", "hdiutil", "disk image"], help: "Copies the app inside a disk image into Applications and ejects the image."),
        // Network
        .init(id: .networkInfo, title: "Network Info…", symbol: "network", group: .network, keywords: ["ip", "local", "public", "wifi", "dns", "rssi", "signal"], help: "Shows the local and public address, Wi-Fi details and DNS servers, each copyable.", kind: .sheet),
        .init(id: .speedTest, title: "Speed Test", symbol: "speedometer", group: .network, keywords: ["networkquality", "bandwidth", "internet"], help: "Measures download, upload and responsiveness with Apple's networkQuality."),
        .init(id: .ping, title: "Ping…", symbol: "waveform.path.ecg", group: .network, keywords: ["latency", "packet loss", "reachability"], help: "Pings a host and shows the latency and packet loss."),
        .init(id: .ports, title: "Ports…", symbol: "point.3.connected.trianglepath.dotted", group: .network, keywords: ["lsof", "listen", "localhost", "port", "open ports"], help: "Lists the processes using or listening on a port, with Quit.", kind: .sheet),
        .init(id: .vpn, title: "VPN…", symbol: "lock.shield", group: .network, keywords: ["vpn", "tailscale", "openvpn", "scutil", "tunnel", "exit node"], help: "Connects or disconnects the VPNs set up on this Mac and Tailscale.", kind: .sheet),
        .init(id: .dns, title: "Flush DNS", symbol: "arrow.triangle.2.circlepath", group: .network, keywords: ["cache", "mdnsresponder", "resolver"], help: "Clears the DNS cache."),
        .init(id: .renewDHCP, title: "Renew DHCP", symbol: "arrow.triangle.2.circlepath.circle", group: .network, keywords: ["lease", "ip address", "router"], help: "Asks the router for a fresh address on the active interface."),
        // Homebrew
        .init(id: .homebrew, title: "Homebrew…", symbol: "mug", group: .homebrew, keywords: ["brew", "outdated", "upgrade", "installed", "services", "search", "doctor"], help: "Opens outdated, installed and service packages with their live log.", requirement: .homebrew),
        // Fix It
        .init(id: .finder, title: "Restart Finder", symbol: "arrow.clockwise", group: .fixIt, keywords: ["relaunch", "finder"], help: "Quits and reopens Finder."),
        .init(id: .restartDock, title: "Restart Dock", symbol: "arrow.triangle.2.circlepath", group: .fixIt, keywords: ["relaunch", "dock", "stuck"], help: "Quits the Dock; macOS opens it again at once."),
        .init(id: .restartMenuBar, title: "Restart Menu Bar", symbol: "menubar.arrow.up.rectangle", group: .fixIt, keywords: ["systemuiserver", "control center", "stuck"], help: "Restarts SystemUIServer and Control Center."),
        .init(id: .launchServices, title: "Rebuild Open With", symbol: "list.bullet.rectangle", group: .fixIt, keywords: ["launch services", "lsregister", "default app"], help: "Re-registers apps to fix duplicate or missing Open With entries."),
        .init(id: .spotlight, title: "Reindex Spotlight", symbol: "magnifyingglass", group: .fixIt, keywords: ["mdutil", "search", "index"], help: "Rebuilds the Spotlight index of the startup disk."),
        .init(id: .fontCaches, title: "Clear Font Caches", symbol: "textformat", group: .fixIt, keywords: ["atsutil", "fonts", "garbled"], help: "Removes your account's font caches."),
        // Tweaks
        .init(id: .extensions, title: "File Extensions", symbol: "doc.text", group: .tweaks, keywords: ["finder", "suffix", "show all"], help: "Shows every file name extension in Finder.", kind: .toggle),
        .init(id: .pathbar, title: "Path Bar", symbol: "point.topleft.down.to.point.bottomright.curvepath", group: .tweaks, keywords: ["finder", "breadcrumb"], help: "Shows the path bar at the bottom of Finder windows.", kind: .toggle),
        .init(id: .statusbar, title: "Status Bar", symbol: "rectangle.bottomthird.inset.filled", group: .tweaks, keywords: ["finder", "free space", "items"], help: "Shows the item count and free space in Finder windows.", kind: .toggle),
        .init(id: .posixtitle, title: "Full Path in Title", symbol: "textformat.abc.dottedunderline", group: .tweaks, keywords: ["finder", "posix", "title bar"], help: "Shows the folder's full path in the Finder window title.", kind: .toggle),
        .init(id: .showLibrary, title: "Library Folder", symbol: "building.columns", group: .tweaks, keywords: ["~/library", "chflags", "hidden folder"], help: "Shows or hides your Library folder in Finder.", kind: .toggle),
        .init(id: .dockactive, title: "Open Apps Only", symbol: "dock.arrow.up.rectangle", group: .tweaks, keywords: ["dock", "static only", "running"], help: "Keeps only running apps in the Dock.", kind: .toggle),
        .init(id: .dockdelay, title: "Instant Dock", symbol: "hare", group: .tweaks, keywords: ["dock", "autohide delay", "fast"], help: "Removes the delay before a hidden Dock appears.", kind: .toggle),
        .init(id: .dockrecents, title: "Dock Recents", symbol: "clock.arrow.circlepath", group: .tweaks, keywords: ["dock", "recents", "suggested"], help: "Shows recent and suggested apps in the Dock.", kind: .toggle),
        .init(id: .shotshadow, title: "Screenshot Shadows", symbol: "shadow", group: .tweaks, keywords: ["screenshot", "capture", "disable-shadow"], help: "Keeps or drops the shadow on window screenshots.", kind: .toggle),
        .init(id: .shotformat, title: "Screenshot Format", symbol: "photo", group: .tweaks, keywords: ["png", "jpg", "heic", "pdf", "capture"], help: "Chooses the file format of macOS screenshots.", kind: .sheet),
        .init(id: .shotfolder, title: "Screenshot Folder", symbol: "folder", group: .tweaks, keywords: ["screenshot folder", "location", "capture"], help: "Chooses where macOS saves screenshots.", kind: .sheet),
        .init(id: .startupChime, title: "Startup Sound", symbol: "power.circle", group: .tweaks, keywords: ["chime", "boot sound", "startupmute", "nvram"], help: "Turns the startup chime on or off in the firmware.", kind: .toggle)
    ]
}
