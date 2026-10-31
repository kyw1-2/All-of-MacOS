import AppKit
import SwiftUI

/// The microphone HUD (design-3.4.0 b.5, b.12 `AOMHUDContent`): a small
/// non-activating panel near the bottom of the screen with the pointer, the
/// state in words and glyph, gone after about 1.2 s. It never takes focus
/// and ignores the mouse, so it can't get in the way of a call.
@MainActor
final class MicMuteHUDPanel: MicMuteHUDPresenting {
    static let shared = MicMuteHUDPanel()

    private var panel: NSPanel?
    private var generation = UUID()

    func show(muted: Bool, title: String, detail: String?) {
        present(AOMHUDContent(symbol: muted ? "mic.slash.fill" : "mic.fill", title: title, detail: detail,
                              tone: muted ? .warning : .success),
                seconds: 1.2)
    }

    func showFailure(title: String, detail: String) {
        present(AOMHUDContent(symbol: "exclamationmark.triangle.fill", title: title, detail: detail, tone: .danger),
                seconds: 2.6)
    }

    private func present(_ content: AOMHUDContent, seconds: TimeInterval) {
        guard NSApp != nil else { return }
        let host = NSHostingView(rootView: content.aomFloatingSurface(.hud, radius: AOMRadius.hud).fixedSize())
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.14))
        }
        let token = UUID()
        generation = token
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: [content.title, content.detail].compactMap { $0 }.joined(separator: ", "),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, let panel else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0.01 : 0.2
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if self.generation == token { panel.orderOut(nil) }
                    }
                }
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
