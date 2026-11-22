import AppKit
import ApplicationServices
import Combine
import CryptoKit
import ScreenCaptureKit

// 7.9: Bartender's Layout page for AOM (Oracle: Bartender 7.1 GoldenGate
// INTEGRATION/ARCHITECTURE notes, Ice 0.11.12 LayoutBar* and
// MenuBarItemImageCache). The real menu bar is "pulled down" into three
// lanes — Shown, Hidden, Always Hidden — drawn with each item's own picture
// captured from the screen. Dragging an icon to another lane moves the real
// item: AOM shows everything, reads fresh AX geometry, then performs the
// Command-drag a person would (Bartender 7's macOS 27 mouse mover does the
// same), checks where macOS put it, and hides again. Nothing private is used:
// Accessibility for the inventory and the drag, Screen Recording for the
// pictures (without it the lanes show symbols and app icons).

enum MenuBarSection: String, CaseIterable, Identifiable, Codable {
    case shown, hidden, alwaysHidden
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        }
    }

    var caption: String {
        switch self {
        case .shown: return "Always in the menu bar"
        case .hidden: return "Shown when you click ❮ or open the Bar"
        case .alwaysHidden: return "Only with ⌥-click or Show All"
        }
    }

    var symbol: String {
        switch self {
        case .shown: return "eye"
        case .hidden: return "eye.slash"
        case .alwaysHidden: return "lock"
        }
    }
}

struct MenuBarLayoutItem: Identifiable, Equatable {
    let item: AOMMenuShelfItem
    var section: MenuBarSection
    /// Why it can't be dragged (macOS pins it, or it is AOM's own control).
    var lockedReason: String?

    var id: String { item.id }
    /// The key its picture is cached under (moves don't change it).
    var imageKey: String { item.stableKey ?? item.pinKey }
}

/// Pure rules, for tests.
enum MenuBarLayoutPolicy {
    /// Which lane an item is in, from where it sits against AOM's dividers.
    /// Without the Hider everything is Shown; without a position, Hidden.
    /// Edges, not centres: a collapsed divider is 10,000 pt wide, its
    /// right edge still at the boundary.
    static func section(of frame: CGRect?, divider: CGRect?, always: CGRect?) -> MenuBarSection {
        guard let divider else { return .shown }
        guard let frame, frame.width > 0 else { return .hidden }
        if frame.midX >= divider.maxX { return .shown }
        if let always, frame.midX <= always.minX { return .alwaysHidden }
        return .hidden
    }

    /// AOM's own chevron and dividers: they are the lanes' edges, not items.
    static func isHiderControl(_ item: AOMMenuShelfItem, ownPID: pid_t) -> Bool {
        guard item.pid == ownPID else { return false }
        let text = (item.title + " " + item.axDescription).lowercased()
        return text.contains("divider") || text.contains("hidden menu bar items") || text.contains("hide menu bar items")
    }

    /// Items macOS keeps at the right end; they can't change lanes.
    static func lockedReason(_ item: AOMMenuShelfItem, ownPID: pid_t, native: Bool = false) -> String? {
        if isHiderControl(item, ownPID: ownPID) { return "AOM's own control" }
        if native {
            // macOS 27 hides by app and always keeps its own items.
            if MenuBarSectionStore.systemOwners.contains(item.ownerBundleID) { return "macOS keeps its own items visible" }
            if item.pid == ownPID { return "All of MacOS stays visible (its ❮ is the switch)" }
        }
        switch item.identity?.name {
        case "Clock", "Control Center": return "macOS keeps it at the right end"
        default: return nil
        }
    }

    /// Lanes read left to right, as in the menu bar.
    static func lanes(_ items: [MenuBarLayoutItem]) -> [MenuBarSection: [MenuBarLayoutItem]] {
        var out: [MenuBarSection: [MenuBarLayoutItem]] = [:]
        for section in MenuBarSection.allCases {
            out[section] = items.filter { $0.section == section }
                .sorted { ($0.item.frame?.minX ?? -.greatestFiniteMagnitude) < ($1.item.frame?.minX ?? -.greatestFiniteMagnitude) }
        }
        return out
    }

