import AppKit
import ApplicationServices
import Carbon
import SwiftUI

// AOM 7.3: the input source badge (DeepSeek design v2 §6.1, Codex 7.2.3
// report p. 7; Input Source Pro's indicator: tryToDisplayIndicatorNearCursor,
// isAlwaysDisplayIndicatorNearMouse).
//
// When the keyboard input source changes — by the per-app rules or by the
// person's own 한/영 key — a small "한" or "A" shows for a moment beside the
// text caret, or beside the pointer where an app (Electron, many browsers)
// gives no caret through Accessibility. It never takes a click or focus,
// needs no Screen Recording, and stays hidden in password fields, on the
// lock screen and during the launcher's own brief switch to English.

/// One DistributedNotificationCenter observer for the input source change,
/// shared by the automation engine's trigger and the badge (Codex: one
/// signal, two kinds of demand). It exists only while someone listens.
@MainActor
final class InputSourceChangeHub {
    static let shared = InputSourceChangeHub()
    static let notification = NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")

    private var observer: NSObjectProtocol?
    private var handlers: [UUID: () -> Void] = [:]

    var listenerCount: Int { handlers.count }
    var isObserving: Bool { observer != nil }

    @discardableResult
    func subscribe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.post() }
            }
        }
        return token
    }

    func unsubscribe(_ token: UUID) {
        handlers[token] = nil
        if handlers.isEmpty, let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    /// Runs every handler (also the tests' way in).
    func post() { handlers.values.forEach { $0() } }
}

/// Where the badge goes.
enum InputSourceBadgePosition: String, CaseIterable, Identifiable {
    /// Beside the text caret, else beside the pointer.
    case caret
    /// Always beside the pointer.
    case pointer

    var id: String { rawValue }
    var title: String { self == .caret ? "Next to the text cursor" : "Next to the pointer" }
}

enum InputSourceBadgeSettings {
    static let enabledKey = "AOMInputSourceBadge"
    static let positionKey = "AOMInputSourceBadgePosition"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var position: InputSourceBadgePosition {
        get { UserDefaults.standard.string(forKey: positionKey).flatMap(InputSourceBadgePosition.init(rawValue:)) ?? .caret }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: positionKey) }
    }
}

/// Pure parts, for tests.
enum InputSourceBadgeLogic {
    /// "한" for Korean, "A" for a Latin layout, "あ", "中" … from the source's ID and name.
    static func glyph(id: String, name: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("korean") || lowered.contains("2setkorean") || lowered.contains("hangul") { return "한" }
        if lowered.contains("japanese") || lowered.contains("kotoeri") {
            return lowered.contains("roman") || lowered.contains("ascii") ? "A" : "あ"
        }
        if lowered.contains("scim") || lowered.contains("tcim") || lowered.contains("pinyin") || lowered.contains("zhuyin") || lowered.contains("chinese") { return "中" }
        if lowered.contains("vietnamese") { return "Vi" }
        if lowered.contains("russian") || lowered.contains("ukrainian") { return "Я" }
        if lowered.contains("greek") { return "Ω" }
        if lowered.contains("arabic") { return "ع" }
        if lowered.contains("hebrew") { return "א" }
        if lowered.contains("thai") { return "ก" }
        if lowered.hasPrefix("com.apple.keylayout.") {
            let layout = lowered.dropFirst("com.apple.keylayout.".count)
            if ["abc", "us", "british", "australian", "canadian", "usinternational-pc", "usextended", "dvorak", "colemak"].contains(where: { layout.hasPrefix($0) }) {
                return "A"
            }
        }
        let letters = name.filter(\.isLetter)
        return letters.isEmpty ? "A" : String(letters.prefix(2))
    }

    /// Pure: two notices of one change (the rule's switch and macOS's own
    /// echo) within 200 ms show once; a quick 한 → A → 한 shows each.
    static func isDuplicate(_ id: String, last: (id: String, at: Date)?, now: Date, window: TimeInterval = 0.2) -> Bool {
        guard let last else { return false }
        return last.id == id && now.timeIntervalSince(last.at) < window
    }

