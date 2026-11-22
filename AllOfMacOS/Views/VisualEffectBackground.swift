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
    /// 7.8: rounds the blur itself. A behind-window blur is composited by the
    /// window server, so SwiftUI's clip alone can leave its square corners
    /// showing past a rounded panel; a mask image is AppKit's own way.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.maskImage = Self.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
        if view.state != state { view.state = state }
        if view.isEmphasized != isEmphasized { view.isEmphasized = isEmphasized }
        if context.coordinator.radius != cornerRadius {
            context.coordinator.radius = cornerRadius
            view.maskImage = Self.mask(cornerRadius)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(radius: cornerRadius) }

    final class Coordinator {
        var radius: CGFloat
        init(radius: CGFloat) { self.radius = radius }
    }

    /// A stretchable rounded-rect mask (nil: square).
    static func mask(_ radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
