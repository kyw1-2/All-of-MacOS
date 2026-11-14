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
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let trustCheck: () -> Bool
    private let requestPrompt: () -> Void
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    init(trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestPrompt: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         },
         notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter? = nil) {
        self.trustCheck = trustCheck
        self.requestPrompt = requestPrompt
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications ?? NSWorkspace.shared.notificationCenter
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { notifications.removeObserver(activationObserver) }
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
    }
    private var granted = true
    private var promptedForCurrentLoss = false
    private var consecutiveFailures = 0
    private var lastPromptTime: Date?
    private let minPromptInterval: TimeInterval = 60.0

    func start() {
        guard timer == nil else { return }
        granted = trustCheck()
        promptedForCurrentLoss = !granted
        consecutiveFailures = granted ? 0 : 1
        schedule()
        activationObserver = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        wakeObserver = workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        NSLog("[AOM] PermissionWatchdog started (accessibility: %@)", granted ? "granted" : "missing")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { notifications.removeObserver(activationObserver) }
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
        activationObserver = nil
        wakeObserver = nil
    }

    private func schedule() {
        let interval: TimeInterval = granted && consecutiveFailures == 0 ? 10 : 2
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = interval == 10 ? 2 : 0.2
    }

    func check() {
        guard timer != nil else { return }
        defer { if timer != nil { schedule() } }
        let trusted = trustCheck()
        if trusted {
            consecutiveFailures = 0
            if !granted {
                granted = true
                promptedForCurrentLoss = false
                NSLog("[AOM] PermissionWatchdog: Accessibility recovered — re-registering monitors")
                notifications.post(name: Self.accessibilityRecovered, object: nil)
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
            notifications.post(name: Self.accessibilityLost, object: nil)
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
        requestPrompt()
    }
}