    /// Pure: the badge's frame beside `anchor` (Cocoa coordinates), kept on
    /// the screen holding the anchor: right of a caret, below-right of the
    /// pointer, flipped to the other side at an edge.
    static func frame(size: CGSize, anchor: CGRect, isCaret: Bool, screens: [CGRect]) -> CGRect {
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        let visible = screens.first { $0.insetBy(dx: -1, dy: -1).contains(point) } ?? screens.first ?? CGRect(origin: .zero, size: size)
        var origin: CGPoint
        if isCaret {
            origin = CGPoint(x: anchor.maxX + 6, y: anchor.midY - size.height / 2)
            if origin.x + size.width > visible.maxX { origin.x = anchor.minX - 6 - size.width }
        } else {
            origin = CGPoint(x: anchor.midX + 16, y: anchor.midY - 16 - size.height)
            if origin.x + size.width > visible.maxX { origin.x = anchor.midX - 16 - size.width }
            if origin.y < visible.minY { origin.y = anchor.midY + 16 }
        }
        origin.x = min(max(origin.x, visible.minX + 2), visible.maxX - size.width - 2)
        origin.y = min(max(origin.y, visible.minY + 2), visible.maxY - size.height - 2)
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
final class InputSourceBadge {
    static let shared = InputSourceBadge()

    private var token: UUID?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var last: (id: String, at: Date)?
    /// The launcher switches to English while its field has focus; that switch shows nothing.
    static var suppressedUntil = Date.distantPast

    var isRunning: Bool { token != nil }

    func refresh() {
        if InputSourceBadgeSettings.isEnabled, AOMModuleSwitches.shared.isOn(.inputSources),
           !PresetManager.isRunningTests, !PresetManager.isUIPreview { start() } else { stop() }
    }

    func start() {
        guard token == nil else { return }
        token = InputSourceChangeHub.shared.subscribe { [weak self] in self?.sourceChanged() }
    }

    func stop() {
        if let token { InputSourceChangeHub.shared.unsubscribe(token) }
        token = nil
        hide(animated: false)
    }

    private func sourceChanged() {
        guard Date() >= Self.suppressedUntil, !IsSecureEventInputEnabled(), !Self.screenIsLocked else { return }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = Self.property(source, kTISPropertyInputSourceID) else { return }
        let now = Date()
        guard !InputSourceBadgeLogic.isDuplicate(id, last: last, now: now) else { return }
        last = (id, now)
        show(InputSourceBadgeLogic.glyph(id: id, name: Self.property(source, kTISPropertyLocalizedName) ?? id),
             name: Self.property(source, kTISPropertyLocalizedName) ?? id)
    }

    /// Shows the badge now (also Settings' Preview).
    func show(_ glyph: String, name: String) {
        let size = CGSize(width: max(34, CGFloat(glyph.count) * 16 + 18), height: 30)
        let caret = InputSourceBadgeSettings.position == .caret ? Self.caretRect() : nil
        let mouse = NSEvent.mouseLocation
        let anchor = caret ?? CGRect(origin: mouse, size: .zero)
        let frame = InputSourceBadgeLogic.frame(size: size, anchor: anchor, isCaret: caret != nil, screens: NSScreen.screens.map(\.visibleFrame))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: InputSourceBadgeView(glyph: glyph))
        panel.setFrame(frame, display: true)
        hideWork?.cancel()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = reduce ? 1 : 0
            panel.orderFrontRegardless()
            if !reduce {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
            }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Input source: \(name)", .priority: NSAccessibilityPriorityLevel.low.rawValue])
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide(animated: true) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func hide(animated: Bool) {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // Display only: clicks pass through to the app being typed in.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setAccessibilityElement(false)
        return panel
    }

    /// The focused text caret in Cocoa screen coordinates, if the app tells.
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        // The caret: a zero-length range at the insertion point (some apps
        // need one character to give bounds).
        var caretRange = CFRange(location: range.location + range.length, length: 0)
        for attempt in 0..<2 {
            if attempt == 1 { caretRange = CFRange(location: max(0, caretRange.location - 1), length: 1) }
            guard let parameter = AXValueCreate(.cfRange, &caretRange) else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite else { continue }
            // AX is top-left origin on the main display.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoa = CGRect(x: attempt == 1 ? rect.maxX : rect.minX, y: mainHeight - rect.maxY, width: max(1, rect.width), height: rect.height)
            return cocoa
        }
        return nil
    }

    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

struct InputSourceBadgeView: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}
