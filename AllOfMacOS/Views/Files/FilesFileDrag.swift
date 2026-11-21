import AppKit
import SwiftUI

/// Drags files out of a SwiftUI row as real file URLs, one dragging item per
/// file (a single NSItemProvider loses files when it carries several) — the
/// files' own paths, never copies or promises. The view takes no clicks
/// itself: one shared local monitor starts the drag after the pointer moves
/// 4 pt from a press inside it, so taps still reach SwiftUI.
/// The drag only offers Copy, so a drop never moves the original.
struct FilesFileDragSource: NSViewRepresentable {
    /// The files to drag, read when the drag starts (the selection may have
    /// changed since the row was drawn).
    let urls: () -> [URL]
    var onStart: (() -> Void)?
    var onEnd: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.urls = urls
        view.onStart = onStart
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onStart = onStart
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) { view.removeMonitor() }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onStart: (() -> Void)?
        /// The drag ended; `delivered` says whether something took the files.
        var onEnd: ((_ delivered: Bool) -> Void)?
        fileprivate var start: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { FilesDragMonitor.shared.remove(self) } else { FilesDragMonitor.shared.add(self) }
        }

        func removeMonitor() { FilesDragMonitor.shared.remove(self) }

        /// 7.3 (Codex 7.2.3 report): 7.2.3 dragged only the first 64 files of
        /// a selection, silently. Every file goes now; only the first few
        /// draw an icon (the rest ride along without an image).
        fileprivate func beginDrag(from point: NSPoint, event: NSEvent) -> Bool {
            let files = urls().filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return false }
            onStart?()
            let items = files.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let offset = CGFloat(min(index, 4)) * 4
                let frame = NSRect(x: point.x - 20 + offset, y: point.y - 20 - offset, width: 40, height: 40)
                item.setDraggingFrame(frame, contents: index < FilesDragMonitor.iconLimit ? NSWorkspace.shared.icon(forFile: url.path) : nil)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = files.count > 1 ? .stack : .none
            return true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onEnd?(!operation.isEmpty)
        }

        deinit { FilesDragMonitor.shared.remove(self) }
    }
}

/// 7.3 (Codex 7.2.3 report): every shelf row added its own local mouse
/// monitor, so 100 rows ran 100 closures for each click. One monitor now
/// finds the drag view under a press and starts its drag after 4 pt.
@MainActor
final class FilesDragMonitor {
    static let shared = FilesDragMonitor()
    static let iconLimit = 8

    private struct Weak { weak var view: FilesFileDragSource.DragView? }
    private var views: [ObjectIdentifier: Weak] = [:]
    private var monitor: Any?
    private weak var pressed: FilesFileDragSource.DragView?

    /// How many drag views are registered (tests).
    var count: Int { views.values.filter { $0.view != nil }.count }
    var isMonitoring: Bool { monitor != nil }

    func add(_ view: FilesFileDragSource.DragView) {
        views[ObjectIdentifier(view)] = Weak(view: view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /// Safe from any thread: a view freed off the main thread (7.3 review)
    /// is dropped on the main queue instead of trapping in assumeIsolated.
    nonisolated func remove(_ view: FilesFileDragSource.DragView) {
        let id = ObjectIdentifier(view)
        if Thread.isMainThread {
            MainActor.assumeIsolated { drop(id) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { FilesDragMonitor.shared.drop(id) } }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        views[id] = nil
        views = views.filter { $0.value.view != nil }
        if views.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressed = nil
            for entry in views.values {
                guard let view = entry.view, view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { continue }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) {
                    view.start = point
                    pressed = view
                    break
                }
            }
            return event
        case .leftMouseUp:
            pressed?.start = nil
            pressed = nil
            return event
        default:
            guard let view = pressed, view.window === event.window, let start = view.start else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return event }
            view.start = nil
            pressed = nil
            return view.beginDrag(from: point, event: event) ? nil : event
        }
    }
}
