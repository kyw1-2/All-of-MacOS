import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps a capture floating on top of everything else, the way CleanShot's pin
/// does.
///
/// The window is resizable and stays above normal windows but below the level a
/// screen saver uses, so a pin never covers the menu bar or a system alert.
@MainActor
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()
    private init() {}

    private var pins: [UUID: PinnedWindow] = [:]

    /// Floats `entry` on screen. Repeated calls pin additional captures rather
    /// than replacing the previous one, which is what the feature is for —
    /// holding several references side by side.
    func pin(entry: CaptureHistoryEntry, url: URL?) {
        let id = UUID()
        let window = PinnedWindow(entry: entry, url: url)
        window.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
        pins[id] = window
        window.present()
    }

    /// CleanShot "Pin to the Screen…": choose image files to pin.
    func chooseAndPin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP, .gif, .bmp]
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                for url in panel.urls {
                    guard let entry = AnnotationEditorController.entry(fromImageAt: url) else {
                        GestureHUD.shared.show(title: "Could Not Pin", detail: url.lastPathComponent)
                        continue
                    }
                    self?.pin(entry: entry, url: url)
                }
            }
        }
    }

    func unpinAll() {
        for window in Array(pins.values) { window.closePin() }
        pins.removeAll()
    }

    var count: Int { pins.count }
}

/// Pure pin geometry, kept AppKit-free for tests.
enum PinnedGeometry {
    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 8

    /// Initial on-screen size: the capture's *point* size (100 %), shrunk to
    /// fit 70 % of the visible screen.
    static func initialSize(pointSize: CGSize, visible: CGSize) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else { return CGSize(width: 120, height: 80) }
        let fit = min(1, (visible.width * 0.7) / pointSize.width, (visible.height * 0.7) / pointSize.height)
        return CGSize(width: max(40, pointSize.width * fit), height: max(30, pointSize.height * fit))
    }

    static func zoom(contentWidth: CGFloat, pointWidth: CGFloat) -> CGFloat {
        guard pointWidth > 0 else { return 1 }
        return contentWidth / pointWidth
    }

    /// Scroll-wheel / pinch step → new zoom, clamped.
    static func zoom(_ current: CGFloat, scrollDelta: CGFloat, precise: Bool) -> CGFloat {
        let factor = 1 + scrollDelta * (precise ? 0.01 : 0.08)
        return min(maximumZoom, max(minimumZoom, current * max(0.5, factor)))
    }

    static let zoomPresets: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2]
    static let opacityPresets: [Double] = [1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
}

@MainActor
private final class PinnedInteractionState: ObservableObject {
    /// CleanShot "lock": the pin ignores the mouse and fades while hovered.
    @Published var clickThrough = false
    @Published var opacity = 1.0
    @Published var zoom: CGFloat = 1
    @Published var zoomBadgeVisible = false
    @Published var hasShadow = CaptureSettings.pinnedShadow
    @Published var rounded = CaptureSettings.pinnedRoundedCorners
    @Published var bordered = CaptureSettings.pinnedBorder
    @Published var positionLocked = false
}

private final class PinnedWindow: NSPanel {
    var onClose: (() -> Void)?
    private let entry: CaptureHistoryEntry
    private let url: URL?
    private let interaction = PinnedInteractionState()
    private var eventMonitor: Any?
    private var recoveryMonitor: Any?
    private var hoverFadeTimer: Timer?
    private var badgeHideWork: DispatchWorkItem?
    private static let padding: CGFloat = 6

    init(entry: CaptureHistoryEntry, url: URL?) {
        self.entry = entry
        self.url = url
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let content = PinnedGeometry.initialSize(pointSize: entry.pointSize, visible: visible)
        let size = NSSize(width: content.width + Self.padding * 2, height: content.height + Self.padding * 2)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above ordinary windows, below the screen-saver level the selection
        // overlay uses, so a pin never hides a capture in progress.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // drawn by SwiftUI so the Shadow toggle is per pin
        // Pinned references should be draggable by their image background.
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 60, height: 44)
        contentAspectRatio = size
        setAccessibilityLabel("Pinned screenshot")
        interaction.zoom = PinnedGeometry.zoom(contentWidth: content.width, pointWidth: entry.pointSize.width)

