import Foundation
import CoreGraphics
import AppKit
import SwiftUI

/// Protocol defining visual feedback presentation during Swish window gestures.
/// Mirrors Swish's BezelWindow (target highlight) and TilingPopover / Snap Preview overlays.
protocol SwishFeedbackPresenting: AnyObject {
    /// Highlights the active window boundary undergoing gesture manipulation.
    func showTargetBezel(frame: CGRect)
    func hideTargetBezel()

    /// Shows a ghost/preview card where the window will snap if the gesture is committed.
    func showSnapPreview(targetFrame: CGRect)
    func showSnapPreview(targetFrame: CGRect, title: String, symbol: String)
    func hideSnapPreview()
    
    /// Triggers tactile haptic feedback when a snap threshold is crossed.
    func playSnapHaptic()
}

extension SwishFeedbackPresenting {
    func showSnapPreview(targetFrame: CGRect, title: String, symbol: String) {
        showSnapPreview(targetFrame: targetFrame)
    }
}

/// The on-screen furniture for the Swish gestures: an accent bezel outlining
/// the target window and the translucent "expected shape" snap preview.
final class LiveSwishFeedbackPresenter: SwishFeedbackPresenting {
    static let shared = LiveSwishFeedbackPresenter()

    private var bezel: NSPanel?
    private var snapPreview: NSPanel?
    private var currentTitle: String = ""
    private var currentSymbol: String = ""

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
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    func showTargetBezel(frame: CGRect) {
        let target = flipped(frame).insetBy(dx: -3, dy: -3)
        if let bezel {
            bezel.setFrame(target, display: true)
            if !bezel.isVisible { bezel.orderFrontRegardless() }
            return
        }
        let panel = makePanel(content: SwishBezelShape(), level: .statusBar + 2)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        bezel = panel
    }

    func hideTargetBezel() {
        bezel?.orderOut(nil)
        bezel = nil
    }

    func showSnapPreview(targetFrame: CGRect) {
        showSnapPreview(targetFrame: targetFrame, title: "Snap", symbol: "macwindow")
    }

    func showSnapPreview(targetFrame: CGRect, title: String, symbol: String) {
        let target = flipped(targetFrame)
        if let snapPreview, currentTitle == title, currentSymbol == symbol {
            snapPreview.setFrame(target, display: true)
            if !snapPreview.isVisible { snapPreview.orderFrontRegardless() }
            return
        }
        snapPreview?.orderOut(nil)
        currentTitle = title
        currentSymbol = symbol
        let panel = makePanel(content: SwishPreviewShape(title: title, symbol: symbol), level: .statusBar + 3)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        snapPreview = panel
    }

    func hideSnapPreview() {
        snapPreview?.orderOut(nil)
        snapPreview = nil
        currentTitle = ""
        currentSymbol = ""
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
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3.5)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 6, x: 0, y: 0)
    }
}

/// Swish's expected-shape preview: Liquid Glass card with crisp badge and icon.
struct SwishPreviewShape: View {
    let title: String
    let symbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)

            // Centered Action Indicator
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
        }
    }
}
