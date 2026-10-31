import AppKit

/// Focus's own menu bar item: the countdown while a session runs. It exists
/// only while a session exists and "Show the countdown in the menu bar" is
/// on, is separate from AOM's icon, and is never created in tests or
/// isolated previews. Its menu is built when it opens.
@MainActor
final class FocusStatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private weak var session: FocusSessionController?
    private let isolated: Bool
    var openPage: () -> Void = {}

    init(isolated: Bool) {
        self.isolated = isolated
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func attach(_ session: FocusSessionController) { self.session = session }

    var isShowing: Bool { item != nil }

    /// The countdown in the menu bar ("18:22"); the glyph shows the phase,
    /// or a pause symbol while paused.
    static func title(timer: FocusTimer, now: Date) -> String? {
        guard let run = timer.run else { return nil }
        return FocusDurationFormat.countdown(run.remaining(at: now))
    }

    func update() {
        guard let session else { remove(); return }
        let timer = session.timer
        guard !isolated, session.settings.settings.showsMenuBarCountdown, let run = timer.run,
              let title = Self.title(timer: timer, now: session.ticker.now) else { remove(); return }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            item.button?.imagePosition = .imageLeading
            self.item = item
        }
        guard let button = item?.button else { return }
        let symbol = run.isPaused ? "pause.circle" : run.phase.symbol
        if button.image?.accessibilityDescription != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            image?.isTemplate = true
            button.image = image
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributed = NSAttributedString(string: " " + title, attributes: [.font: font])
        if button.attributedTitle != attributed { button.attributedTitle = attributed }
        let spoken = FocusDurationFormat.spoken(run.remaining(at: session.ticker.now))
        button.setAccessibilityLabel("\(run.phase.title), \(spoken) left\(run.isPaused ? ", paused" : "")")
        button.toolTip = "\(run.phase.title) · ends \(run.endsAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "when resumed")"
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let session, let run = session.timer.run else { return }
        let header = NSMenuItem(title: "\(run.phase.title) · \(FocusDurationFormat.countdown(run.remaining(at: session.ticker.now))) left",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if run.isPaused {
            menu.addItem(QuickAccessMenuAction.item("Resume", symbol: "play.fill") { [weak session] in
                MainActor.assumeIsolated { session?.resume() }
            })
        } else {
            menu.addItem(QuickAccessMenuAction.item("Pause", symbol: "pause.fill") { [weak session] in
                MainActor.assumeIsolated { session?.pause() }
            })
        }
        let skipTitle = run.phase == .focus ? (session.timer.plan.breaksEnabled ? "Skip to Break" : "Finish Now") : "Skip Break"
        menu.addItem(QuickAccessMenuAction.item(skipTitle, symbol: "forward.end.fill") { [weak session] in
            MainActor.assumeIsolated { session?.skip() }
        })
        menu.addItem(QuickAccessMenuAction.item("Stop Focus", symbol: "stop.fill") { [weak session] in
            MainActor.assumeIsolated { session?.stop() }
        })
        menu.addItem(.separator())
        menu.addItem(QuickAccessMenuAction.item("Open Focus", symbol: "timer") { [weak self] in
            MainActor.assumeIsolated { self?.openPage() }
        })
    }
}
