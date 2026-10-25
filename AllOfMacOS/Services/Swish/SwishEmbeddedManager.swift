import AppKit
import Combine
import Foundation

/// Manages the embedded native Swish engine helper application.
/// Provides seamless lifecycle control, status observation, and preferences bridging.
@MainActor
final class SwishEmbeddedManager: ObservableObject {
    static let shared = SwishEmbeddedManager()

    static let swishBundleID = "co.highlyopinionated.swish"
    static let defaultsEnabledKey = "AOMSwishEnabled"

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isEmbeddedAvailable: Bool = false
    @Published private(set) var swishCount: Int = 0
    @Published private(set) var modifierName: String = "Control"

    private var pollTimer: Timer?

    private var helperURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Swish.app")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let system = URL(fileURLWithPath: "/Applications/Swish.app")
        if FileManager.default.fileExists(atPath: system.path) {
            return system
        }
        return nil
    }

    private init() {
        refresh()
        setupPolling()
        if UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true {
            startIfNeeded()
        }
    }

    func setupPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isEmbeddedAvailable = (helperURL != nil)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.swishBundleID)
        isRunning = apps.contains { !$0.isTerminated }

        if let defaults = UserDefaults(suiteName: Self.swishBundleID) {
            swishCount = defaults.integer(forKey: "numberOfSwishes")
            let mod = defaults.integer(forKey: "generalModifier")
            if mod == 262144 {
                modifierName = "Control"
            } else if mod == 524288 {
                modifierName = "Option"
            } else if mod == 1048576 {
                modifierName = "Command"
            } else if mod == 131072 {
                modifierName = "Shift"
            } else if mod == 0 {
                modifierName = "None (Titlebar Only)"
            }
        }
    }

    func startIfNeeded() {
        refresh()
        guard !isRunning, let url = helperURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.swishBundleID)
        for app in apps {
            app.terminate()
        }
        refresh()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startIfNeeded()
        }
    }

    func openPreferences() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.swishBundleID).first {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        } else if let url = helperURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }
}
