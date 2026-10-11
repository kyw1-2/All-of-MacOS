import Foundation
import AppKit

/// Watches the Accessibility (TCC) permission state while the app runs.
///
/// TCC grants can be invalidated between launches (rebuilds, app updates,
/// system upgrades) or revoked at runtime. Previously the app checked
/// `AXIsProcessTrusted()` exactly once at launch, so losing permission meant
/// gestures silently stopped working and the only fix was force-quitting and
/// relaunching. The watchdog closes that gap:
///
///   1. Detects permission loss and asks macOS to prompt for it again
///      (once per loss episode).
///   2. Detects recovery (the user re-grants in System Settings) and fires
///      `onRecovered` so all event taps / monitors re-register without an
///      app restart.
@MainActor
final class PermissionWatchdog {
    static let accessibilityLost = Notification.Name("AOMAccessibilityLost")
    static let accessibilityRecovered = Notification.Name("AOMAccessibilityRecovered")

    /// Called on the main thread when Accessibility goes from missing to granted.
    var onRecovered: (() -> Void)?

    private var timer: Timer?
    private var granted = true
    private var promptedForCurrentLoss = false
    private var consecutiveFailures = 0
    private var lastPromptTime: Date?
    private let minPromptInterval: TimeInterval = 60.0

    func start() {
        guard timer == nil else { return }
        granted = AXIsProcessTrusted()
        promptedForCurrentLoss = !granted
        consecutiveFailures = granted ? 0 : 1
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        NSLog("[AOM] PermissionWatchdog started (accessibility: %@)", granted ? "granted" : "missing")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            consecutiveFailures = 0
            if !granted {
                granted = true
                promptedForCurrentLoss = false
                NSLog("[AOM] PermissionWatchdog: Accessibility recovered — re-registering monitors")
                NotificationCenter.default.post(name: Self.accessibilityRecovered, object: nil)
                onRecovered?()
            }
            return
        }

        consecutiveFailures += 1
        // Require at least 2 consecutive untrusted checks to avoid momentary flapping
        guard consecutiveFailures >= 2 else { return }

        if granted {
            granted = false
            NSLog("[AOM] PermissionWatchdog: Accessibility lost — prompting to re-grant")
            NotificationCenter.default.post(name: Self.accessibilityLost, object: nil)
            promptIfNeeded()
        } else if !promptedForCurrentLoss {
            promptIfNeeded()
        }
    }

    private func promptIfNeeded() {
        let now = Date()
        if let last = lastPromptTime, now.timeIntervalSince(last) < minPromptInterval {
            return
        }
        lastPromptTime = now
        promptedForCurrentLoss = true
        prompt()
    }

    private func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
