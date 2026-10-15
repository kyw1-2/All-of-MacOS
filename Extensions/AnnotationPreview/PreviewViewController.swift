import Cocoa
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let (document, scale) = try AnnotationProject.read(from: url)
            guard let image = document.render(scale: scale) else { throw CocoaError(.fileReadCorruptFile) }
            loadViewIfNeeded()
            let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
            imageView.image = NSImage(cgImage: image, size: size)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityLabel("Annotated image preview")
            (view as? NSScrollView)?.documentView = imageView
            preferredContentSize = NSSize(width: min(1000, max(400, size.width)), height: min(800, max(300, size.height)))
            handler(nil)
        } catch { handler(error) }
    }
}