        let view = PinnedScreenshotView(
            // Use the full capture so zooming does not enlarge a cached thumbnail.
            image: NSImage(cgImage: entry.image, size: entry.pointSize),
            padding: Self.padding,
            onClose: { [weak self] in self?.closePin() },
            onLock: { [weak self] in self?.toggleClickThrough() },
            interaction: interaction
        )
        let hosting = PinnedHostingView(rootView: view)
        hosting.menuProvider = { [weak self] in self?.buildMenu() }
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    func present() {
        // Cascade new pins so a second one does not land exactly on the first.
        let offset = CGFloat(PinnedScreenshotController.shared.count) * 24
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - frame.width / 2 + offset,
                             y: visible.midY - frame.height / 2 - offset)
        setFrameOrigin(origin)
        orderFrontRegardless()
        installInteractionMonitors()
    }

    // MARK: - Menu (CleanShot order: Close, Close All, Copy, Save As…, Annotate,
    // Opacity ▸, Shadow, Rounded Corners, Border; AOM extras after a separator)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Pinned Screenshot")
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String?, key: String = "", mods: NSEvent.ModifierFlags = [],
                 state: Bool? = nil, _ handler: @escaping () -> Void) {
            let item = QuickAccessMenuAction.item(title, symbol: symbol, keyEquivalent: key, modifiers: mods, handler)
            if let state { item.state = state ? .on : .off }
            menu.addItem(item)
        }
        add("Close", "xmark", key: "w", mods: .command) { [weak self] in self?.closePin() }
        add("Close All", "xmark.rectangle") { PinnedScreenshotController.shared.unpinAll() }
        menu.addItem(.separator())
        add("Copy", "doc.on.doc", key: "c", mods: .command) { [weak self] in self?.copyImage() }
        add("Save As…", "square.and.arrow.down", key: "s", mods: .command) { [weak self] in self?.saveAs() }
        add("Annotate", "pencil.tip.crop.circle", key: "e", mods: .command) { [weak self] in self?.annotate() }
        add("Extract Text", "text.viewfinder") { [weak self] in self?.extractText() }
        menu.addItem(.separator())

        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacity.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let opacityMenu = NSMenu(title: "Opacity")
        for value in PinnedGeometry.opacityPresets {
            let item = QuickAccessMenuAction.item("\(Int((value * 100).rounded()))%", symbol: nil) { [weak self] in
                self?.setOpacity(value)
            }
            item.state = abs(interaction.opacity - value) < 0.05 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)

        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoom.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        let zoomMenu = NSMenu(title: "Zoom")
        for value in PinnedGeometry.zoomPresets {
            let item = QuickAccessMenuAction.item(value == 1 ? "Actual Size (100%)" : "\(Int(value * 100))%",
                                                  symbol: nil) { [weak self] in
                self?.setZoom(value, animated: true)
            }
            item.state = abs(interaction.zoom - value) < 0.01 ? .on : .off
            zoomMenu.addItem(item)
        }
        zoom.submenu = zoomMenu
        menu.addItem(zoom)

        add("Shadow", nil, state: interaction.hasShadow) { [weak self] in self?.interaction.hasShadow.toggle() }
        add("Rounded Corners", nil, state: interaction.rounded) { [weak self] in self?.interaction.rounded.toggle() }
        add("Border", nil, state: interaction.bordered) { [weak self] in self?.interaction.bordered.toggle() }
        menu.addItem(.separator())
        add("Lock and Hide on Mouse Over", "lock", key: "t", mods: .command,
            state: interaction.clickThrough) { [weak self] in self?.toggleClickThrough() }
        add("Lock Position", "pin", state: interaction.positionLocked) { [weak self] in
            guard let self else { return }
            self.setPositionLocked(!self.interaction.positionLocked)
        }
        return menu
    }

    // MARK: - State

    private func setOpacity(_ value: Double) {
        interaction.opacity = min(1, max(0.1, value))
        if !interaction.clickThrough { alphaValue = CGFloat(interaction.opacity) }
    }

    private func toggleClickThrough() {
        interaction.clickThrough.toggle()
        ignoresMouseEvents = interaction.clickThrough
        hoverFadeTimer?.invalidate()
        hoverFadeTimer = nil
        if interaction.clickThrough {
            // Locked pins fade while the pointer is over them so the content
            // underneath stays readable (CleanShot behaviour).
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHoverFade() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverFadeTimer = timer
            GestureHUD.shared.show(title: "Pin Locked", detail: "Hover the pin and press ⌘T to unlock")
        } else {
            alphaValue = CGFloat(interaction.opacity)
        }
    }

    private func updateHoverFade() {
        guard interaction.clickThrough else { return }
        let inside = frame.contains(NSEvent.mouseLocation)
        let target = inside ? min(0.15, CGFloat(interaction.opacity)) : CGFloat(interaction.opacity)
        if abs(alphaValue - target) > 0.01 {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                alphaValue = target
            } else {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = target }
            }
        }
    }

    private func setPositionLocked(_ locked: Bool) {
        interaction.positionLocked = locked
        isMovableByWindowBackground = !locked
        styleMask = locked ? styleMask.subtracting(.resizable) : styleMask.union(.resizable)
    }

    private func setZoom(_ zoom: CGFloat, animated: Bool = false) {
        guard !interaction.positionLocked else { return }
        let clamped = min(PinnedGeometry.maximumZoom, max(PinnedGeometry.minimumZoom, zoom))
        let content = NSSize(width: entry.pointSize.width * clamped, height: entry.pointSize.height * clamped)
        let size = NSSize(width: max(minSize.width, content.width + Self.padding * 2),
                          height: max(minSize.height, content.height + Self.padding * 2))
        let old = frame
        let target = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                            width: size.width, height: size.height)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().setFrame(target, display: true) }
        } else {
            setFrame(target, display: true)
        }
        interaction.zoom = clamped
        flashZoomBadge()
    }

    private func flashZoomBadge() {
        interaction.zoomBadgeVisible = true
        badgeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.interaction.zoomBadgeVisible = false }
        badgeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // Manual window resizing updates the zoom readout too.
        let width = frameRect.width - Self.padding * 2
        interaction.zoom = PinnedGeometry.zoom(contentWidth: width, pointWidth: entry.pointSize.width)
    }

    // MARK: - Input

    private func installInteractionMonitors() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            let recover = self.ignoresMouseEvents && self.frame.contains(NSEvent.mouseLocation)
            guard event.window === self || recover else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            guard !self.ignoresMouseEvents else { return event }
            if event.type == .scrollWheel {
                // ⌥-scroll keeps the AOM opacity gesture; plain scroll zooms (CleanShot).
                if event.modifierFlags.contains(.option) {
                    self.setOpacity(self.interaction.opacity + Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.003 : 0.03))
                } else {
                    self.setZoom(PinnedGeometry.zoom(self.interaction.zoom, scrollDelta: event.scrollingDeltaY,
                                                     precise: event.hasPreciseScrollingDeltas))
                }
                return nil
            }
            if event.type == .magnify {
                self.setZoom(self.interaction.zoom * max(0.5, 1 + event.magnification))
                return nil
            }
            return event
        }
        // A click-through window cannot receive a mouse click to restore itself.
        // Command-T over its bounds remains available while another app is active.
        recoveryMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.ignoresMouseEvents,
                      self.frame.contains(NSEvent.mouseLocation),
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers?.lowercased() == "t" else { return }
                self.toggleClickThrough()
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command {
            switch key {
            case "t": toggleClickThrough(); return true
            case "w": closePin(); return true
            case "c": copyImage(); return true
            case "s": saveAs(); return true
            case "e": annotate(); return true
            case "0": setZoom(1, animated: true); return true
            case "=", "+": setZoom(interaction.zoom * 1.25, animated: true); return true
            case "-": setZoom(interaction.zoom / 1.25, animated: true); return true
            default: return false
            }
        }
        guard event.window === self else { return false }
        // Arrow keys move the pin precisely (Shift = 10 pt).
        if !interaction.positionLocked, modifiers.subtracting(.shift).isEmpty {
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            var origin = frame.origin
            switch event.keyCode {
            case 123: origin.x -= step
            case 124: origin.x += step
            case 125: origin.y -= step
            case 126: origin.y += step
            default: break
            }
            if origin != frame.origin { setFrameOrigin(origin); return true }
        }
        if event.keyCode == 53 { closePin(); return true }
        if modifiers.isEmpty, let digit = Int(key), (0...9).contains(digit) {
            setOpacity(digit == 0 ? 1 : Double(digit) / 10)
            return true
        }
        return false
    }

    /// Unpins this window. Deliberately not named `close()`: `NSWindow` already
    /// has one, and overriding it would also catch the system's own close paths.
    func closePin() {
        for token in [eventMonitor, recoveryMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(token) }
        eventMonitor = nil
        recoveryMonitor = nil
        hoverFadeTimer?.invalidate()
        hoverFadeTimer = nil
        badgeHideWork?.cancel()
        orderOut(nil)
        onClose?()
        onClose = nil
    }

    // MARK: - Actions

    private var result: CaptureResult {
        CaptureResult(image: entry.image, globalRect: CGRect(origin: .zero, size: entry.pointSize),
                      scale: entry.scale, kind: entry.kind,
                      windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    private func copyImage() {
        // F-04B: encode off the main thread, then report the outcome once.
        let capture = result
        Task { @MainActor in
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(capture)
                GestureHUD.shared.show(title: "Copied", detail: nil)
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
            }
        }
    }

    private func saveAs() {
        let format = CaptureSettings.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent
            ?? CaptureNaming.defaultName(for: result)) + "." + format.fileExtension
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // F-04D: snapshot the pixels before the await, then encode and
                // atomically write to the panel's URL off the main actor.
                let capture = self.result
                do {
                    try await ScreenCaptureService.shared.writeToURLAsync(capture, to: destination, format: format)
                    GestureHUD.shared.show(title: "Saved As", detail: destination.lastPathComponent)
                } catch {
                    GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                }
            }
        }
    }

    private func extractText() {
        let image = entry.image
        Task { @MainActor in
            do {
                let text = try await TextRecognitionService.recognize(
                    image, keepsLineBreaks: CaptureSettings.ocrKeepsLineBreaks)
                guard !text.isEmpty else {
                    GestureHUD.shared.show(title: "No Text Found", detail: nil)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                GestureHUD.shared.show(title: "Text Copied", detail: "\(text.count) characters")
            } catch {
                GestureHUD.shared.show(title: "Text Recognition Failed", detail: error.localizedDescription)
            }
        }
    }

    private func annotate() {
        AnnotationEditorController.shared.open(capture: entry, url: url)
        closePin()
    }
}

