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
        for (_, window) in pins { window.orderOut(nil) }
        pins.removeAll()
    }

    var count: Int { pins.count }
}

private final class PinnedWindow: NSPanel {
    var onClose: (() -> Void)?
    private let entry: CaptureHistoryEntry
    private let url: URL?

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
            onOpacityChange: { [weak self] opacity in self?.alphaValue = CGFloat(opacity) }
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
    }

    private func setLocked(_ locked: Bool) {
        isMovableByWindowBackground = !locked
        styleMask = locked ? styleMask.subtracting(.resizable) : styleMask.union(.resizable)
    }

    /// Unpins this window. Deliberately not named `close()`: `NSWindow` already
    /// has one, and overriding it would also catch the system's own close paths.
    private func closePin() {
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

    @State private var isHovering = false
    @State private var isLocked = false
    @State private var opacity = 1.0
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
                        clipShape.stroke(Color.primary.opacity(0.25), lineWidth: 1)
                    }
                }
                .shadow(color: hasShadow ? .black.opacity(0.3) : .clear, radius: hasShadow ? 12 : 0, y: hasShadow ? 4 : 0)

            if isHovering { controls }
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
            Button("Reset Opacity") {
                opacity = 1
                onOpacityChange(1)
            }
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
                    Slider(value: $opacity, in: 0.25...1)
                        .onChange(of: opacity) { _, value in onOpacityChange(value) }
                    Text("\(Int(opacity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 210)
            }
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
