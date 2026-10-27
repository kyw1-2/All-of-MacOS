import AppKit
import AVFoundation

/// Geometry for the live camera bubble. Global rects use the top-left origin
/// (ScreenCaptureKit); panel frames use AppKit's bottom-left origin.
enum CameraBubbleGeometry {
    /// The studio camera layer's defaults: centre at 84 % / 84 %, 24 % of the short side.
    static func initialFrame(recording rect: CGRect, primaryTop: CGFloat) -> CGRect {
        let side = min(260, max(96, (min(rect.width, rect.height) * 0.24).rounded()))
        var centre = CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.84)
        centre.x = min(rect.maxX - side / 2, max(rect.minX + side / 2, centre.x))
        centre.y = min(rect.maxY - side / 2, max(rect.minY + side / 2, centre.y))
        return CGRect(x: centre.x - side / 2, y: primaryTop - centre.y - side / 2, width: side, height: side)
    }

    /// Where the bubble ended up, as the camera layer's normalised centre and size.
    static func placement(panel frame: CGRect, recording rect: CGRect, primaryTop: CGFloat) -> (x: Double, y: Double, size: Double)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (frame.midX - rect.minX) / rect.width
        let y = (primaryTop - frame.midY - rect.minY) / rect.height
        let size = frame.width / min(rect.width, rect.height)
        return (Double(min(1, max(0, x))), Double(min(1, max(0, y))), Double(min(0.6, max(0.1, size))))
    }
}

/// CleanShot's webcam bubble: a round, draggable, mirrored camera preview on
/// screen while recording. It is never captured: it exists before
/// ScreenCaptureKit lists AOM's windows for exclusion, and is marked private.
/// The camera itself is still recorded as AOM's separate, editable layer,
/// which starts where the bubble was left.
@MainActor
final class RecordingCameraBubble {
    static let shared = RecordingCameraBubble()
    private var panel: NSPanel?
    private var preview: AVCaptureVideoPreviewLayer?

    var isVisible: Bool { panel != nil }

    func show(recording rect: CGRect) {
        hide()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CameraBubbleGeometry.initialFrame(recording: rect, primaryTop: primaryTop)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = frame.width / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        view.setAccessibilityLabel("Camera preview. Drag to move.")
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func attach(_ session: AVCaptureSession) {
        guard let layer = panel?.contentView?.layer, let bounds = panel?.contentView?.bounds else { return }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        // Mirrored like FaceTime, and like the camera layer in the export.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer.insertSublayer(preview, at: 0)
        self.preview = preview
    }

    func placement(recording rect: CGRect) -> (x: Double, y: Double, size: Double)? {
        guard let frame = panel?.frame else { return nil }
        return CameraBubbleGeometry.placement(panel: frame, recording: rect, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    func hide() {
        preview?.removeFromSuperlayer()
        preview = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
