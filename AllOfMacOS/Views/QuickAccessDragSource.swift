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
    var didClick: (() -> Void)? = nil
    var didFinishWithModifiers: ((Bool, Bool) -> Void)? = nil

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
        view.didClick = didClick
        view.didFinishWithModifiers = didFinishWithModifiers
    }

    final class DraggableView: NSView, NSDraggingSource {
        var preview: NSImage?
        var prepareFile: (() -> URL?)?
        var didFinish: ((Bool) -> Void)?
        var didDoubleClick: (() -> Void)?
        var didSwipe: (() -> Void)?
        var isLeftCorner = false
        var didFinishWithModifiers: ((Bool, Bool) -> Void)?
        var didClick: (() -> Void)?
        private var pendingClick: DispatchWorkItem?
        private var mouseDownPoint = NSPoint.zero
        private var handledDoubleClick = false
        private var started = false
        private var horizontalScroll: CGFloat = 0

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            pendingClick?.cancel()
            pendingClick = nil
            started = false
            mouseDownPoint = event.locationInWindow
            handledDoubleClick = event.clickCount >= 2
            if handledDoubleClick { didDoubleClick?() }
        }

        override func mouseUp(with event: NSEvent) {
            guard !started, !handledDoubleClick, didClick != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.didClick?()
                self.pendingClick = nil
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { pendingClick?.cancel(); pendingClick = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            guard !started, !handledDoubleClick,
                  hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 4 else { return }
            pendingClick?.cancel()
            pendingClick = nil
            // Suppress click even when an unavailable file prevents export.
            started = true
            guard let url = prepareFile?() else { return }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = preview ?? NSImage(size: bounds.size)
            item.setDraggingFrame(bounds, contents: image)
            _ = beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Keep mouseUp from opening a preview after the drag ends.
            started = true
            // Snapshot at the native drop completion, before callbacks can
            // change focus or open another window.
            let optionPressed = NSEvent.modifierFlags.contains(.option)
            if let didFinishWithModifiers {
                didFinishWithModifiers(operation != [], optionPressed)
            } else {
                didFinish?(operation != [])
            }
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
