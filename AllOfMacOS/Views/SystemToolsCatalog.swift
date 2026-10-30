import SwiftUI

/// The System Tools page's groups, in page order.
enum SystemToolGroup: String, CaseIterable, Identifiable {
    case toggles, power, finderDock, screenshots, maintenance, cleanup, files, text, network

    var id: String { rawValue }

    var name: String {
        switch self {
        case .toggles: return "Quick Toggles"
        case .power: return "Power & Session"
        case .finderDock: return "Finder & Dock"
        case .screenshots: return "Screenshots"
        case .maintenance: return "Maintenance"
        case .cleanup: return "Cleanup"
        case .files: return "Files, PDF & Media"
        case .text: return "Text & Developer"
        case .network: return "Network"
        }
    }

    /// The glyph hue for the group's tiles (colour for grouping, as before).
    var tint: Color {
        switch self {
        case .toggles: return .blue
        case .power: return .purple
        case .finderDock: return .cyan
        case .screenshots: return .mint
        case .maintenance: return .indigo
        case .cleanup: return .teal
        case .files: return .orange
        case .text: return .pink
        case .network: return .green
        }
    }
}

/// Every tool on the page. Raw values are stable ids: favorites and the
/// recent list persist them, and the 3.3.4 ids are kept unchanged.
enum SystemToolID: String, CaseIterable, Identifiable {
    // Quick Toggles
    case darkMode, keepAwake, hidden, desktop, dockAutoHide, wifi, muteSound, muteMic, bluetooth, focus, keyboardClean
    // Power & Session
    case lockScreen, sleep, sleepDisplays, screenSaver, restart, shutDown, logOut, quitAll, hideOthers, ejectAll
    // Finder & Dock
    case finder, extensions, pathbar, statusbar, posixtitle, dockactive, dockdelay, dockrecents, restartDock
    // Screenshots
    case shotshadow, shotformat, shotfolder
    // Maintenance
    case restartMenuBar, launchServices, spotlight, fontCaches, freeMemory
    // Cleanup
    case cache, dsstore, trash, uninstall, largeFiles, oldDownloads, devJunk
    // Files, PDF & Media
    case pdfmerge, pdfcompress, imageconvert, videoconvert, qr, rename, lockFiles, hideFiles, whoLocks, fileHash
    // Text & Developer
    case formatJSON, base64, urlCode, changeCase, cleanText, textStats, uuid, timestamp, pickColor, hashText
    // Network
    case dns, speedTest, portLookup, copyIP

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
    /// "lsof", "json" or "trash" find their tools.
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
        .init(id: .ejectAll, title: "Eject All Disks", symbol: "eject", group: .power, keywords: ["usb", "drive", "disk image", "unmount"], help: "Ejects external drives, disk images and network volumes."),
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
        // Screenshots
        .init(id: .shotshadow, title: "Window Shadows", symbol: "shadow", group: .screenshots, keywords: ["screenshot", "capture", "disable-shadow"], help: "Keeps or drops the shadow on macOS window screenshots (⇧⌘4, Space).", isToggle: true),
        .init(id: .shotformat, title: "File Format", symbol: "photo", group: .screenshots, keywords: ["screenshot format", "png", "jpg", "heic", "pdf", "capture"], help: "Chooses the file format of macOS screenshots.", isToggle: true),
        .init(id: .shotfolder, title: "Save Folder", symbol: "folder", group: .screenshots, keywords: ["screenshot folder", "location", "capture"], help: "Chooses where macOS saves screenshots.", isToggle: true),
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
        // Text & Developer (clipboard)
        .init(id: .formatJSON, title: "Format JSON", symbol: "curlybraces", group: .text, keywords: ["pretty", "minify", "clipboard"], help: "Pretty-prints or minifies the JSON on the clipboard (keys sorted)."),
        .init(id: .base64, title: "Base64", symbol: "chevron.left.forwardslash.chevron.right", group: .text, keywords: ["encode", "decode", "clipboard"], help: "Encodes or decodes the clipboard text as Base64."),
        .init(id: .urlCode, title: "URL Encode", symbol: "link", group: .text, keywords: ["percent", "decode", "clipboard"], help: "Percent-encodes or decodes the clipboard text."),
        .init(id: .changeCase, title: "Change Case", symbol: "textformat.size", group: .text, keywords: ["upper", "lower", "title", "camel", "snake", "kebab"], help: "Rewrites the clipboard text in another case or naming style."),
        .init(id: .cleanText, title: "Clean Up Text", symbol: "text.badge.checkmark", group: .text, keywords: ["trim", "plain", "sort", "duplicates", "strip formatting"], help: "Trims, joins, sorts or de-duplicates the clipboard text, or strips its formatting."),
        .init(id: .textStats, title: "Count Words", symbol: "textformat.123", group: .text, keywords: ["characters", "lines", "length"], help: "Counts the characters, words and lines on the clipboard."),
        .init(id: .uuid, title: "New UUID", symbol: "number.square", group: .text, keywords: ["guid", "identifier"], help: "Copies a new random UUID."),
        .init(id: .timestamp, title: "Unix Time", symbol: "clock", group: .text, keywords: ["epoch", "timestamp", "date"], help: "Converts a Unix time on the clipboard to a date, or copies the current Unix time."),
        .init(id: .pickColor, title: "Pick Color", symbol: "eyedropper", group: .text, keywords: ["hex", "color picker", "sampler"], help: "Picks a colour anywhere on screen and copies its hex code."),
        .init(id: .hashText, title: "Hash Text", symbol: "number.circle", group: .text, keywords: ["sha256", "checksum", "clipboard"], help: "Copies the SHA-256 of the clipboard text."),
        // Network
        .init(id: .dns, title: "Flush DNS", symbol: "network", group: .network, keywords: ["cache", "mdnsresponder", "resolver"], help: "Clears the DNS cache (asks for an administrator if macOS requires it)."),
        .init(id: .speedTest, title: "Speed Test", symbol: "speedometer", group: .network, keywords: ["networkquality", "bandwidth", "internet"], help: "Measures download, upload and responsiveness with Apple's networkQuality (about 20 s)."),
        .init(id: .portLookup, title: "What's Using a Port", symbol: "point.3.connected.trianglepath.dotted", group: .network, keywords: ["lsof", "listen", "localhost", "port"], help: "Lists the processes using a TCP or UDP port, with Quit."),
        .init(id: .copyIP, title: "Copy IP Address", symbol: "doc.on.doc", group: .network, keywords: ["local ip", "address", "ipv4"], help: "Copies this Mac's local IPv4 address.")
    ]
    // swiftlint:enable line_length
}
