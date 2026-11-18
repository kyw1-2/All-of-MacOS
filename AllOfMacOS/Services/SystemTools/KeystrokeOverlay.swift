import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What one key press shows in the keystroke overlay (KeyCastr-style, see
/// the 2026-11-18 binary review): shortcuts and named keys are chips of
/// their own; plain and shifted characters run together as typed text.
/// Pure, so it is unit tested.
enum KeystrokeFormatter {
    struct Press: Equatable {
        let text: String
        /// A chip of its own (⌘K, ↩); false: typed text joining the run.
        let isChip: Bool
    }

    static func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
        kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12"
    ]

    /// nil: nothing to show (a dead key, or typed text while only shortcuts show).
    static func press(keyCode: Int, characters: String?, baseCharacters: String?,
                      modifiers: NSEvent.ModifierFlags, shortcutsOnly: Bool) -> Press? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let commandLike = !flags.intersection([.command, .control, .option]).isEmpty
        if let name = namedKeys[keyCode] {
            // A bare Space is typed text; with a modifier it is a chip (⌃Space).
            if keyCode == kVK_Space, !commandLike {
                return shortcutsOnly ? nil : Press(text: " ", isChip: false)
            }
            if shortcutsOnly, !commandLike { return nil }
            return Press(text: modifierGlyphs(flags) + name, isChip: true)
        }
        if commandLike {
            guard let base = baseCharacters, !base.isEmpty,
                  base.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return Press(text: modifierGlyphs(flags) + base.uppercased(), isChip: true)
        }
        guard !shortcutsOnly, let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Press(text: characters, isChip: false)
    }

    /// Appends a press to the shown entries: typed text joins the last
    /// typed run, a chip starts a new entry. Keeps the last `limit` entries
    /// and each run to its last 32 characters.
    static func appending(_ press: Press, to entries: [KeystrokeEntry], limit: Int = 5) -> [KeystrokeEntry] {
        var next = entries
        if !press.isChip, let last = next.last, !last.isChip {
            next[next.count - 1].text = String((last.text + press.text).suffix(32))
        } else {
            next.append(KeystrokeEntry(text: press.text, isChip: press.isChip))
        }
        if next.count > limit { next.removeFirst(next.count - limit) }
        return next
    }
}

struct KeystrokeEntry: Equatable, Identifiable {
    let id = UUID()
    var text: String
    let isChip: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.text == rhs.text && lhs.isChip == rhs.isChip }
}

/// Shows the keys you press at the bottom of the screen with the pointer,
/// for demos and screen recordings. A click-through panel that never takes
/// focus; nothing is shown while secure input is on (password fields), and
/// nothing is stored. Needs Accessibility, which AOM already has.
@MainActor
final class KeystrokeOverlay: ObservableObject {
    static let shared = KeystrokeOverlay()
    static let shortcutsOnlyKey = "AOMKeystrokeShortcutsOnly"
    /// How long the last keys stay after the typing stops.
    static let lingerSeconds: TimeInterval = 1.6

    @Published private(set) var isActive = false
    @Published fileprivate var entries: [KeystrokeEntry] = []

    var shortcutsOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.shortcutsOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.shortcutsOnlyKey) }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var panel: NSPanel?
    private var host: NSHostingView<KeystrokeOverlayView>?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// False when macOS refused the key monitor (no Accessibility).
    @discardableResult
    func start(shortcutsOnly: Bool) -> Bool {
        self.shortcutsOnly = shortcutsOnly
        guard !isActive else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask: NSEvent.EventTypeMask = [.keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { KeystrokeOverlay.shared.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { KeystrokeOverlay.shared.handle(event) }
            return event
        }
        isActive = globalMonitor != nil
        if !isActive { stop() }
        return isActive
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        isActive = false
        hideWork?.cancel(); hideWork = nil
        generation += 1
        entries = []
        panel?.orderOut(nil)
    }

    private func handle(_ event: NSEvent) {
        guard isActive, !IsSecureEventInputEnabled() else { return }
        guard let press = KeystrokeFormatter.press(
            keyCode: Int(event.keyCode), characters: event.characters,
            baseCharacters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
            shortcutsOnly: shortcutsOnly) else { return }
        // A long pause starts a fresh line instead of extending the old one.
        let base = (panel?.isVisible == true && panel?.alphaValue ?? 0 > 0.5) ? entries : []
        entries = KeystrokeFormatter.appending(press, to: base)
        present()
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if host == nil {
            let view = NSHostingView(rootView: KeystrokeOverlayView(model: self))
            view.sizingOptions = [.intrinsicContentSize]
            panel.contentView = view
            host = view
        }
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 200, height: 60)
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 72))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        generation += 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.generation == token else { return }
                        panel.orderOut(nil)
                        self.entries = []
                    }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerSeconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

struct KeystrokeOverlayView: View {
    @ObservedObject var model: KeystrokeOverlay

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.entries) { entry in
                Text(entry.text)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, entry.isChip ? 10 : 2)
                    .padding(.vertical, entry.isChip ? 4 : 0)
                    .background(entry.isChip ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.16)) : nil)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.72)))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keys pressed")
    }
}
