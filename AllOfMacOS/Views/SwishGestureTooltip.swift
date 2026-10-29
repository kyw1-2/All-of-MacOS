import AppKit

/// Swish's gesture tooltip (3.3.3): a small label beside the pointer naming
/// where the title-bar snap on show puts the window ("← Left Half"), in a
/// borderless, non-activating, click-through panel like the snap preview.
/// It fades in and out over the snap's animation time (Swish
/// "tooltipAnimationTime"); with Reduce Motion or the animation off it
/// appears and goes at once. Settings: `TitleBarWindowSnap.tooltipKey`
/// (on by default) and the preview switch, which hides both.
@MainActor
final class SwishGestureTooltip {
    static let shared = SwishGestureTooltip()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private(set) var text: String?
    /// Bumped by every show, so a fade-out from an earlier gesture cannot
    /// close a tooltip that came back.
    private var generation = 0

    var isShowing: Bool { panel?.isVisible == true && text != nil }

    /// Shows `text` beside `pointer` (AppKit coordinates), or updates it.
    func show(_ text: String, near pointer: NSPoint, speed: SwishSnap.AnimationSpeed) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation &+= 1
        if self.text != text {
            self.text = text
            label.stringValue = text
            label.sizeToFit()
        }
        let size = NSSize(width: ceil(label.frame.width) + 20, height: ceil(label.frame.height) + 10)
        label.frame.origin = NSPoint(x: 10, y: 5)
        panel.setFrame(Self.frame(size: size, pointer: pointer, screen: Self.screen(containing: pointer)), display: true)
        guard !panel.isVisible else { panel.alphaValue = 1; return }
        let duration = Self.duration(speed)
        panel.alphaValue = duration > 0 ? 0 : 1
        panel.orderFrontRegardless()
        guard duration > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        }
    }

    func hide(speed: SwishSnap.AnimationSpeed = .normal) {
        guard let panel, panel.isVisible else { text = nil; return }
        text = nil
        let duration = Self.duration(speed)
        guard duration > 0 else { panel.orderOut(nil); return }
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard SwishGestureTooltip.shared.generation == token else { return }
                panel.orderOut(nil)
            }
        })
    }

    /// Pure: below and to the right of the pointer, kept on its screen.
    nonisolated static func frame(size: NSSize, pointer: NSPoint, screen: NSRect?) -> NSRect {
        var origin = NSPoint(x: pointer.x + 14, y: pointer.y - 22 - size.height)
        if let screen {
            if origin.x + size.width > screen.maxX - 4 { origin.x = pointer.x - 14 - size.width }
            if origin.y < screen.minY + 4 { origin.y = pointer.y + 22 }
            origin.x = min(max(origin.x, screen.minX + 4), max(screen.minX + 4, screen.maxX - size.width - 4))
            origin.y = min(max(origin.y, screen.minY + 4), max(screen.minY + 4, screen.maxY - size.height - 4))
        }
        return NSRect(origin: origin, size: size)
    }

    private static func duration(_ speed: SwishSnap.AnimationSpeed) -> Double {
        SwishSnap.animationDuration(0.12, speed: speed,
                                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                    movesFrame: false)
    }

    private static func screen(containing point: NSPoint) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.setAccessibilityLabel("Gesture")
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