private final class PinnedHostingView: NSHostingView<PinnedScreenshotView> {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
}

/// The pinned image itself. Hovering reveals close (top-left) and lock
/// (top-right); zooming shows a transient percentage badge.
private struct PinnedScreenshotView: View {
    let image: NSImage
    let padding: CGFloat
    let onClose: () -> Void
    let onLock: () -> Void
    @ObservedObject var interaction: PinnedInteractionState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(clipShape)
                .overlay {
                    if interaction.bordered {
                        clipShape.stroke(Color.primary.opacity(0.28), lineWidth: 1)
                    }
                }
                .shadow(color: interaction.hasShadow ? .black.opacity(0.32) : .clear,
                        radius: interaction.hasShadow ? 5 : 0, y: interaction.hasShadow ? 2 : 0)

            if !interaction.clickThrough && isHovering { controls.transition(.opacity) }

            if interaction.zoomBadgeVisible {
                Text("\(Int((interaction.zoom * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Zoom \(Int((interaction.zoom * 100).rounded())) percent")
            }
        }
        .padding(padding)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: interaction.zoomBadgeVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned screenshot")
    }

    private var clipShape: AnyShape {
        interaction.rounded ? AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous)) : AnyShape(Rectangle())
    }

    private var controls: some View {
        VStack {
            HStack {
                iconButton("xmark", label: "Close", help: "Close (⌘W)", onClose)
                Spacer()
                iconButton("lock.open", label: "Lock",
                           help: "Lock and hide screenshot on mouse over (⌘T to unlock)", onLock)
            }
            Spacer()
        }
        .padding(6)
    }

    private func iconButton(_ symbol: String, label: String, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}