    /// Where to let go of the Command-drag (AX coordinates). Before a
    /// neighbour: over its left quarter, so macOS puts the item left of it.
    /// At a lane's end: just past the divider that bounds the lane.
    /// Gemini 7.9: a Shown drop lands right of ❮ (not between the divider and
    /// it), and reordering before a neighbour works without the Hider.
    static func dropPoint(section: MenuBarSection, before neighbor: CGRect?, toggle: CGRect? = nil, divider: CGRect?, always: CGRect?) -> CGPoint? {
        if let neighbor { return CGPoint(x: neighbor.minX + max(2, neighbor.width * 0.25), y: neighbor.midY) }
        guard let divider else { return nil }
        let y = divider.midY
        switch section {
        case .shown: return CGPoint(x: max(divider.maxX, toggle?.maxX ?? divider.maxX) + 4, y: y)
        case .hidden: return CGPoint(x: divider.minX - 3, y: y)
        case .alwaysHidden:
            guard let always else { return nil }
            return CGPoint(x: always.minX - 3, y: y)
        }
    }

    /// Gemini 7.9: an item behind the notch or off every display can't be
    /// dragged or photographed.
    static func isVisible(_ frame: CGRect, displays: [MenuBarStripPolicy.Display]) -> Bool {
        displays.contains { $0.frame.contains(frame) && $0.notch?.intersects(frame) != true }
    }

    /// The colour most of the menu bar shows (its top row), for lanes that
    /// blend with the captured pictures.
    static func median(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else { return nil }
        func luminance(_ c: NSColor) -> CGFloat {
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        }
        return colors.sorted { luminance($0) < luminance($1) }[colors.count / 2]
    }
}

/// The Command-drag a person does to rearrange the menu bar, as events.
enum MenuBarCommandDrag {
    /// Blocks for about half a second; call off the main thread. Returns the
    /// pointer where it was.
    static func perform(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Gemini 7.9: no 250 ms freeze of the real mouse after the warp back.
        source?.localEventsSuppressionInterval = 0
        let original = CGEvent(source: nil)?.location
        let number = Int64.random(in: 10_000...9_999_999)
        func key(_ down: Bool) {
            // ⌘ is a modifier: it travels as flagsChanged, not keyDown.
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down) else { return }
            event.type = .flagsChanged
            event.flags = down ? .maskCommand : []
            event.post(tap: .cghidEventTap)
        }
        func mouse(_ type: CGEventType, _ point: CGPoint, command: Bool = true) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = command ? .maskCommand : []
            if type != .mouseMoved {
                // One press: the same event number and a click count of one.
                event.setIntegerValueField(.mouseEventNumber, value: number)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            event.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(start)
        mouse(.mouseMoved, start, command: false)
        usleep(40_000)
        key(true)
        usleep(40_000)
        mouse(.leftMouseDown, start)
        usleep(90_000)
        let steps = 14
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            usleep(16_000)
        }
        usleep(90_000)
        mouse(.leftMouseUp, end)
        usleep(40_000)
        key(false)
        if let original { CGWarpMouseCursorPosition(original) }
    }
}

