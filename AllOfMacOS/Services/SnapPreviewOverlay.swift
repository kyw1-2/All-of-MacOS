import AppKit

// MARK: - Preview overlay

/// The translucent rounded rectangle shown while swiping, in a borderless,
/// non-activating, click-through window at a floating level — the mechanism
/// Swish uses for its snapping preview. Frame changes animate briefly, and not
/// at all under Reduce Motion (the preview then jumps and fades).
@MainActor
final class SnapPreviewOverlay {
    private var panel: NSPanel?
    private let view = SnapPreviewView()
    /// Bumped by every `show()`. Fade completions from an earlier gesture
    /// check it, so a swipe that starts while the last snap is still fading
    /// keeps its own preview.
    private var generation = 0
    /// Whether the current gesture has put a preview on screen.
    private(set) var isShowing = false

    func show(frame: CGRect, restoring: Bool = false) {
        generation += 1
        isShowing = true
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view.setStyle(committed: false, restoring: restoring)
        if panel.frame == .zero || !panel.isVisible {
            panel.setFrame(frame, display: true)
            // Short enough that the preview is there as the swipe engages
            // (3.3.2: 0.12 s and 0.14 s felt sluggish).
            let fade = duration(0.08, movesFrame: false)
            panel.alphaValue = fade > 0 ? 0 : 1
            panel.orderFrontRegardless()
            guard fade > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                panel.animator().alphaValue = 1
            }
            return
        }
        let move = duration(0.1, movesFrame: true)
        guard move > 0 else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = move
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Swish animates its preview to the frame the window really took
    /// (`setFrame:display:animate:` after reading `AXFrame` back), then hides
    /// it; a size-limited window therefore shows where it actually landed.
    func settle(on frame: CGRect) {
        guard let panel, panel.isVisible else { return }
        isShowing = false
        let started = generation
        view.setStyle(committed: true, restoring: false)
        let fadeTime = duration(0.16, movesFrame: false)
        let fade = { [weak self] in
            guard let self, self.generation == started else { return }
            guard fadeTime > 0 else {
                self.view.setStyle(committed: false, restoring: false)
                self.panel?.orderOut(nil)
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeTime
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == started else { return }
                self.view.setStyle(committed: false, restoring: false)
                self.panel?.orderOut(nil)
            })
        }
        let move = duration(0.12, movesFrame: true)
        guard move > 0, !WindowGeometry.close(panel.frame, frame) else {
            panel.setFrame(frame, display: true)
            fade()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = move
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { fade() })
    }

    func hide() {
        isShowing = false
        guard let panel, panel.isVisible else { return }
        let started = generation
        let fade = duration(0.1, movesFrame: false)
        guard fade > 0 else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == started else { return }
            self.panel?.orderOut(nil)
        })
    }

    /// Fades a held preview towards the hold-still cancel: 0 is fully shown,
    /// 1 the faintest it gets before it goes. Moving again restores it.
    func dim(_ amount: CGFloat) {
        guard isShowing, let panel, panel.isVisible else { return }
        let alpha = 1 - 0.7 * min(max(amount, 0), 1)
        guard abs(panel.alphaValue - alpha) > 0.01 else { return }
        let time = AOMDesign.reduceMotion ? 0 : duration(0.2, movesFrame: false)
        guard time > 0 else { panel.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = time
            panel.animator().alphaValue = alpha
        }
    }

    /// Swish's "tooltipAnimationTime" (3.3.2): Fast halves every duration,
    /// Off shows and hides the preview at once; Reduce Motion still keeps the
    /// frame from sliding.
    private func duration(_ base: Double, movesFrame: Bool) -> Double {
        SwishSnap.animationDuration(base, speed: TitleBarWindowSnap.animationSpeed(),
                                    reduceMotion: AOMDesign.reduceMotion, movesFrame: movesFrame)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        panel.contentView = view
        return panel
    }
}

/// A rounded accent rectangle: the fill deepens on commit, and a restore of
/// the pre-snap frame draws a dashed outline so it reads as "put it back"
/// rather than another snap. Increase Contrast and Reduce Transparency get a
/// stronger fill and a solid edge.
private final class SnapPreviewView: NSView {
    private var committed = false
    private var restoring = false
    private let outline = CAShapeLayer()

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = nil
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { nil }

    func setStyle(committed: Bool, restoring: Bool) {
        guard committed != self.committed || restoring != self.restoring else { return }
        self.committed = committed
        self.restoring = restoring
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateOutlinePath()
    }

    private func updateOutlinePath() {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: inset, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    override func updateLayer() {
        guard let layer else { return }
        let workspace = NSWorkspace.shared
        let strong = workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
        let accent = NSColor.controlAccentColor
        let base: CGFloat = restoring ? 0.12 : 0.20
        layer.backgroundColor = accent.withAlphaComponent(committed ? 0.34 : (strong ? base + 0.12 : base)).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        updateOutlinePath()
        outline.strokeColor = accent.withAlphaComponent(strong ? 1 : 0.95).cgColor
        outline.lineWidth = strong ? 3 : 2
        outline.lineDashPattern = restoring ? [7, 5] : nil
    }
}
