import AppKit
import SwiftUI

/// Drags files out of a SwiftUI row as real file URLs, one dragging item per
/// file (a single NSItemProvider loses files when it carries several). The
/// view takes no clicks itself: a local monitor starts the drag after the
/// pointer moves 4 pt from a press inside it, so taps still reach SwiftUI.
/// The drag only offers Copy, so a drop never moves the original.
struct FilesFileDragSource: NSViewRepresentable {
    /// The files to drag, read when the drag starts (the selection may have
    /// changed since the row was drawn).
    let urls: () -> [URL]
    var onStart: (() -> Void)?

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.urls = urls
        view.onStart = onStart
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onStart = onStart
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) { view.removeMonitor() }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onStart: (() -> Void)?
        private var monitor: Any?
        private var start: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                switch event.type {
                case .leftMouseDown:
                    self.start = self.bounds.contains(point) && !self.isHiddenOrHasHiddenAncestor ? point : nil
                    return event
                case .leftMouseUp:
                    self.start = nil
                    return event
                default:
                    guard let start = self.start, hypot(point.x - start.x, point.y - start.y) > 4 else { return event }
                    self.start = nil
                    let files = self.urls().filter { FileManager.default.fileExists(atPath: $0.path) }
                    guard !files.isEmpty else { return event }
                    self.onStart?()
                    let items = files.prefix(64).enumerated().map { index, url -> NSDraggingItem in
                        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        let offset = CGFloat(min(index, 4)) * 4
                        item.setDraggingFrame(NSRect(x: point.x - 20 + offset, y: point.y - 20 - offset, width: 40, height: 40), contents: icon)
                        return item
                    }
                    self.beginDraggingSession(with: Array(items), event: event, source: self)
                    return nil
                }
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
