import AppKit
import SwiftUI

/// Native AppKit file drag so the overlay is notified *after* dropping,
/// not when the drag starts. SwiftUI .onDrag alone has no drop result callback.
struct QuickAccessDragSource: NSViewRepresentable {
    var preview: NSImage
    var prepareFile: () -> URL?
    var didFinish: (Bool) -> Void
    var didDoubleClick: () -> Void
    var didSwipe: () -> Void
    var isLeftCorner: Bool

    func makeNSView(context: Context) -> DraggableView {
        let view = DraggableView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DraggableView, context: Context) {
        view.preview = preview
        view.prepareFile = prepareFile
        view.didFinish = didFinish
        view.didDoubleClick = didDoubleClick
        view.didSwipe = didSwipe
        view.isLeftCorner = isLeftCorner
    }

    final class DraggableView: NSView, NSDraggingSource {
        var preview: NSImage?
        var prepareFile: (() -> URL?)?
        var didFinish: ((Bool) -> Void)?
        var didDoubleClick: (() -> Void)?
        var didSwipe: (() -> Void)?
        var isLeftCorner = false
        private var started = false
        private var horizontalScroll: CGFloat = 0

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            started = false
            if event.clickCount == 2 {
                didDoubleClick?()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !started, let url = prepareFile?() else { return }
            started = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = preview ?? NSImage(size: bounds.size)
            item.setDraggingFrame(bounds, contents: image)
            _ = beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            started = false
            didFinish?(operation != [])
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }
            horizontalScroll += event.scrollingDeltaX
            if abs(horizontalScroll) > 65 {
                let expectedSign: CGFloat = isLeftCorner ? 1 : -1
                if horizontalScroll * expectedSign > 0 { didSwipe?() }
                horizontalScroll = 0
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                horizontalScroll = 0
            }
        }
    }
}
