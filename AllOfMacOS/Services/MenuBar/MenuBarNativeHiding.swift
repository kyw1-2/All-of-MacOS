import AOMMenuBarNative
import AppKit

// 7.10: hiding that works on macOS 27. The user's 7.9 report: the chevron
// hid nothing and the Bar didn't work. Measured on this Mac (27.3): macOS 27
// drops a status item that grows very wide, so the 10,000 pt divider never
// pushed anything off; macOS's own menu bar restriction (MenuBarClientCore,
// as Hidden Bar 1.11 and Bartender 7 use) hid Raycast, ChatGPT and Google
// Drive at once and reflowed the bar. So on macOS 27 AOM keeps a section per
// app — Shown, Hidden, Always Hidden — chosen in Menu Bar › Layout, and asks
// macOS to show only the allowed apps. Nothing is dragged in the real menu bar.
//
// Limits macOS 27 sets: hiding is per app (an app's icons go together), and
// macOS's own items (clock, battery, sound, Control Center, Wi-Fi …) always
// stay. While anything is hidden macOS ignores clicks on the clock, so AOM
// lifts the restriction for a clock click and puts it back when the panel
// closes.

/// The section each app's icons belong to (bundle id → section).
enum MenuBarSectionStore {
    static let key = "AOMMenuBarSections"

    /// Apps macOS keeps visible whatever the list says.
    static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]

    static var all: [String: MenuBarSection] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(MenuBarSection.init(rawValue:))
    }

    static func set(_ section: MenuBarSection, for bundle: String) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if section == .shown { raw.removeValue(forKey: bundle) } else { raw[bundle] = section.rawValue }
        UserDefaults.standard.set(raw, forKey: key)
    }

    /// A preset's whole map at once (Shown entries are dropped, as in `set`).
    static func replaceAll(_ sections: [String: MenuBarSection]) {
        UserDefaults.standard.set(sections.filter { $0.value != .shown }.mapValues(\.rawValue), forKey: key)
    }

    /// Pure: which running apps may show, given what is to be hidden. AOM
    /// itself always shows (its chevron must stay).
    static func allowed(running: [String], sections: [String: MenuBarSection], hiding: Set<MenuBarSection>, own: String) -> [String] {
        var out = Set(running.filter { !hiding.contains(sections[$0] ?? .shown) })
        out.insert(own)
        return out.sorted()
    }

    /// Pure: the first sections from where icons sit against the chevron
    /// (left of it: Hidden), used once when native hiding starts.
    static func seed(items: [(bundle: String, minX: CGFloat)], chevronMinX: CGFloat) -> [String: MenuBarSection] {
        var out: [String: MenuBarSection] = [:]
        for item in items where !systemOwners.contains(item.bundle) && item.minX < chevronMinX {
            out[item.bundle] = .hidden
        }
        return out
    }
}

@MainActor
final class MenuBarNativeHiding {
    static let shared = MenuBarNativeHiding()

