import SwiftUI

/// The System Tools page's groups, in page order.
enum SystemToolGroup: String, CaseIterable, Identifiable {
    case toggles, displaySound, power, energy, apps, finderDock, screenshots, disk, maintenance, cleanup, files, network, info

    var id: String { rawValue }

    var name: String {
        switch self {
        case .toggles: return "Quick Toggles"
        case .displaySound: return "Display & Sound"
        case .power: return "Power & Session"
        case .energy: return "Battery & Energy"
        case .apps: return "Apps & Processes"
        case .finderDock: return "Finder & Dock"
        case .screenshots: return "Screenshots"
        case .disk: return "Disk & Storage"
        case .maintenance: return "Maintenance"
        case .cleanup: return "Cleanup"
        case .files: return "Files, PDF & Media"
        case .network: return "Network"
        case .info: return "System Info"
        }
    }

    /// The group's SF Symbol, for section headers.
    var symbol: String {
        switch self {
        case .toggles: return "switch.2"
        case .displaySound: return "display"
        case .power: return "power"
        case .energy: return "battery.75percent"
        case .apps: return "app.badge"
        case .finderDock: return "folder"
        case .screenshots: return "camera.viewfinder"
        case .disk: return "internaldrive"
        case .maintenance: return "wrench.and.screwdriver"
        case .cleanup: return "trash"
        case .files: return "doc.on.doc"
        case .network: return "network"
        case .info: return "info.circle"
        }
    }

    /// The glyph hue for the group's tiles (colour for grouping, as before).
    var tint: Color {
        switch self {
        case .toggles: return .blue
        case .displaySound: return .pink
        case .power: return .purple
        case .energy: return .green
        case .apps: return .red
        case .finderDock: return .cyan
        case .screenshots: return .mint
        case .disk: return .brown
        case .maintenance: return .indigo
        case .cleanup: return .teal
        case .files: return .orange
        case .network: return .green
        case .info: return .gray
        }
    }
}

/// Every tool on the page. Raw values are stable ids: favorites and the
/// recent list persist them, and the 3.3.4 and 3.3.5 ids are kept unchanged.
/// Ids of removed tools (3.3.5's Text & Developer group) simply no longer
/// decode, and `SystemToolsModel.storedTools` drops them.
enum SystemToolID: String, CaseIterable, Identifiable {
    // Quick Toggles
    case darkMode, keepAwake, hidden, desktop, dockAutoHide, wifi, muteSound, muteMic, bluetooth, focus, keyboardClean
    case lowPower, hideMenuBar
    // Display & Sound
    case resolution, brightness, wallpaper, reduceTransparency, reduceMotion, soundOutput, soundInput, volume, alertVolume, startupChime
    // Power & Session
    case lockScreen, sleep, sleepDisplays, screenSaver, restart, shutDown, logOut, quitAll, hideOthers
    // Battery & Energy
    case batteryDetails, sleepTimer, awakeWhileApp, awakeReasons
    // Apps & Processes
    case forceQuit, topCPU, topMemory, relaunchApp, loginItems, resetSavedState
    // Finder & Dock
    case finder, extensions, pathbar, statusbar, posixtitle, dockactive, dockdelay, dockrecents, restartDock
    case showLibrary, copyFinderPath, newTextFile, terminalHere
    // Screenshots
    case shotshadow, shotformat, shotfolder
    // Disk & Storage
    case ejectAll, ejectDisk, verifyDisk, backupNow, backupStatus, snapshots
    // Maintenance
    case restartMenuBar, launchServices, spotlight, fontCaches, freeMemory
    // Cleanup
    case cache, dsstore, trash, uninstall, largeFiles, oldDownloads, devJunk
    // Files, PDF & Media
    case pdfmerge, pdfcompress, imageconvert, videoconvert, qr, rename, lockFiles, hideFiles, whoLocks, fileHash
    case duplicates, folderSizes
    // Network
    case dns, speedTest, portLookup, copyIP, wifiDetails, publicIP, ping, dnsServers, renewDHCP, listeningPorts
    case airDropSettings, bluetoothSettings
    // System Info
    case aboutMac, copySerial, bootReasons, settingsPane

    var id: String { rawValue }
}

/// What a tile shows and searches: name, glyph, group, search keywords and
/// the one-line tooltip. `isToggle` tiles carry a live state pill.
struct SystemToolInfo: Identifiable {
    let id: SystemToolID
    let title: String
    let symbol: String
    let group: SystemToolGroup
    let keywords: [String]
    let help: String
    var isToggle = false

