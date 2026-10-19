import SwiftUI
import AppKit

/// A real behind-window blur, as an NSViewRepresentable.
///
/// SwiftUI's `Material` blurs within the window's own backing store, which is
/// why `.regularMaterial` over a solid `controlBackgroundColor` still looks flat:
/// there is nothing behind it to show. To get the System Settings look the blur
/// has to be an `NSVisualEffectView` in `.behindWindow` mode, so the desktop
/// behind the window is what shows through.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = false
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
        if view.state != state { view.state = state }
        if view.isEmphasized != isEmphasized { view.isEmphasized = isEmphasized }
    }
}

/// Clears the hosting window so a behind-window blur has something to show.
///
/// A window is opaque by default, and an opaque window is exactly what makes a
/// `.behindWindow` material render as flat grey. This walks up to the window and
/// turns that off when its host actually joins a window, including reattachment.
struct TranslucentWindow: NSViewRepresentable {
    private final class WindowProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let window else { return }
            if window.isOpaque { window.isOpaque = false }
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        }
    }
    func makeNSView(context: Context) -> NSView { WindowProbe(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { (view as? WindowProbe)?.configure() }
}

/// macOS 26+ owns the sidebar's Liquid Glass. Older systems get one AppKit
/// material; accessibility settings substitute an opaque surface.
private struct AOMSidebarMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.scrollContentBackground(.hidden).background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26, *) {
            content
        } else {
            content.scrollContentBackground(.hidden).background {
                VisualEffectBackground(material: .sidebar).ignoresSafeArea()
            }
        }
    }
}

extension View {
    func aomSidebarMaterial() -> some View { modifier(AOMSidebarMaterial()) }

    /// Gives a pane the System Settings treatment: a real behind-window blur
    /// with the window itself made non-opaque so the blur is visible.
    func translucentPane(_ material: NSVisualEffectView.Material = .sidebar) -> some View {
        background {
            VisualEffectBackground(material: material)
                .ignoresSafeArea()
        }
        .background(TranslucentWindow().frame(width: 0, height: 0))
    }
}
