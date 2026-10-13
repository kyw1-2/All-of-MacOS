import AppKit
import SwiftUI

/// Observe mouse-down without competing with SwiftUI's double-click or drag recognizers.
struct ImmediateMouseSelection: NSViewRepresentable {
    var select: () -> Void

    func makeNSView(context: Context) -> SelectionObserver {
        let view = SelectionObserver()
        view.select = select
        return view
    }

    func updateNSView(_ view: SelectionObserver, context: Context) { view.select = select }
    static func dismantleNSView(_ view: SelectionObserver, coordinator: ()) { view.stopObserving() }

    final class SelectionObserver: NSView {
        var select: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.clickCount == 1 { self.select?() }
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
