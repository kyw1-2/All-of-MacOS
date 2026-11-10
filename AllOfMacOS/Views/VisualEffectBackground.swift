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
