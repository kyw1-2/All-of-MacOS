import Foundation
import CoreGraphics
import AppKit

/// Protocol defining visual feedback presentation during Swish window gestures.
/// Mirrors Swish's BezelWindow (target highlight) and TilingPopover / Snap Preview overlays.
protocol SwishFeedbackPresenting: AnyObject {
    /// Highlights the active window boundary undergoing gesture manipulation.
    func showTargetBezel(frame: CGRect)
    func hideTargetBezel()

    /// Shows a ghost/preview card where the window will snap if the gesture is committed.
    func showSnapPreview(targetFrame: CGRect)
    func hideSnapPreview()
    
    /// Triggers tactile haptic feedback when a snap threshold is crossed.
    func playSnapHaptic()
}

/// Default implementation routing into AOM's native Liquid Glass visual system.
import SwiftUI

/// The on-screen furniture for the Swish gestures: an accent bezel outlining
/// the target window and the translucent "expected shape" snap preview.
final class LiveSwishFeedbackPresenter: SwishFeedbackPresenting {
    static let shared = LiveSwishFeedbackPresenter()

    private var bezel: NSPanel?
    private var snapPreview: NSPanel?

    init() {}

    private func flipped(_ frame: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    private func makePanel(content: some View, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    func showTargetBezel(frame: CGRect) {
        let target = flipped(frame).insetBy(dx: -3, dy: -3)
        if let bezel {
            bezel.setFrame(target, display: true)
            return
        }
        let panel = makePanel(content: SwishBezelShape(), level: .floating + 1)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        bezel = panel
    }

    func hideTargetBezel() {
        bezel?.orderOut(nil)
        bezel = nil
    }

    func showSnapPreview(targetFrame: CGRect) {
        let target = flipped(targetFrame)
        if let snapPreview {
            snapPreview.setFrame(target, display: true)
            if !snapPreview.isVisible { snapPreview.orderFrontRegardless() }
            return
        }
        let panel = makePanel(content: SwishPreviewShape(), level: .floating + 2)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        snapPreview = panel
    }

    func hideSnapPreview() {
        snapPreview?.orderOut(nil)
        snapPreview = nil
    }

    func playSnapHaptic() {
        if SwishConfiguration.shared.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .default
            )
        }
    }
}

struct SwishBezelShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Swish's expected-shape preview: a soft accent fill with a bright edge.
struct SwishPreviewShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2))
    }
}
