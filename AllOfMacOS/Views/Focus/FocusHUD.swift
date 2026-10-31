import AppKit
import SwiftUI

/// Focus's HUD (design-3.4.0 b.5, #136): `AOMHUDContent` with the Focus hue
/// in a borderless, non-activating panel that ignores the mouse and never
/// takes focus, centred on the display with the pointer, gone after a
/// moment. A newer HUD replaces the one on screen.
@MainActor
final class FocusHUD {
    static let shared = FocusHUD()

    private var panel: NSPanel?
    private var generation = 0

    func show(symbol: String, title: String, detail: String?, seconds: TimeInterval) {
        guard NSApp != nil, !PresetManager.isRunningTests else { return }
        generation += 1
        let token = generation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: FocusHUDView(symbol: symbol, title: title, detail: detail))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.05 : 0.12
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: [title, detail].compactMap { $0 }.joined(separator: ", "),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, seconds)) { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, let panel else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if self.generation == token { panel.orderOut(nil) }
                    }
                }
            }
        }
    }

    func dismiss() {
        generation += 1
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

/// The HUD's content: the Focus-hued glyph, the title and one detail line.
struct FocusHUDView: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol)
                .font(AOMFont.display)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AOMModule.focus.hue)
                .frame(width: AOMIcon.hudGlyph, height: AOMIcon.hudGlyph)
                .accessibilityHidden(true)
            Text(title)
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AOMSpace.x6)
        .padding(.vertical, AOMSpace.x4)
        .frame(minWidth: AOMSize.quickActionMin + AOMSpace.x8, maxWidth: 320)
        .aomFloatingSurface(.hud, radius: AOMRadius.hud)
        .accessibilityElement(children: .combine)
    }
}
