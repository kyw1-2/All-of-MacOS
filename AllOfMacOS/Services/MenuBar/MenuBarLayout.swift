import AppKit
import ApplicationServices
import Combine
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
    static func lockedReason(_ item: AOMMenuShelfItem, ownPID: pid_t) -> String? {
        if isHiderControl(item, ownPID: ownPID) { return "AOM's own control" }
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
    static func dropPoint(section: MenuBarSection, before neighbor: CGRect?, divider: CGRect, always: CGRect?) -> CGPoint? {
        let y = divider.midY
        if let neighbor { return CGPoint(x: neighbor.minX + max(2, neighbor.width * 0.25), y: neighbor.midY) }
        switch section {
        case .shown: return CGPoint(x: divider.maxX + 3, y: y)
        case .hidden: return CGPoint(x: divider.minX - 3, y: y)
        case .alwaysHidden:
            guard let always else { return nil }
            return CGPoint(x: always.minX - 3, y: y)
        }
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
        let original = CGEvent(source: nil)?.location
        func key(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down)
            event?.flags = down ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
        func mouse(_ type: CGEventType, _ point: CGPoint, command: Bool = true) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = command ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
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

    /// `frames` in AX coordinates (top-left origin of the main display).
    static func capture(_ frames: [String: CGRect]) async -> Result {
        guard hasPermission, !frames.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return Result() }
        var result = Result()
        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            let mine = frames.filter { bounds.intersects($0.value) && $0.value.width > 0 }
            guard !mine.isEmpty else { continue }
            let band = CGRect(x: 0, y: 0, width: bounds.width,
                              height: min(bounds.height, max(24, (mine.values.map(\.maxY).max() ?? 24) - bounds.minY + 1)))
            let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 2
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = band
            configuration.width = Int(band.width * scale)
            configuration.height = Int(band.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            for (key, frame) in mine {
                let local = CGRect(x: (frame.minX - bounds.minX) * scale, y: (frame.minY - bounds.minY) * scale,
                                   width: frame.width * scale, height: frame.height * scale).integral
                guard let crop = image.cropping(to: local) else { continue }
                result.images[key] = NSImage(cgImage: crop, size: frame.size)
            }
            if result.background == nil, let bitmap = Optional(NSBitmapImageRep(cgImage: image)) {
                let samples = stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 40)).compactMap { bitmap.colorAt(x: $0, y: 1) }
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
    private var lastReveal = Date.distantPast

    private let worker = DispatchQueue(label: "com.kyw.aom.menubar-layout", qos: .userInitiated)
    private var generation = 0

    private init() {
        // Pictures from earlier reads, so the bar has real icons from the start
        // (Bartender keeps them on disk too; keys are identities, never places).
        guard let folder = Self.cacheFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" {
            guard let key = Self.key(fromFile: file.deletingPathExtension().lastPathComponent),
                  let image = NSImage(contentsOf: file) else { continue }
            images[key] = image
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

    nonisolated static func file(forKey key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    nonisolated static func key(fromFile name: String) -> String? {
        let base64 = name.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func store(_ pictures: [String: NSImage]) {
        guard let folder = Self.cacheFolder, !pictures.isEmpty else { return }
        let encoded: [(URL, Data)] = pictures.compactMap { key, image in
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            // The point size goes into the PNG's resolution, so it loads at its size.
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = image.size
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            return (folder.appendingPathComponent(Self.file(forKey: key)).appendingPathExtension("png"), data)
        }
        DispatchQueue.global(qos: .utility).async { for (url, data) in encoded { try? data.write(to: url, options: .atomic) } }
    }

    var lanes: [MenuBarSection: [MenuBarLayoutItem]] { MenuBarLayoutPolicy.lanes(items) }

    // MARK: Reading the menu bar

    /// Shows everything for a moment if the Hider has items hidden, reads
    /// every item's place, takes their pictures and puts the Hider back.
    func refresh(quietly: Bool = false, reveal allowReveal: Bool = true) {
        guard !isSample else { return }
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
        let reveal = allowReveal && needsPictures && hider.isRunning && hider.isCollapsed
        if reveal { lastReveal = Date() }
        if reveal { hider.revealForInspection() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reveal ? 0.45 : 0)) { [weak self] in
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
                    let laid = snapshot.items.filter { !MenuBarLayoutPolicy.isHiderControl($0, ownPID: own) }.map { item in
                        MenuBarLayoutItem(item: item,
                                          section: MenuBarLayoutPolicy.section(of: item.frame, divider: hiderFrames.divider, always: hiderFrames.always),
                                          lockedReason: MenuBarLayoutPolicy.lockedReason(item, ownPID: own))
                    }
                    self.items = laid
                    if snapshot.appsLeft > 0 { self.status = "\(snapshot.appsLeft) app\(snapshot.appsLeft == 1 ? "" : "s") didn't answer in time; Refresh to try again." }
                    var frames: [String: CGRect] = [:]
                    for entry in laid { if let frame = entry.item.frame { frames[entry.imageKey] = frame } }
                    Task { @MainActor [weak self] in
                        let pictures = await MenuBarItemImager.capture(frames)
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
        let hider = MenuBarHider.shared
        guard hider.isRunning || section == .shown else {
            status = "Turn on Hide Icons to give the menu bar hidden sections."
            return
        }
        if section == .alwaysHidden, !hider.hasAlwaysSection {
            hider.setAlwaysSection(true, announce: false)
        }
        busy = true
        status = "Moving \(entry.item.displayName)…"
        hider.revealForInspection()
        let target = entry.item
        let neighborItem = neighbor.flatMap { key in items.first { $0.id == key }?.item }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let frames = hider.axFrames()
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
                let to: CGPoint? = frames.divider.flatMap {
                    MenuBarLayoutPolicy.dropPoint(section: section, before: fresh(neighborItem), divider: $0, always: frames.always)
                }
                var moved = false
                if let from, let to, from.width > 0 {
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
                            self.status = "Couldn't find \(target.displayName) on screen. ⌘-drag it yourself, then Refresh."
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
        barColor = NSColor(white: 0.5, alpha: 0.15)
        lastRefresh = Date()
    }

    private func sampleMove(_ id: String, to section: MenuBarSection, before neighbor: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].lockedReason == nil else { return }
        items[index].section = section
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
                NSColor.labelColor.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                                   width: glyph.size.width, height: glyph.size.height))
            return true
        }
    }
}
