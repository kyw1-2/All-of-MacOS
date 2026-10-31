import AppKit
import Foundation

/// Recognises a shake in a stream of pointer positions: several fast
/// left-right reversals, each stroke long enough to be deliberate. Pure and
/// clock-free (times come with the samples), so traces are unit-tested.
struct FilesShakeDetector {
    struct Tuning: Equatable {
        /// Horizontal travel a stroke needs before its reversal counts (points).
        var minimumStroke: CGFloat
        /// Reversals that have to fall inside `window`.
        var reversals: Int
        var window: TimeInterval
        /// A slower stroke breaks the shake.
        var maximumStrokeTime: TimeInterval
        /// Back-travel below this is jitter, not a reversal (points).
        var jitter: CGFloat = 4
    }

    static func tuning(for sensitivity: FilesShakeSensitivity) -> Tuning {
        switch sensitivity {
        // design-3.4.0 b.17: three direction changes within half a second.
        case .medium: return Tuning(minimumStroke: 40, reversals: 3, window: 0.5, maximumStrokeTime: 0.25)
        case .low: return Tuning(minimumStroke: 70, reversals: 4, window: 0.6, maximumStrokeTime: 0.25)
        case .high: return Tuning(minimumStroke: 24, reversals: 3, window: 0.7, maximumStrokeTime: 0.35)
        }
    }

    var tuning: Tuning
    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var strokeStart: TimeInterval = 0
    private var opposite: CGFloat = 0
    private var oppositeStart: TimeInterval = 0
    private var reversalTimes: [TimeInterval] = []

    init(tuning: Tuning) { self.tuning = tuning }
    init(sensitivity: FilesShakeSensitivity) { self.init(tuning: Self.tuning(for: sensitivity)) }

    mutating func reset() {
        lastX = nil
        direction = 0
        travel = 0
        opposite = 0
        reversalTimes.removeAll()
    }

    /// Feeds one sample; true when it completes a shake (the detector then
    /// starts over).
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else { strokeStart = time; return false }
        let dx = x - lastX
        guard abs(dx) >= 0.5 else { return false }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if direction == 0 {
            direction = sign
            travel = abs(dx)
            strokeStart = time
            return false
        }
        if sign == direction {
            // A little back-travel that never added up was jitter: net it out.
            travel = max(0, travel - opposite) + abs(dx)
            opposite = 0
            return false
        }
        // Moving against the stroke: jitter until it adds up.
        if opposite == 0 { oppositeStart = time }
        opposite += abs(dx)
        guard opposite >= tuning.jitter else { return false }
        let strokeTime = oppositeStart - strokeStart
        if travel >= tuning.minimumStroke && strokeTime <= tuning.maximumStrokeTime {
            reversalTimes.append(oppositeStart)
        } else if strokeTime > tuning.maximumStrokeTime {
            reversalTimes.removeAll()
        }
        direction = sign
        travel = opposite
        strokeStart = oppositeStart
        opposite = 0
        reversalTimes.removeAll { oppositeStart - $0 > tuning.window }
        if reversalTimes.count >= tuning.reversals {
            reset()
            return true
        }
        return false
    }
}

/// Watches file drags for a shake (and, when chosen, a Shift press) and opens
/// the Drop Shelf at the pointer. The monitors exist only while one of the two
/// switches is on and AOM may act; outside a drag they do nothing.
@MainActor
final class FilesShakeMonitor {
    static let shared = FilesShakeMonitor()

    var onShake: ((NSPoint) -> Void)?
    private var monitors: [Any] = []
    private var detector = FilesShakeDetector(sensitivity: .medium)
    private var dragBaseline: Int?
    private var dragHandled = false
    private var shiftEnabled = false
    private var shakeEnabled = false
    private var isExcluded: (String?) -> Bool = { _ in false }

    var isRunning: Bool { !monitors.isEmpty }

    func configure(shake: Bool, shift: Bool, sensitivity: FilesShakeSensitivity, isExcluded: @escaping (String?) -> Bool) {
        self.isExcluded = isExcluded
        detector = FilesShakeDetector(sensitivity: sensitivity)
        shakeEnabled = shake
        shiftEnabled = shift
        if shake || shift { install() } else { stop() }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        dragBaseline = nil
    }

    private func install() {
        guard monitors.isEmpty else { return }
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if shiftEnabled { mask.insert(.flagsChanged) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { FilesShakeMonitor.shared.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { FilesShakeMonitor.shared.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // The drag pasteboard changes when a drag starts; remembering its
            // count now tells a new file drag from text selection or a
            // window move, which drag the mouse without it.
            dragBaseline = NSPasteboard(name: .drag).changeCount
            dragHandled = false
            detector.reset()
        case .leftMouseUp:
            dragBaseline = nil
            detector.reset()
        case .leftMouseDragged:
            guard shakeEnabled, !dragHandled, dragBaseline != nil else { return }
            let location = NSEvent.mouseLocation
            if detector.add(x: location.x, time: event.timestamp) { trigger(at: location) }
        case .flagsChanged:
            guard shiftEnabled, !dragHandled, dragBaseline != nil, NSEvent.pressedMouseButtons & 1 == 1,
                  event.modifierFlags.contains(.shift) else { return }
            trigger(at: NSEvent.mouseLocation)
        default:
            break
        }
    }

    private func trigger(at point: NSPoint) {
        guard let baseline = dragBaseline, Self.isFileDrag(baseline: baseline) else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard AutomationGate.allows(.mouse), !TriggerSuppression.shared.isPaused(forApp: front), !isExcluded(front) else { return }
        dragHandled = true
        onShake?(point)
    }

    /// A drag that started after `baseline` and carries files (or promised files).
    static func isFileDrag(baseline: Int, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        guard pasteboard.changeCount != baseline else { return false }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let fileTypes: Set<String> = [NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType",
                                      "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
                                      "com.apple.pasteboard.promised-file-content-type"]
        return !types.isDisjoint(with: fileTypes)
    }
}