    /// Title, group name, keywords and the tooltip all count, so "awake",
    /// "lsof", "battery" or "trash" find their tools.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([title, group.name, help] + keywords).contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum SystemToolCatalog {
    static func info(_ id: SystemToolID) -> SystemToolInfo { byID[id]! }

    static func tools(in group: SystemToolGroup) -> [SystemToolInfo] { all.filter { $0.group == group } }

    private static let byID: [SystemToolID: SystemToolInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    // swiftlint:disable line_length
    static let all: [SystemToolInfo] = [
        // Quick Toggles
        .init(id: .darkMode, title: "Dark Mode", symbol: "circle.lefthalf.filled", group: .toggles, keywords: ["appearance", "light", "theme"], help: "Switches macOS between light and dark appearance (needs Automation for System Events).", isToggle: true),
        .init(id: .keepAwake, title: "Keep Awake", symbol: "cup.and.saucer", group: .toggles, keywords: ["caffeine", "amphetamine", "sleep", "prevent"], help: "Keeps the Mac awake for a chosen time or until turned off.", isToggle: true),
        .init(id: .hidden, title: "Hidden Files", symbol: "eye.trianglebadge.exclamationmark", group: .toggles, keywords: ["finder", "dotfiles", "invisible"], help: "Shows or hides hidden files in Finder, then restarts Finder.", isToggle: true),
        .init(id: .desktop, title: "Desktop Icons", symbol: "menubar.rectangle", group: .toggles, keywords: ["finder", "clean desktop", "presentation"], help: "Shows or hides the icons on the desktop, then restarts Finder.", isToggle: true),
        .init(id: .dockAutoHide, title: "Dock Auto-Hide", symbol: "dock.rectangle", group: .toggles, keywords: ["dock", "hide"], help: "Turns Dock hiding on or off (needs Automation for System Events).", isToggle: true),
        .init(id: .wifi, title: "Wi-Fi", symbol: "wifi", group: .toggles, keywords: ["network", "airport", "wireless"], help: "Turns Wi-Fi on or off.", isToggle: true),
        .init(id: .muteSound, title: "Mute Sound", symbol: "speaker.slash", group: .toggles, keywords: ["volume", "audio", "output"], help: "Mutes or unmutes the current sound output.", isToggle: true),
        .init(id: .muteMic, title: "Mute Microphone", symbol: "mic.slash", group: .toggles, keywords: ["input", "audio", "call"], help: "Mutes or unmutes the default microphone.", isToggle: true),
        .init(id: .bluetooth, title: "Bluetooth Device", symbol: "airpods", group: .toggles, keywords: ["airpods", "headphones", "connect", "bluetooth"], help: "Connects or disconnects a paired Bluetooth device, such as AirPods."),
        .init(id: .focus, title: "Focus", symbol: "moon", group: .toggles, keywords: ["do not disturb", "dnd", "notifications"], help: "Runs your “Toggle Focus” shortcut. macOS doesn't let apps read or set Focus directly, so the state isn't shown."),
        .init(id: .keyboardClean, title: "Lock Keyboard", symbol: "keyboard.badge.ellipsis", group: .toggles, keywords: ["clean", "cleaning", "wipe", "keyboard"], help: "Ignores every key for up to two minutes while you clean the keyboard; the pointer still works.", isToggle: true),
        .init(id: .lowPower, title: "Low Power Mode", symbol: "battery.25percent", group: .toggles, keywords: ["energy", "pmset", "battery saver"], help: "Turns Low Power Mode on or off on battery and power adapter (pmset, asks for an administrator).", isToggle: true),
        .init(id: .hideMenuBar, title: "Hide Menu Bar", symbol: "rectangle.topthird.inset.filled", group: .toggles, keywords: ["menu bar", "auto-hide", "autohide", "full screen"], help: "Hides the menu bar until the pointer reaches the top of the screen (needs Automation for System Events).", isToggle: true),
        // Display & Sound
        .init(id: .resolution, title: "Resolution", symbol: "arrow.up.left.and.arrow.down.right", group: .displaySound, keywords: ["display", "refresh rate", "hz", "scaled", "betterdisplay"], help: "Switches a display's resolution or refresh rate; the current mode is checked in the menu.", isToggle: true),
        .init(id: .brightness, title: "Brightness", symbol: "sun.max", group: .displaySound, keywords: ["display", "dim", "monitorcontrol"], help: "Sets a display's brightness: hardware where the display allows it, otherwise a software dim that AOM undoes when it quits.", isToggle: true),
        .init(id: .wallpaper, title: "Wallpaper", symbol: "photo.on.rectangle", group: .displaySound, keywords: ["desktop picture", "background"], help: "Sets a picture you choose as the wallpaper on every display.", isToggle: true),
        .init(id: .reduceTransparency, title: "Reduce Transparency", symbol: "square.on.square.dashed", group: .displaySound, keywords: ["accessibility", "blur", "glass"], help: "Shows whether Reduce Transparency is on and opens Accessibility settings to change it (macOS doesn't let apps change it).", isToggle: true),
        .init(id: .reduceMotion, title: "Reduce Motion", symbol: "figure.walk.motion", group: .displaySound, keywords: ["accessibility", "animation"], help: "Shows whether Reduce Motion is on and opens Accessibility settings to change it (macOS doesn't let apps change it).", isToggle: true),
        .init(id: .soundOutput, title: "Sound Output", symbol: "hifispeaker", group: .displaySound, keywords: ["speakers", "headphones", "audio device", "soundsource"], help: "Switches the sound output device; the current one is checked in the menu.", isToggle: true),
        .init(id: .soundInput, title: "Sound Input", symbol: "mic", group: .displaySound, keywords: ["microphone", "audio device"], help: "Switches the microphone; the current one is checked in the menu.", isToggle: true),
        .init(id: .volume, title: "Volume", symbol: "speaker.wave.2", group: .displaySound, keywords: ["output volume", "loudness", "preset"], help: "Sets the output volume to a preset level.", isToggle: true),
        .init(id: .alertVolume, title: "Alert Volume", symbol: "bell", group: .displaySound, keywords: ["beep", "alert sound", "system sounds"], help: "Sets the volume of alert sounds, separate from the output volume.", isToggle: true),
        .init(id: .startupChime, title: "Startup Sound", symbol: "power.circle", group: .displaySound, keywords: ["chime", "boot sound", "startupmute", "nvram"], help: "Turns the startup chime on or off (the StartupMute firmware setting; asks for an administrator).", isToggle: true),
        // Power & Session
        .init(id: .lockScreen, title: "Lock Screen", symbol: "lock", group: .power, keywords: ["away", "security"], help: "Locks the screen right away."),
        .init(id: .sleep, title: "Sleep", symbol: "moon.zzz", group: .power, keywords: ["suspend", "power"], help: "Puts the Mac to sleep."),
        .init(id: .sleepDisplays, title: "Sleep Displays", symbol: "display", group: .power, keywords: ["screen off", "monitor"], help: "Turns the displays off without sleeping the Mac."),
        .init(id: .screenSaver, title: "Screen Saver", symbol: "sparkles.tv", group: .power, keywords: ["screensaver"], help: "Starts the screen saver."),
        .init(id: .restart, title: "Restart…", symbol: "restart", group: .power, keywords: ["reboot", "power"], help: "Asks first, then restarts the Mac the normal way (apps can still ask to save)."),
        .init(id: .shutDown, title: "Shut Down…", symbol: "power", group: .power, keywords: ["power off", "turn off"], help: "Asks first, then shuts the Mac down the normal way."),
        .init(id: .logOut, title: "Log Out…", symbol: "rectangle.portrait.and.arrow.right", group: .power, keywords: ["sign out", "session"], help: "Asks first, then logs you out."),
        .init(id: .quitAll, title: "Quit All Apps…", symbol: "xmark.app", group: .power, keywords: ["close", "apps", "clean slate"], help: "Asks first, then asks every app except Finder and All of MacOS to quit."),
        .init(id: .hideOthers, title: "Hide Other Apps", symbol: "eye.slash", group: .power, keywords: ["focus", "declutter"], help: "Hides every app except All of MacOS."),
        // Battery & Energy
        .init(id: .batteryDetails, title: "Battery Details", symbol: "battery.100percent", group: .energy, keywords: ["coconutbattery", "cycle count", "health", "capacity", "temperature", "condition"], help: "Shows charge, cycle count, condition, capacity in mAh and temperature (coconutBattery style)."),
        .init(id: .sleepTimer, title: "Sleep Timer", symbol: "timer", group: .energy, keywords: ["sleep in", "countdown", "bedtime"], help: "Puts the Mac to sleep after 15 minutes to 2 hours. The timer runs in All of MacOS, so it only fires while AOM is open.", isToggle: true),
        .init(id: .awakeWhileApp, title: "Awake While App Runs", symbol: "app.badge.checkmark", group: .energy, keywords: ["amphetamine", "keep awake", "prevent sleep", "app"], help: "Keeps the Mac awake until an app you pick quits; the display may still sleep.", isToggle: true),
        .init(id: .awakeReasons, title: "What's Keeping Awake", symbol: "eye", group: .energy, keywords: ["assertions", "pmset", "insomnia", "sleep prevented"], help: "Lists the apps that stop the Mac or its display from sleeping right now (pmset -g assertions)."),
        // Apps & Processes
        .init(id: .forceQuit, title: "Force Quit App…", symbol: "xmark.octagon", group: .apps, keywords: ["kill", "frozen", "not responding", "beachball"], help: "Pick an open app; after you confirm it is force quit and its unsaved work is lost."),
        .init(id: .topCPU, title: "Top CPU", symbol: "cpu", group: .apps, keywords: ["activity monitor", "processes", "busy", "ps"], help: "Lists the processes using the most CPU right now, with Quit."),
        .init(id: .topMemory, title: "Top Memory", symbol: "square.stack.3d.up", group: .apps, keywords: ["activity monitor", "ram", "processes", "ps"], help: "Lists the processes using the most memory right now, with Quit."),
        .init(id: .relaunchApp, title: "Relaunch App", symbol: "arrow.clockwise.circle", group: .apps, keywords: ["restart app", "reopen"], help: "Quits an open app the normal way and opens it again."),
        .init(id: .loginItems, title: "Login Items", symbol: "person.crop.circle.badge.clock", group: .apps, keywords: ["startup", "launch agents", "open at login"], help: "Lists apps that open at login and launch agents (read-only). Background items that apps register themselves appear only in System Settings, which the list links to."),
        .init(id: .resetSavedState, title: "Reset Window State…", symbol: "rectangle.stack.badge.minus", group: .apps, keywords: ["saved application state", "reopen windows", "restore"], help: "Lists apps with saved windows; what you check moves to the Trash, so the app opens without its old windows."),
        // Finder & Dock
        .init(id: .finder, title: "Restart Finder", symbol: "arrow.clockwise", group: .finderDock, keywords: ["relaunch", "finder"], help: "Quits and reopens Finder."),
        .init(id: .extensions, title: "File Extensions", symbol: "doc.text", group: .finderDock, keywords: ["finder", "suffix", "show all"], help: "Shows every file name extension in Finder (AppleShowAllExtensions).", isToggle: true),
        .init(id: .pathbar, title: "Path Bar", symbol: "point.topleft.down.to.point.bottomright.curvepath", group: .finderDock, keywords: ["finder", "breadcrumb"], help: "Shows the path bar at the bottom of Finder windows.", isToggle: true),
        .init(id: .statusbar, title: "Status Bar", symbol: "rectangle.bottomthird.inset.filled", group: .finderDock, keywords: ["finder", "free space", "items"], help: "Shows the status bar (item count, free space) in Finder windows.", isToggle: true),
        .init(id: .posixtitle, title: "Full Path in Title", symbol: "textformat.abc.dottedunderline", group: .finderDock, keywords: ["finder", "posix", "title bar"], help: "Shows the folder's full path in the Finder window title.", isToggle: true),
        .init(id: .dockactive, title: "Open Apps Only", symbol: "dock.arrow.up.rectangle", group: .finderDock, keywords: ["dock", "static only", "running"], help: "Keeps only running apps in the Dock, then restarts the Dock.", isToggle: true),
        .init(id: .dockdelay, title: "Instant Dock", symbol: "hare", group: .finderDock, keywords: ["dock", "autohide delay", "fast"], help: "Removes the delay before a hidden Dock appears, then restarts the Dock.", isToggle: true),
        .init(id: .dockrecents, title: "Dock Recents", symbol: "clock.arrow.circlepath", group: .finderDock, keywords: ["dock", "recents", "suggested"], help: "Shows recent and suggested apps in the Dock, then restarts the Dock.", isToggle: true),
        .init(id: .restartDock, title: "Restart Dock", symbol: "arrow.triangle.2.circlepath", group: .finderDock, keywords: ["relaunch", "dock", "stuck"], help: "Quits the Dock; macOS opens it again at once."),
        .init(id: .showLibrary, title: "Library Folder", symbol: "building.columns", group: .finderDock, keywords: ["~/library", "chflags", "hidden folder"], help: "Shows or hides your Library folder in Finder (chflags nohidden ~/Library).", isToggle: true),
        .init(id: .copyFinderPath, title: "Copy Finder Path", symbol: "doc.on.clipboard", group: .finderDock, keywords: ["path", "selection", "posix"], help: "Copies the full paths of the items selected in Finder, one per line (needs Automation for Finder)."),
        .init(id: .newTextFile, title: "New Text File Here", symbol: "square.and.pencil", group: .finderDock, keywords: ["new file", "untitled", "txt"], help: "Creates an empty text file in the front Finder window's folder and selects it (needs Automation for Finder)."),
        .init(id: .terminalHere, title: "Terminal Here", symbol: "terminal", group: .finderDock, keywords: ["shell", "command line", "open in terminal"], help: "Opens Terminal in the front Finder window's folder (needs Automation for Finder)."),
        // Screenshots
        .init(id: .shotshadow, title: "Window Shadows", symbol: "shadow", group: .screenshots, keywords: ["screenshot", "capture", "disable-shadow"], help: "Keeps or drops the shadow on macOS window screenshots (⇧⌘4, Space).", isToggle: true),
        .init(id: .shotformat, title: "File Format", symbol: "photo", group: .screenshots, keywords: ["screenshot format", "png", "jpg", "heic", "pdf", "capture"], help: "Chooses the file format of macOS screenshots.", isToggle: true),
        .init(id: .shotfolder, title: "Save Folder", symbol: "folder", group: .screenshots, keywords: ["screenshot folder", "location", "capture"], help: "Chooses where macOS saves screenshots.", isToggle: true),
        // Disk & Storage
        .init(id: .ejectAll, title: "Eject All Disks", symbol: "eject", group: .disk, keywords: ["usb", "drive", "disk image", "unmount"], help: "Ejects external drives, disk images and network volumes."),
        .init(id: .ejectDisk, title: "Eject a Disk", symbol: "eject.circle", group: .disk, keywords: ["usb", "unmount", "external", "volume"], help: "Lists external drives, disk images and network volumes with their free space, and ejects the one you pick."),
        .init(id: .verifyDisk, title: "Verify Startup Disk", symbol: "checkmark.shield", group: .disk, keywords: ["diskutil", "first aid", "fsck", "onyx"], help: "Checks the startup volume with diskutil verifyVolume / (read-only; takes a few minutes and the Mac may pause briefly)."),
        .init(id: .backupNow, title: "Back Up Now", symbol: "clock.arrow.2.circlepath", group: .disk, keywords: ["time machine", "tmutil", "backup"], help: "Starts a Time Machine backup (tmutil startbackup); the tile shows when one is running.", isToggle: true),
        .init(id: .backupStatus, title: "Time Machine Status", symbol: "clock.badge.checkmark", group: .disk, keywords: ["time machine", "latest backup", "tmutil"], help: "Shows whether a backup is running, its progress, and the latest backup."),
        .init(id: .snapshots, title: "Local Snapshots", symbol: "camera.on.rectangle", group: .disk, keywords: ["apfs", "tmutil", "purgeable", "space"], help: "Lists the startup disk's APFS local snapshots; Thin asks macOS to remove Time Machine's (administrator)."),
        // Maintenance
        .init(id: .restartMenuBar, title: "Restart Menu Bar", symbol: "menubar.arrow.up.rectangle", group: .maintenance, keywords: ["systemuiserver", "control center", "stuck"], help: "Restarts SystemUIServer and Control Center when menu bar icons are stuck."),
        .init(id: .launchServices, title: "Rebuild Open With", symbol: "list.bullet.rectangle", group: .maintenance, keywords: ["launch services", "lsregister", "duplicates", "default app"], help: "Re-registers apps with Launch Services to fix duplicate or missing Open With entries."),
        .init(id: .spotlight, title: "Reindex Spotlight", symbol: "magnifyingglass", group: .maintenance, keywords: ["mdutil", "search", "index"], help: "Erases and rebuilds the Spotlight index of the startup disk (administrator)."),
        .init(id: .fontCaches, title: "Clear Font Caches", symbol: "textformat", group: .maintenance, keywords: ["atsutil", "fonts", "garbled"], help: "Removes your account's font caches; they rebuild after you log out and in."),
        .init(id: .freeMemory, title: "Purge Disk Cache", symbol: "memorychip", group: .maintenance, keywords: ["purge", "memory", "ram"], help: "Flushes the disk cache from memory with `purge` (administrator)."),
        // Cleanup
        .init(id: .cache, title: "Clear Caches", symbol: "paintbrush", group: .cleanup, keywords: ["library", "caches", "space"], help: "Permanently deletes the contents of ~/Library/Caches (apps rebuild them)."),
        .init(id: .dsstore, title: "Erase .DS_Store", symbol: "trash.slash", group: .cleanup, keywords: ["finder", "metadata"], help: "Deletes .DS_Store files inside a folder you choose."),
        .init(id: .trash, title: "Empty Trash", symbol: "trash.fill", group: .cleanup, keywords: ["delete", "bin"], help: "Asks first, then permanently deletes everything in the Trash."),
        .init(id: .uninstall, title: "Uninstall App…", symbol: "xmark.bin", group: .cleanup, keywords: ["appcleaner", "pearcleaner", "leftovers", "remove"], help: "Lists an app with its leftovers in ~/Library, then moves what you keep checked to the Trash."),
        .init(id: .largeFiles, title: "Large Files…", symbol: "externaldrive.badge.exclamationmark", group: .cleanup, keywords: ["big", "space", "disk"], help: "Finds files over a size you choose in a folder, so you can move some to the Trash."),
        .init(id: .oldDownloads, title: "Old Downloads…", symbol: "arrow.down.circle", group: .cleanup, keywords: ["downloads", "stale", "space"], help: "Lists Downloads items untouched for 30 days to a year, to move to the Trash."),
        .init(id: .devJunk, title: "Xcode Junk…", symbol: "hammer", group: .cleanup, keywords: ["deriveddata", "simulator", "developer"], help: "Lists rebuildable Xcode data (DerivedData, simulator caches, device support); archives are never listed."),
        // Files, PDF & Media
        .init(id: .pdfmerge, title: "Merge PDFs", symbol: "doc.badge.plus", group: .files, keywords: ["combine", "join"], help: "Combines PDFs into one file, ordered by name."),
        .init(id: .pdfcompress, title: "Compress PDF", symbol: "doc.badge.gearshape", group: .files, keywords: ["shrink", "smaller"], help: "Saves a smaller copy of a PDF (pages become images)."),
        .init(id: .imageconvert, title: "Convert Image", symbol: "photo.badge.arrow.down", group: .files, keywords: ["png", "jpeg", "heic", "webp"], help: "Saves a copy of an image as PNG, JPEG, HEIC or WebP."),
        .init(id: .videoconvert, title: "Convert Video", symbol: "film", group: .files, keywords: ["mp4", "h264", "movie"], help: "Saves a copy of a video as MP4."),
        .init(id: .qr, title: "QR Code", symbol: "qrcode", group: .files, keywords: ["barcode", "link"], help: "Makes a QR code PNG from text or a link."),
        .init(id: .rename, title: "Batch Rename", symbol: "character.cursor.ibeam", group: .files, keywords: ["rename", "replace", "number"], help: "Replaces text in many file names at once; {n} inserts a running number."),
        .init(id: .lockFiles, title: "Lock Files", symbol: "lock.doc", group: .files, keywords: ["immutable", "uchg", "protect"], help: "Locks or unlocks files (Finder's Locked flag)."),
        .init(id: .hideFiles, title: "Hide Files", symbol: "eye.slash.circle", group: .files, keywords: ["invisible", "chflags"], help: "Hides or shows files in Finder without renaming them."),
        .init(id: .whoLocks, title: "What's Using a File", symbol: "questionmark.folder", group: .files, keywords: ["lsof", "in use", "can't eject", "locked"], help: "Lists the processes that have a file open, with Quit."),
        .init(id: .fileHash, title: "File SHA-256", symbol: "number", group: .files, keywords: ["checksum", "hash", "verify", "sha"], help: "Copies a file's SHA-256 and checks it against a hash on the clipboard."),
        .init(id: .duplicates, title: "Find Duplicates…", symbol: "square.on.square", group: .files, keywords: ["duplicate", "same file", "gemini", "space"], help: "Finds identical files (same size and SHA-256) in a folder. Copies are checked, the oldest stays unchecked, and only the Trash is used."),
        .init(id: .folderSizes, title: "Folder Sizes…", symbol: "chart.bar.doc.horizontal", group: .files, keywords: ["daisydisk", "disk usage", "biggest", "space"], help: "Adds up what each item in a folder takes on disk, biggest first, with Show in Finder."),
        // Network
        .init(id: .dns, title: "Flush DNS", symbol: "network", group: .network, keywords: ["cache", "mdnsresponder", "resolver"], help: "Clears the DNS cache (asks for an administrator if macOS requires it)."),
        .init(id: .speedTest, title: "Speed Test", symbol: "speedometer", group: .network, keywords: ["networkquality", "bandwidth", "internet"], help: "Measures download, upload and responsiveness with Apple's networkQuality (about 20 s)."),
        .init(id: .portLookup, title: "What's Using a Port", symbol: "point.3.connected.trianglepath.dotted", group: .network, keywords: ["lsof", "listen", "localhost", "port"], help: "Lists the processes using a TCP or UDP port, with Quit."),
        .init(id: .copyIP, title: "Copy IP Address", symbol: "doc.on.doc", group: .network, keywords: ["local ip", "address", "ipv4"], help: "Copies this Mac's local IPv4 address."),
        .init(id: .wifiDetails, title: "Wi-Fi Details", symbol: "wifi.circle", group: .network, keywords: ["rssi", "signal", "channel", "noise", "corewlan"], help: "Shows the Wi-Fi interface, signal (RSSI and noise), channel and rate. macOS shows the network name only with Location permission."),
        .init(id: .publicIP, title: "Public IP", symbol: "globe", group: .network, keywords: ["external ip", "wan", "ipify"], help: "Asks api64.ipify.org over HTTPS for your public address (one request per click) and copies it."),
        .init(id: .ping, title: "Ping", symbol: "waveform.path.ecg", group: .network, keywords: ["latency", "packet loss", "reachability"], help: "Pings a host five times and shows the latency and packet loss."),
        .init(id: .dnsServers, title: "DNS Servers", symbol: "server.rack", group: .network, keywords: ["resolver", "nameserver", "scutil"], help: "Shows the DNS servers macOS is using (scutil --dns) and copies them."),
        .init(id: .renewDHCP, title: "Renew DHCP", symbol: "arrow.triangle.2.circlepath.circle", group: .network, keywords: ["lease", "ip address", "router"], help: "Asks the router for a fresh address on the active interface (ipconfig set … DHCP; asks for an administrator)."),
        .init(id: .listeningPorts, title: "Listening Ports", symbol: "antenna.radiowaves.left.and.right", group: .network, keywords: ["lsof", "server", "open ports", "listen"], help: "Lists the processes you can see listening for TCP connections (lsof), with Quit."),
        .init(id: .airDropSettings, title: "AirDrop Settings", symbol: "dot.radiowaves.left.and.right", group: .network, keywords: ["airdrop", "handoff", "receiving"], help: "Opens System Settings › AirDrop & Handoff."),
        .init(id: .bluetoothSettings, title: "Bluetooth Settings", symbol: "gearshape", group: .network, keywords: ["bluetooth", "pair", "devices"], help: "Opens System Settings › Bluetooth."),
        // System Info
        .init(id: .aboutMac, title: "About This Mac", symbol: "laptopcomputer", group: .info, keywords: ["model", "chip", "memory", "macos version", "build"], help: "Shows the model, chip, memory and macOS version and build, with Copy."),
        .init(id: .copySerial, title: "Copy Serial Number", symbol: "barcode", group: .info, keywords: ["serial", "warranty", "applecare"], help: "Copies this Mac's serial number."),
        .init(id: .bootReasons, title: "Last Restart & Wake", symbol: "power.dotted", group: .info, keywords: ["uptime", "boot", "shutdown reason", "wake reason"], help: "Shows uptime and the codes macOS recorded for the last shutdown and wake (kern.shutdownreason, kern.wakereason). Apple doesn't document every code."),
        .init(id: .settingsPane, title: "Open Settings Pane", symbol: "gearshape.2", group: .info, keywords: ["system settings", "preferences", "pane", "x-apple.systempreferences"], help: "Opens a System Settings pane directly: Battery, Displays, Storage, Login Items and more."),
    ]
    // swiftlint:enable line_length
}
