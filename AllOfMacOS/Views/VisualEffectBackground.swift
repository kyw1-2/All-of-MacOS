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
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
    }
}

/// Clears the hosting window so a behind-window blur has something to show.
///
/// A window is opaque by default, and an opaque window is exactly what makes a
/// `.behindWindow` material render as flat grey. This walks up to the window and
/// turns that off, which has to happen after the window exists, hence the async
/// hop.
struct TranslucentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // The title bar keeps its own material, matching System Settings.
            window.titlebarAppearsTransparent = true
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

extension View {
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