    /// macOS 27 or later with the restriction available, running from an
    /// Applications folder (macOS matches the list to apps it knows there).
    static let isAvailable: Bool = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27, AOMMenuBarNativeIsAvailable() else { return false }
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.contains("/Applications/")
    }()

    /// The system item ids to keep (unknown ids are ignored; 0–63 covers them).
    static let systemItems: [NSNumber] = (0..<64).map { NSNumber(value: $0) }

    private var assertion: AnyObject?
    private(set) var allowed: [String]?
    private var generation = 0
    private var launchObserver: NSKeyValueObservation?
    private var launchWork: DispatchWorkItem?
    /// The sections the current hold hides (to re-hold when apps start).
    private var hiding: Set<MenuBarSection> = []
    /// An app shown for a moment (the Bar, a clock click), and what to go back to.
    private var lift: (bundle: String?, timer: Timer?)?

    var isHolding: Bool { assertion != nil }

    /// Hides the apps in these sections; nil leaves everything visible.
    func hide(_ sections: Set<MenuBarSection>, completion: ((Bool) -> Void)? = nil) {
        hiding = sections
        guard !sections.isEmpty else { release(); completion?(true); return }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        // 7.10: an app never placed starts where the "New Menu Bar Items" pill is.
        let placed = MenuBarTriggerPolicy.sections(running: running, stored: MenuBarSectionStore.all, seen: MenuBarPrefs.seenApps,
                                                   newItems: MenuBarPrefs.newItemsSection)
        let list = MenuBarSectionStore.allowed(running: running, sections: placed, hiding: sections,
                                               own: Bundle.main.bundleIdentifier ?? "com.kyw.allofmacos")
        // The same list again (a helper process started) changes nothing.
        if isHolding, list == allowed { completion?(true) } else { activate(list, completion: completion) }
        watchLaunches()
    }

    /// Everything visible again.
    func release() {
        generation &+= 1
        hiding = []
        endLift()
        if let assertion { AOMMenuBarNativeInvalidate(assertion) }
        assertion = nil
        allowed = nil
        launchObserver = nil
        launchWork?.cancel()
        launchWork = nil
    }

    /// The new list is held before the old one goes, so nothing flashes.
    private func activate(_ list: [String], completion: ((Bool) -> Void)? = nil) {
        generation &+= 1
        let ticket = generation
        AOMMenuBarNativeActivate(Self.systemItems, list) { [weak self] handle, error in
            MainActor.assumeIsolated {
                guard let self, ticket == self.generation else {
                    if let handle { AOMMenuBarNativeInvalidate(handle) }
                    return
                }
                if let handle {
                    let old = self.assertion
                    self.assertion = handle as AnyObject
                    self.allowed = list
                    if let old { AOMMenuBarNativeInvalidate(old) }
                    completion?(true)
                } else {
                    // Fail open: never leave icons hidden after an error.
                    NSLog("AOM menu bar: macOS refused the hide list: \(error?.localizedDescription ?? "unknown")")
                    if let old = self.assertion { AOMMenuBarNativeInvalidate(old) }
                    self.assertion = nil
                    self.allowed = nil
                    completion?(false)
                }
            }
        }
    }

    /// An app that starts while something is hidden joins the list unless
    /// its section hides it.
    private func watchLaunches() {
        guard launchObserver == nil else { return }
        // Coalesced: a login or a build starts dozens of helpers at once.
        launchObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let native = MenuBarNativeHiding.shared
                    native.launchWork?.cancel()
                    let work = DispatchWorkItem {
                        guard native.isHolding, native.lift == nil else { return }
                        native.hide(native.hiding)
                    }
                    native.launchWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }
            }
        }
    }

    // MARK: Showing one app for a moment (the Bar)

    /// Lets one hidden app show (its icons come back where they were) until
    /// its menu closes and the pointer leaves the menu bar.
    func showTemporarily(_ bundle: String, then: @escaping () -> Void) {
        guard isHolding, let current = allowed, !current.contains(bundle) else { then(); return }
        endLift()
        activate((current + [bundle]).sorted()) { [weak self] ok in
            guard let self else { return }
            self.startLift(bundle: bundle)
            then()
            _ = ok
        }
    }

    private func startLift(bundle: String?) {
        var quietTicks = 0
        // Bartender's "Delay before hiding temporarily shown menu bar items"
        // (15 s); the clock's lift ends as soon as its panel closes.
        let needed = bundle == nil ? 3 : max(3, Int(MenuBarPrefs.temporaryShowSeconds * 2))
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let native = MenuBarNativeHiding.shared
                // Give the menu a moment to open, then wait until it closes.
                if MenuBarHider.isMenuBarBusy() { quietTicks = 0 } else { quietTicks += 1 }
                if quietTicks >= needed { native.endLift(); if !native.hiding.isEmpty { native.hide(native.hiding) } }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lift = (bundle, timer)
    }

    private func endLift() {
        lift?.timer?.invalidate()
        lift = nil
    }

    // MARK: The clock

    /// While anything is hidden macOS ignores the clock; a click on it lifts
    /// the restriction, presses the clock (Notification Center) and hides
    /// again once the panel has closed.
    /// A click on the menu bar (from `MenuBarTriggers`' one monitor): true
    /// when it was the clock and was handed over.
    func handleClockClick(at point: CGPoint) -> Bool {
        guard isHolding, lift == nil else { return false }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let ax = CGPoint(x: point.x, y: primary - point.y)
        guard let clock = MenuBarLayoutModel.shared.items.first(where: { $0.item.identity?.name == "Clock" })?.item,
              let frame = clock.frame, frame.insetBy(dx: -2, dy: -2).contains(ax) else { return false }
        let keep = hiding
        if let assertion { AOMMenuBarNativeInvalidate(assertion) }
        assertion = nil
        hiding = keep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AOMMenuShelfController.shared.activate(clock, retry: "Click the clock again.")
            MenuBarNativeHiding.shared.startLift(bundle: nil)
        }
        return true
    }
}