/// Pictures of the items, cut from one capture of each display's menu bar.
enum MenuBarItemImager {
    struct Result {
        var images: [String: NSImage] = [:]
        var background: NSColor?
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Pure-ish: pixels close to the picture's border colour (the menu bar
    /// behind the icon) become transparent, with a soft edge.
    static func removeBackground(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 2, height > 2,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var border: [(Int, Int, Int)] = []
        for x in 0..<width { for y in [0, height - 1] { let i = (y * width + x) * 4; border.append((Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))) } }
        for y in 0..<height { for x in [0, width - 1] { let i = (y * width + x) * 4; border.append((Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))) } }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let bg = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))
        for index in 0..<(width * height) {
            let i = index * 4
            let d = abs(Int(pixels[i]) - bg.0) + abs(Int(pixels[i + 1]) - bg.1) + abs(Int(pixels[i + 2]) - bg.2)
            // Within 24 of the bar: gone; past 72: kept; between: a ramp.
            let keep = d <= 24 ? 0.0 : d >= 72 ? 1.0 : Double(d - 24) / 48
            if keep < 1 {
                for c in 0..<4 { pixels[i + c] = UInt8(Double(pixels[i + c]) * keep) }
            }
        }
        return context.makeImage()
    }

    /// `frames` in AX coordinates (top-left origin of the main display).
    /// Display scales and notches, read on the main thread (Gemini 7.9: NSScreen
    /// isn't for the capture's background executor).
    struct Displays: Sendable {
        var scales: [CGDirectDisplayID: CGFloat] = [:]
        var notches: [CGDirectDisplayID: CGRect] = [:]
    }

    @MainActor static func displays() -> Displays {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        var out = Displays()
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            out.scales[id] = screen.backingScaleFactor
            if let notch = GestureHUD.notchRect(screen) { out.notches[id] = MenuBarStripPolicy.axRect(notch, primaryHeight: primary) }
        }
        return out
    }

    static func capture(_ frames: [String: CGRect], displays info: Displays) async -> Result {
        guard hasPermission, !frames.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return Result() }
        var result = Result()
        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            let notch = info.notches[display.displayID]
            // Only items wholly on this display and clear of its notch: an item
            // pushed off the next display, or under the notch, would come back
            // as app-menu text or black (Gemini 7.9).
            let mine = frames.filter { _, rect in
                rect.width > 0 && rect.height > 0 && bounds.contains(rect) && notch?.intersects(rect) != true
            }
            guard !mine.isEmpty else { continue }
            let band = CGRect(x: 0, y: 0, width: bounds.width,
                              height: min(bounds.height, max(24, (mine.values.map(\.maxY).max() ?? 24) - bounds.minY + 1)))
            let scale = info.scales[display.displayID] ?? 2
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = band
            configuration.width = Int(band.width * scale)
            configuration.height = Int(band.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            // The scale the image really has (rounding, even widths).
            let sx = CGFloat(image.width) / max(1, band.width), sy = CGFloat(image.height) / max(1, band.height)
            for (key, frame) in mine {
                let local = CGRect(x: (frame.minX - bounds.minX) * sx, y: (frame.minY - bounds.minY) * sy,
                                   width: frame.width * sx, height: frame.height * sy).integral
                guard let crop = image.cropping(to: local) else { continue }
                // 7.10: the bar behind the icon is keyed out, so pictures sit on
                // any background without a box around them.
                let clean = removeBackground(crop) ?? crop
                result.images[key] = NSImage(cgImage: clean, size: NSSize(width: CGFloat(crop.width) / sx, height: CGFloat(crop.height) / sy))
            }
            if result.background == nil {
                // The right side, where the status items sit — not the notch or app menus.
                let bitmap = NSBitmapImageRep(cgImage: image)
                let start = Int(Double(bitmap.pixelsWide) * 0.65)
                let samples = stride(from: start, to: bitmap.pixelsWide, by: max(1, (bitmap.pixelsWide - start) / 24)).compactMap { bitmap.colorAt(x: $0, y: 1) }
                result.background = MenuBarLayoutPolicy.median(samples)
            }
        }
        return result
    }
}

@MainActor
final class MenuBarLayoutModel: ObservableObject {
    static let shared = MenuBarLayoutModel()

    @Published private(set) var items: [MenuBarLayoutItem] = []
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var barColor: NSColor?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var lastRefresh: Date?
    /// True in an isolated preview filled with sample items.
    @Published private(set) var isSample = false
    fileprivate var lastReveal = Date.distantPast

    private let worker = DispatchQueue(label: "com.kyw.aom.menubar-layout", qos: .userInitiated)
    private var generation = 0

