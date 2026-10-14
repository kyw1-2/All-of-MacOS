import AppKit
import SwiftUI

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

    func unpinAll() {
        for window in Array(pins.values) { window.closePin() }
        pins.removeAll()
    }

    var count: Int { pins.count }
}

@MainActor
private final class PinnedInteractionState: ObservableObject {
    @Published var clickThrough = false
    @Published var opacity = 1.0
}

private final class PinnedWindow: NSPanel {
    var onClose: (() -> Void)?
    private let entry: CaptureHistoryEntry
    private let url: URL?
    private let interaction = PinnedInteractionState()
    private var eventMonitor: Any?
    private var recoveryMonitor: Any?
    private var locked = false

    init(entry: CaptureHistoryEntry, url: URL?) {
        self.entry = entry
        self.url = url
        let scale = min(1, 520 / max(entry.pixelSize.width, entry.pixelSize.height))
        let size = NSSize(width: max(120, entry.pixelSize.width * scale),
                          height: max(80, entry.pixelSize.height * scale))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above ordinary windows, below the screen-saver level the selection
        // overlay uses, so a pin never hides a capture in progress.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = CaptureSettings.pinnedShadow
        // Pinned references should be draggable by their image background.
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 80, height: 60)

        let view = PinnedScreenshotView(
            // Use the full capture so zooming does not enlarge a cached thumbnail.
            image: NSImage(cgImage: entry.image, size: entry.pointSize),
            rounded: CaptureSettings.pinnedRoundedCorners,
            bordered: CaptureSettings.pinnedBorder,
            hasShadow: CaptureSettings.pinnedShadow,
            onCopy: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.save() },
            onAnnotate: { [weak self] in self?.annotate() },
            onClose: { [weak self] in self?.closePin() },
            onLockChange: { [weak self] locked in self?.setLocked(locked) },
            onOpacityChange: { [weak self] opacity in self?.setOpacity(opacity) },
            onClickThrough: { [weak self] in self?.toggleClickThrough() },
            interaction: interaction
        )
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }

    func present() {        // Cascade new pins so a second one does not land exactly on the first.
        let offset = CGFloat(PinnedScreenshotController.shared.count) * 24
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - frame.width / 2 + offset,
                             y: visible.midY - frame.height / 2 - offset)
        setFrameOrigin(origin)
        orderFrontRegardless()
        installInteractionMonitors()
    }

    private func setOpacity(_ value: Double) {
        interaction.opacity = min(1, max(0.1, value))
        alphaValue = CGFloat(interaction.opacity)
    }

    private func toggleClickThrough() {
        interaction.clickThrough.toggle()
        ignoresMouseEvents = interaction.clickThrough
    }

    private func installInteractionMonitors() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            let recover = self.ignoresMouseEvents && self.frame.contains(NSEvent.mouseLocation)
            guard event.window === self || recover else { return event }
            if event.type == .keyDown {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "t" {
                    self.toggleClickThrough()
                    return nil
                }
                if event.window === self, modifiers.intersection([.command, .control, .option]).isEmpty,
                   let text = event.charactersIgnoringModifiers, let digit = Int(text), (0...9).contains(digit) {
                    self.setOpacity(digit == 0 ? 1 : Double(digit) / 10)
                    return nil
                }
            }
            guard !self.ignoresMouseEvents else { return event }
            if event.type == .scrollWheel {
                self.setOpacity(self.interaction.opacity + Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.003 : 0.03))
                return nil
            }
            if event.type == .magnify, !self.locked {
                let old = self.frame
                let requested = max(0.1, 1 + event.magnification)
                let minimum = max(self.minSize.width / old.width, self.minSize.height / old.height)
                let maximum = min(8192 / old.width, 8192 / old.height)
                let factor = min(maximum, max(minimum, requested))
                let size = NSSize(width: old.width * factor, height: old.height * factor)
                self.setFrame(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                                     width: size.width, height: size.height), display: true)
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

    private func setLocked(_ locked: Bool) {
        self.locked = locked
        isMovableByWindowBackground = !locked
        styleMask = locked ? styleMask.subtracting(.resizable) : styleMask.union(.resizable)
    }

    /// Unpins this window. Deliberately not named `close()`: `NSWindow` already
    /// has one, and overriding it would also catch the system's own close paths.
    func closePin() {
        for token in [eventMonitor, recoveryMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(token) }
        eventMonitor = nil
        recoveryMonitor = nil
        orderOut(nil)
        onClose?()
    }

    private func copyImage() {
        let result = CaptureResult(image: entry.image, globalRect: .zero, scale: 1, kind: entry.kind,
                                   windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
        do {
            try ScreenCaptureService.shared.copyToClipboard(result)
            GestureHUD.shared.show(title: "Copied", detail: nil)
        } catch {
            GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
        }
    }

    private func save() {
        let result = CaptureResult(image: entry.image, globalRect: .zero, scale: 1, kind: entry.kind,
                                   windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
        do {
            let written = try ScreenCaptureService.shared.writeToDisk(result)
            NSWorkspace.shared.activateFileViewerSelecting([written])
        } catch {
            GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
        }
    }

    private func annotate() {
        AnnotationEditorController.shared.open(capture: entry, url: url)
        closePin()
    }
}

/// The pinned image itself, with a hover-revealed control strip.
private struct PinnedScreenshotView: View {
    let image: NSImage
    let rounded: Bool
    let bordered: Bool
    let hasShadow: Bool
    let onCopy: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onClose: () -> Void
    let onLockChange: (Bool) -> Void
    let onOpacityChange: (Double) -> Void
    let onClickThrough: () -> Void
    @ObservedObject var interaction: PinnedInteractionState

    @State private var isHovering = false
    @State private var isLocked = false
    @State private var showingOpacity = false

    private func toggleLock() {
        isLocked.toggle()
        onLockChange(isLocked)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(clipShape)
                .overlay {
                    if bordered {
                        clipShape.stroke(Color.primary.opacity(interaction.clickThrough ? 0.10 : 0.25), lineWidth: 1)
                    }
                }
                .shadow(color: hasShadow ? .black.opacity(0.3) : .clear, radius: hasShadow ? 12 : 0, y: hasShadow ? 4 : 0)

            // Keep the control host alive when a popover takes pointer focus.
            if !interaction.clickThrough && (isHovering || showingOpacity) { controls }
        }
        .padding(hasShadow ? 6 : 0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Copy Image", action: onCopy)
            Button("Save As…", action: onSave)
            Divider()
            Button("Annotate", action: onAnnotate)
            Button(isLocked ? "Unlock Position" : "Lock Position", action: toggleLock)
            Button(interaction.clickThrough ? "Disable Click-Through" : "Click-Through", action: onClickThrough)
                .keyboardShortcut("t", modifiers: .command)
            Button("Reset Opacity") { onOpacityChange(1) }
            Button("Unpin", role: .destructive, action: onClose)
        }
        .accessibilityElement()
        .accessibilityLabel("Pinned screenshot")
    }

    private var clipShape: AnyShape {
        rounded ? AnyShape(RoundedRectangle(cornerRadius: 8)) : AnyShape(Rectangle())
    }

    private var controls: some View {
        HStack(spacing: 4) {
            iconButton("doc.on.doc", "Copy", onCopy)
            iconButton("square.and.arrow.down", "Save", onSave)
            iconButton("pencil.tip.crop.circle", "Annotate", onAnnotate)
            iconButton(isLocked ? "lock.fill" : "lock.open", isLocked ? "Unlock Position" : "Lock Position", toggleLock)
            Button { showingOpacity.toggle() } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .help("Opacity")
            .accessibilityLabel("Pinned image opacity")
            .popover(isPresented: $showingOpacity) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Opacity").font(.headline)
                    Slider(value: Binding(get: { interaction.opacity }, set: onOpacityChange), in: 0.1...1)
                    Text("\(Int(interaction.opacity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 210)
            }
            iconButton("cursorarrow.rays", "Click-Through (⌘T; press again over image to restore)", onClickThrough)
            iconButton("xmark", "Unpin", onClose)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(8)
        .transition(.opacity)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
