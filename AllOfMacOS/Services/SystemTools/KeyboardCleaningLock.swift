import AppKit
import ApplicationServices
import SwiftUI

/// One Switch's "keyboard lock for cleaning" (KeyboardCleanTool parity): an
/// event tap swallows every key, modifier and media key for a fixed time
/// while a panel counts down. The pointer keeps working, so Done Cleaning
/// unlocks at once, and the lock always ends by itself at the deadline.
/// Needs Accessibility; without it nothing is locked and the caller says so.
@MainActor
final class KeyboardCleaningLock: ObservableObject {
    static let shared = KeyboardCleaningLock()

    @Published private(set) var endsAt: Date?
    var isActive: Bool { endsAt != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panel: NSPanel?
    private var timer: Timer?

    /// The event type numbers the tap swallows: key down/up (10, 11),
    /// modifiers (12) and NX_SYSDEFINED (14: brightness, volume, media keys).
    static let blockedTypeNumbers: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue,
                                               CGEventType.flagsChanged.rawValue, 14]

    static var eventMask: CGEventMask {
        blockedTypeNumbers.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }

    /// Clamped to 10 s…2 min so a lock can never outlast a short wipe.
    static func clampedSeconds(_ seconds: Int) -> Int { min(120, max(10, seconds)) }

    enum StartError: LocalizedError {
        case needsAccessibility, tapUnavailable
        var errorDescription: String? {
            switch self {
            case .needsAccessibility:
                return "Locking the keyboard needs Accessibility. Turn on All of MacOS in System Settings › Privacy & Security › Accessibility, then try again."
            case .tapUnavailable:
                return "macOS didn't allow the keyboard to be locked, so nothing is locked."
            }
        }
    }

    func start(seconds: Int) throws {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else { throw StartError.needsAccessibility }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // macOS turns a slow or idle tap off; turn it straight back on
            // so the lock holds for its whole time.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in KeyboardCleaningLock.shared.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: Self.eventMask, callback: callback, userInfo: nil) else {
            throw StartError.tapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        endsAt = Date().addingTimeInterval(TimeInterval(Self.clampedSeconds(seconds)))
        showPanel()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in KeyboardCleaningLock.shared.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        panel?.orderOut(nil); panel = nil
        endsAt = nil
    }

    private func reenableTap() {
        if let tap, isActive { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func tick() {
        guard let endsAt else { return }
        if endsAt <= Date() { stop() } else { objectWillChange.send() }
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Keyboard Locked"
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: KeyboardCleaningPanel(lock: self))
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct KeyboardCleaningPanel: View {
    @ObservedObject var lock: KeyboardCleaningLock

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Keys are ignored while you clean.")
                .font(AOMFont.body)
            if let endsAt = lock.endsAt {
                Text("Unlocks by itself in \(max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))) s")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Done Cleaning") { lock.stop() }
                .controlSize(.regular)
        }
        .padding(AOMSpace.x4)
        .frame(width: 340, height: 150)
    }
}