    private init() {
        // Pictures from earlier reads, so the bar has real icons from the start
        // (Bartender keeps them on disk too; keys are identities, never places).
        // A new look (dark/light, wallpaper) gets new pictures at the next read.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarLayoutModel.shared.lastReveal = .distantPast }
        }
        guard let folder = Self.cacheFolder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        // Gemini 7.9: names are hashes (a long key overran the 255-byte limit);
        // index.json maps them back. Read once, a few dozen small files.
        for (file, key) in index {
            if let image = NSImage(contentsOf: folder.appendingPathComponent(file)) { images[key] = image }
        }
    }

    /// Application Support/AllOfMacOS/MenuBarImages (never in previews or tests).
    private static var cacheFolder: URL? {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("AllOfMacOS/MenuBarImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A fixed-length file name for a key (SHA-256, hex).
    nonisolated static func file(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func store(_ pictures: [String: NSImage]) {
        guard let folder = Self.cacheFolder, !pictures.isEmpty else { return }
        // The index lists only the keys still pictured (no endless growth).
        let index = Dictionary(images.keys.map { (Self.file(forKey: $0), $0) }, uniquingKeysWith: { a, _ in a })
        let indexData = try? JSONEncoder().encode(index)
        let encoded: [(URL, Data)] = pictures.compactMap { key, image in
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            // The point size goes into the PNG's resolution, so it loads at its size.
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = image.size
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            return (folder.appendingPathComponent(Self.file(forKey: key)), data)
        }
        DispatchQueue.global(qos: .utility).async {
            for (url, data) in encoded { try? data.write(to: url, options: .atomic) }
            if let indexData { try? indexData.write(to: folder.appendingPathComponent("index.json"), options: .atomic) }
        }
    }

    var lanes: [MenuBarSection: [MenuBarLayoutItem]] { MenuBarLayoutPolicy.lanes(items) }

    // MARK: Reading the menu bar

    /// Shows everything for a moment if the Hider has items hidden, reads
    /// every item's place, takes their pictures and puts the Hider back.
    func refresh(quietly: Bool = false, reveal allowReveal: Bool = true) {
        // Gemini 7.9: one read at a time — a second one used to end the first's
        // reveal while it was still reading, and could cut into a move.
        guard !isSample, !busy else { return }
        guard AXIsProcessTrusted() else {
            items = []
            status = "Allow Accessibility so AOM can read the menu bar."
            return
        }
        generation &+= 1
        let ticket = generation
        busy = true
        if !quietly { status = nil }
        let hider = MenuBarHider.shared
        // Hidden items are read where they are (off screen); they are shown
        // for a moment only to take pictures still missing or 30 minutes old.
        let needsPictures = items.isEmpty || items.contains { $0.section != .shown && images[$0.imageKey] == nil }
            || Date().timeIntervalSince(lastReveal) > 30 * 60
        let reveal = allowReveal && needsPictures && hider.isRunning
            && (hider.native ? MenuBarNativeHiding.shared.isHolding : hider.isCollapsed)
        if reveal { lastReveal = Date() }
        if reveal { hider.revealForInspection() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reveal ? (hider.native ? 0.9 : 0.45) : 0)) { [weak self] in
            self?.scan(ticket: ticket) { [weak self] in
                if reveal { MenuBarHider.shared.endInspection() }
                self?.busy = false
                self?.lastRefresh = Date()
            }
        }
    }

    private func scan(ticket: Int, then done: @escaping @MainActor () -> Void) {
        let apps = AOMMenuShelfPolicy.orderedApps(NSWorkspace.shared.runningApplications)
        let hiderFrames = MenuBarHider.shared.axFrames()
        let own = ProcessInfo.processInfo.processIdentifier
        worker.async { [weak self] in
            let snapshot = AOMMenuShelfProbe.snapshot(apps: apps, deadline: 2.5)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, ticket == self.generation else { done(); return }
                    // AOM's own icons (its menu, weather) are items like any other;
                    // only the Hider's chevron and dividers are left out.
                    let native = MenuBarNativeHiding.isAvailable
                    if native, !UserDefaults.standard.bool(forKey: "AOMMenuBarSections.seeded"),
                       let chevron = hiderFrames.toggle, MenuBarSectionStore.all.isEmpty, !MenuBarNativeHiding.shared.isHolding {
                        // First run on macOS 27: what already sat left of ❮ starts Hidden.
                        let seed = MenuBarSectionStore.seed(items: snapshot.items.filter { $0.pid != own }.compactMap { item in
                            item.frame.map { (item.ownerBundleID, $0.minX) } }, chevronMinX: chevron.minX)
                        for (bundle, section) in seed { MenuBarSectionStore.set(section, for: bundle) }
                        UserDefaults.standard.set(true, forKey: "AOMMenuBarSections.seeded")
                    }
                    let sections = MenuBarSectionStore.all
                    let laid = snapshot.items.filter { !MenuBarLayoutPolicy.isHiderControl($0, ownPID: own) }.map { item -> MenuBarLayoutItem in
                        let locked = MenuBarLayoutPolicy.lockedReason(item, ownPID: own, native: native)
                        let section: MenuBarSection = native
                            ? (locked == nil ? sections[item.ownerBundleID] ?? .shown : .shown)
                            : MenuBarLayoutPolicy.section(of: item.frame, divider: hiderFrames.divider, always: hiderFrames.always)
                        return MenuBarLayoutItem(item: item, section: section, lockedReason: locked)
                    }
                    self.items = laid
                    if snapshot.appsLeft > 0 { self.status = "\(snapshot.appsLeft) app\(snapshot.appsLeft == 1 ? "" : "s") didn't answer in time; Refresh to try again." }
                    var frames: [String: CGRect] = [:]
                    // While anything is hidden only the Shown items are where they look.
                    let collapsed = MenuBarHider.shared.isRunning
                        && (native ? MenuBarNativeHiding.shared.isHolding : MenuBarHider.shared.isCollapsed)
                    for entry in laid where !collapsed || entry.section == .shown {
                        if let frame = entry.item.frame { frames[entry.imageKey] = frame }
                    }
                    let displays = MenuBarItemImager.displays()
                    Task { @MainActor [weak self] in
                        let pictures = await MenuBarItemImager.capture(frames, displays: displays)
                        guard let self, ticket == self.generation else { done(); return }
                        // Pictures stay from earlier reads (an item behind the notch keeps its last one).
                        self.images.merge(pictures.images) { _, new in new }
                        self.store(pictures.images)
                        if let color = pictures.background { self.barColor = color }
                        done()
                    }
                }
            }
        }
    }

    // MARK: Moving

    /// Moves the real item to `section`, before `neighbor` in that lane (or
    /// at the lane's end nearest the divider), then reads the menu bar again
    /// and says whether macOS put it there.
    func move(_ id: String, to section: MenuBarSection, before neighbor: String? = nil) {
        guard !isSample else { sampleMove(id, to: section, before: neighbor); return }
        guard !busy, let entry = items.first(where: { $0.id == id }) else { return }
        if let reason = entry.lockedReason { status = "\(entry.item.displayName) can't move: \(reason)."; return }
        if MenuBarNativeHiding.isAvailable { assign(entry.item.ownerBundleID, to: section, name: entry.item.ownerName); return }
        let hider = MenuBarHider.shared
        guard hider.isRunning || section == .shown else {
            status = "Turn on Hide Icons to give the menu bar hidden sections."
            return
        }
        busy = true
        status = "Moving \(entry.item.displayName)…"
        // The state to come back to is read before the always-hidden divider
        // is added (Gemini 7.9: adding it first left everything shown).
        hider.revealForInspection()
        if section == .alwaysHidden, !hider.hasAlwaysSection {
            hider.setAlwaysSection(true, announce: false)
        }
        let target = entry.item
        let neighborItem = neighbor.flatMap { key in items.first { $0.id == key }?.item }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let frames = hider.axFrames()
            let displays = MenuBarStripPolicy.displays()
            let apps = AOMMenuShelfPolicy.orderedApps(NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier == target.pid || $0.processIdentifier == neighborItem?.pid })
            self.worker.async { [weak self] in
                // Fresh geometry for both, found again by their identity.
                let snapshot = AOMMenuShelfProbe.snapshot(apps: apps, deadline: 1.5)
                func fresh(_ item: AOMMenuShelfItem?) -> CGRect? {
                    guard let item else { return nil }
                    let live = snapshot.items.filter { $0.pid == item.pid }
                    if let key = item.stableKey { return live.first { $0.stableKey == key }?.frame }
                    return live.first { $0.ordinal == item.ordinal && $0.siblings == item.siblings }?.frame
                }
                let from = fresh(target)
                let to = MenuBarLayoutPolicy.dropPoint(section: section, before: fresh(neighborItem), toggle: frames.toggle,
                                                       divider: frames.divider, always: frames.always)
                var moved = false
                if let from, let to, from.width > 0, MenuBarLayoutPolicy.isVisible(from, displays: displays) {
                    MenuBarCommandDrag.perform(from: CGPoint(x: from.midX, y: from.midY), to: to)
                    moved = true
                }
                usleep(450_000)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.busy = false
                        if !moved {
                            hider.endInspection()
                            self.status = "\(target.displayName) isn't on screen (behind the notch?). ⌘-drag it yourself, then Refresh."
                            return
                        }
                        self.generation &+= 1
                        let ticket = self.generation
                        self.busy = true
                        self.scan(ticket: ticket) { [weak self] in
                            guard let self else { return }
                            self.busy = false
                            self.lastRefresh = Date()
                            hider.endInspection()
                            let landed = self.items.first { $0.item.stableKey != nil && $0.item.stableKey == target.stableKey }
                                ?? self.items.first { $0.item.pid == target.pid && $0.item.baseName == target.baseName }
                            if landed?.section == section {
                                self.status = "Moved \(target.displayName) to \(section.title)."
                            } else {
                                self.status = "macOS didn't move \(target.displayName). Hold ⌘ and drag it in the menu bar, then Refresh."
                            }
                        }
                    }
                }
            }
        }
    }

    /// 7.10 (macOS 27): an app's section is a setting, applied at once —
    /// all of its icons move together, nothing is dragged in the menu bar.
    func assign(_ bundle: String, to section: MenuBarSection, name: String) {
        MenuBarSectionStore.set(section, for: bundle)
        for index in items.indices where items[index].item.ownerBundleID == bundle && items[index].lockedReason == nil {
            items[index].section = section
        }
        let hider = MenuBarHider.shared
        if hider.isRunning { hider.reapply() }
        switch section {
        case .shown: status = "\(name) stays in the menu bar."
        case .hidden: status = hider.isRunning ? "\(name) hides; ❮ or the Bar shows it." : "\(name) will hide once Hide icons is on."
        case .alwaysHidden: status = hider.isRunning ? "\(name) shows only with ⌥-click or Show All." : "\(name) will hide once Hide icons is on."
        }
    }

    /// One row per app for the list under the lanes (Bartender's item list).
    var apps: [(bundle: String, name: String, items: [MenuBarLayoutItem])] {
        var order: [String] = []
        var groups: [String: [MenuBarLayoutItem]] = [:]
        for entry in items.sorted(by: { ($0.item.frame?.minX ?? 0) > ($1.item.frame?.minX ?? 0) }) {
            let key = entry.item.ownerBundleID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { key in
            let name = MenuBarSectionStore.systemOwners.contains(key) ? "macOS" : groups[key]?.first?.item.ownerName ?? key
            return (key, name, groups[key] ?? [])
        }
    }

    // MARK: Sample (isolated previews)

    /// `--aom-preview-menubar-sample`: 18 items with long Korean names, as a
    /// full menu bar looks, so the page is checked with real-looking data.
    func loadSample() {
        isSample = true
        let entries: [(String, String, String, String, MenuBarSection, String?)] = [
            ("com.kakao.KakaoTalkMac", "카카오톡", "카카오톡 새 메시지 3개", "message.fill", .shown, nil),
            ("com.microsoft.OneDrive", "OneDrive", "원드라이브 동기화 일시 중지됨", "cloud.fill", .shown, nil),
            ("com.agilebits.onepassword7", "1Password 7", "1Password 7 – 암호 관리자", "key.fill", .shown, nil),
            ("eu.exelban.Stats", "Stats", "CPU 사용량 미니 그래프 23%", "cpu", .shown, nil),
            ("com.raycast.macos", "Raycast", "Raycast", "magnifyingglass.circle.fill", .shown, nil),
            ("com.apple.MenuBarAgent", "MenuBarAgent", "Battery", "battery.75percent", .shown, nil),
            ("com.apple.MenuBarAgent", "MenuBarAgent", "Sound", "speaker.wave.2.fill", .shown, nil),
            ("com.apple.MenuBarAgent", "MenuBarAgent", "Control Center", "switch.2", .shown, "macOS keeps it at the right end"),
            ("com.apple.MenuBarAgent", "MenuBarAgent", "Clock", "clock", .shown, "macOS keeps it at the right end"),
            ("com.docker.docker", "Docker Desktop", "Docker Desktop 엔진 실행 중", "shippingbox.fill", .hidden, nil),
            ("com.getdropbox.dropbox", "Dropbox", "Dropbox 최신 상태", "drop.fill", .hidden, nil),
            ("com.knollsoft.Rectangle", "Rectangle", "Rectangle 창 정리", "rectangle.split.2x1.fill", .hidden, nil),
            ("com.if.Amphetamine", "Amphetamine", "잠자기 방지 남은 시간 1시간 25분", "pills.fill", .hidden, nil),
            ("com.bjango.istatmenus", "iStat Menus", "iStat Menus 배터리 남은 시간", "gauge.with.dots.needle.67percent", .hidden, nil),
            ("kr.co.hancom.input", "한컴 입력기", "한글 입력기 상태 표시", "character.bubble.fill", .hidden, nil),
            ("com.weather.widget", "날씨 위젯", "서울특별시 종로구 맑음 6°", "sun.max.fill", .alwaysHidden, nil),
            ("com.tailscale.ipn.macos", "Tailscale", "Tailscale 연결됨 – 사무실 네트워크", "network", .alwaysHidden, nil),
            ("org.pqrs.Karabiner-Elements", "Karabiner-Elements", "Karabiner 프로필 기본값", "keyboard.fill", .alwaysHidden, nil),
        ]
        var x: CGFloat = 400
        var laid: [MenuBarLayoutItem] = []
        var pictures: [String: NSImage] = [:]
        for (index, entry) in entries.enumerated() {
            let item = AOMMenuShelfItem(pid: pid_t(9000 + index), ownerBundleID: entry.0, ownerName: entry.1, title: entry.2,
                                        axIdentifier: entry.0 == "com.apple.MenuBarAgent" ? "com.apple.menuextra.\(entry.2.lowercased().replacingOccurrences(of: " ", with: ""))" : "",
                                        ordinal: 0, siblings: 1, frame: CGRect(x: x, y: 0, width: 30, height: 24),
                                        axDescription: entry.2)
            x += 32
            let row = MenuBarLayoutItem(item: item, section: entry.4, lockedReason: entry.5)
            laid.append(row)
            pictures[row.imageKey] = Self.sampleImage(entry.3)
        }
        items = laid
        images = pictures
        status = nil
        // A blue wallpaper behind a translucent bar, white icons — as on this Mac.
        barColor = NSColor(srgbRed: 0.16, green: 0.38, blue: 0.68, alpha: 1)
        lastRefresh = Date()
    }

    private func sampleMove(_ id: String, to section: MenuBarSection, before neighbor: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].lockedReason == nil else { return }
        let bundle = items[index].item.ownerBundleID
        for other in items.indices where items[other].item.ownerBundleID == bundle && items[other].lockedReason == nil {
            items[other].section = section
        }
        status = "Moved \(items[index].item.displayName) to \(section.title)."
    }

    /// A menu-bar-sized template picture for sample items.
    static func sampleImage(_ symbol: String) -> NSImage {
        let size = NSSize(width: 30, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else { return false }
            let tinted = NSImage(size: glyph.size, flipped: false) { inner in
                glyph.draw(in: inner)
                NSColor.white.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                                   width: glyph.size.width, height: glyph.size.height))
            return true
        }
    }
}
