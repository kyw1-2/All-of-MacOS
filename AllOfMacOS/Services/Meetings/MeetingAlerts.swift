import AppKit
import EventKit
import SwiftUI

/// 7.4 (In Your Face, Meeter, Itsycal): the next meeting counts down in the
/// menu bar from 30 minutes before, and a full-screen alert covers every
/// display a minute before it starts, with Join when the event has a
/// meeting link. Events come from My Schedule's calendar reading.
@MainActor
final class MeetingAlerts: NSObject {
    static let shared = MeetingAlerts()

    static let leadKey = "AOMMeetingAlerts.leadSeconds"
    static let countdownMinutes = 30
    static var leadSeconds: Double {
        get { UserDefaults.standard.object(forKey: leadKey) as? Double ?? 60 }
        set { UserDefaults.standard.set(min(900, max(0, newValue)), forKey: leadKey) }
    }

    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var alerted: Set<String> = []
    private var snoozed: [String: Date] = [:]
    private var panels: [NSPanel] = []
    private var shownEvent: PaletteSchedule.Event?
    private var shownAt: Date?
    /// 7.5 (Codex D06): the alerts' own read, around now — not My
    /// Schedule's week, so neither replaces the other, and an event just
    /// after midnight is read at 23:50.
    private var feed: [PaletteSchedule.Event] = []
    private var feedLoadedAt: Date?
    private var feedLoading = false
    /// The calendar changed while a read was running: read again when it ends.
    private var feedStale = false
    private var storeObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        let schedule = PaletteSchedule.shared
        if schedule.access == .notDetermined {
            Task { _ = await schedule.requestAccess(); self.tick() }
        } else if schedule.access == .denied {
            GestureHUD.shared.show(title: "Meeting Alerts", detail: "Needs Calendar access: System Settings › Privacy & Security › Calendars.")
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedLoadedAt = nil; self?.feedStale = true; self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        feed = []
        feedLoadedAt = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        dismissAlert()
    }

    // MARK: Pure

    /// Event identity for one occurrence (a repeating event shares its id).
    nonisolated static func key(_ event: PaletteSchedule.Event) -> String { "\(event.id)|\(event.start.timeIntervalSince1970)" }

    /// The next timed event that hasn't ended, starting within `window`.
    nonisolated static func next(_ events: [PaletteSchedule.Event], now: Date, window: TimeInterval) -> PaletteSchedule.Event? {
        events.filter { !$0.isAllDay && $0.end > now && $0.start > now.addingTimeInterval(-300) && $0.start.timeIntervalSince(now) <= window }
            .min { $0.start < $1.start }
    }

    /// "12m Standup", "Now Standup"; the title cut to 18 characters.
    nonisolated static func countdown(_ event: PaletteSchedule.Event, now: Date) -> String {
        let seconds = event.start.timeIntervalSince(now)
        let title = event.title.count > 18 ? String(event.title.prefix(17)).trimmingCharacters(in: .whitespaces) + "…" : event.title
        guard seconds > 0 else { return "Now \(title)" }
        return "\(max(1, Int((seconds / 60).rounded(.up))))m \(title)"
    }

    /// Whether the alert is due: inside the lead time, not shown yet, or a snooze ran out.
    nonisolated static func alertDue(_ event: PaletteSchedule.Event, now: Date, lead: TimeInterval,
                                     alerted: Set<String>, snoozedUntil: Date?) -> Bool {
        guard event.start.timeIntervalSince(now) <= lead, event.end > now else { return false }
        if let snoozedUntil { return now >= snoozedUntil }
        return !alerted.contains(key(event))
    }

    /// 7.5 (Codex D05): the alert to show now, picked on its own — the
    /// menu bar's next event may be one already shown. Timed events not
    /// shown yet (or whose snooze ran out), earliest first, then by key;
    /// one never shown that started over five minutes ago is let go.
    nonisolated static func dueAlert(_ events: [PaletteSchedule.Event], now: Date, lead: TimeInterval,
                                     alerted: Set<String>, snoozed: [String: Date]) -> PaletteSchedule.Event? {
        events.filter { event in
            guard !event.isAllDay else { return false }
            let until = snoozed[key(event)]
            if until == nil, event.start <= now.addingTimeInterval(-300) { return false }
            return alertDue(event, now: now, lead: lead, alerted: alerted, snoozedUntil: until)
        }
        .min { ($0.start, key($0)) < ($1.start, key($1)) }
    }

    /// The range the alerts read: from 12 hours back (a snoozed event
    /// still running) to two hours ahead, from now rather than midnight.
    nonisolated static func feedRange(now: Date) -> (start: Date, end: Date) {
        (now.addingTimeInterval(-12 * 3600), now.addingTimeInterval(2 * 3600))
    }

    // MARK: Loop

    private func refreshFeed(now: Date) {
        guard !feedLoading else { return }
        feedLoading = true
        feedStale = false
        let range = Self.feedRange(now: now)
        Task { [weak self] in
            let events = await PaletteSchedule.shared.events(from: range.start, to: range.end)
            guard let self else { return }
            self.feedLoading = false
            guard self.timer != nil else { return }
            self.feed = events ?? []
            // A change that came in during this read is read now, not in five minutes.
            self.feedLoadedAt = self.feedStale ? nil : Date()
            self.tick()
        }
    }

    private func tick() {
        let schedule = PaletteSchedule.shared
        guard schedule.access == .granted else { updateStatus(nil); return }
        let now = Date()
        if feedLoadedAt.map({ now.timeIntervalSince($0) > 300 }) ?? true { refreshFeed(now: now) }
        let next = Self.next(feed, now: now, window: Double(Self.countdownMinutes) * 60)
        updateStatus(next.map { Self.countdown($0, now: now) })
        // An open alert whose event ended, or that a fresh read no longer
        // has (canceled, moved), closes so the next one can show.
        if let shown = shownEvent {
            let fresh = feedLoadedAt.map { loaded in shownAt.map { loaded > $0 } ?? false } ?? false
            let gone = fresh && !feed.contains { Self.key($0) == Self.key(shown) }
            guard shown.end <= now || gone else { return }
            dismissAlert()
        }
        guard let event = Self.dueAlert(feed, now: now, lead: Self.leadSeconds, alerted: alerted, snoozed: snoozed) else { return }
        let key = Self.key(event)
        alerted.insert(key)
        snoozed[key] = nil
        showAlert(event)
    }

    /// The user closed the alert: another one due at the same time shows next.
    private func closeAndContinue() {
        dismissAlert()
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    private func updateStatus(_ text: String?) {
        guard let text else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.title = text
        item.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Next meeting")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
    }

    @objc private func statusClicked() {
        guard let event = Self.next(feed, now: Date(), window: Double(Self.countdownMinutes) * 60) else { return }
        if let link = event.meetingLink { NSWorkspace.shared.open(link) } else { PaletteSchedule.open(event) }
    }

    // MARK: Alert

    private func showAlert(_ event: PaletteSchedule.Event) {
        dismissAlert()
        shownEvent = event
        shownAt = Date()
        let main = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        for screen in NSScreen.screens {
            let panel = MeetingAlertPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = MeetingAlertView(event: event, join: event.meetingLink == nil ? nil : { [weak self] in
                if let link = event.meetingLink { NSWorkspace.shared.open(link) }
                self?.closeAndContinue()
            }, snooze: { [weak self] in
                self?.snoozed[Self.key(event)] = Date().addingTimeInterval(60)
                self?.closeAndContinue()
            }, dismiss: { [weak self] in self?.closeAndContinue() })
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(screen.frame, display: true)
            // The pointer's display takes the keys (↩ Join, esc Dismiss)
            // without bringing AOM forward.
            if screen == main { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
            panels.append(panel)
        }
        NSSound(named: "Glass")?.play()
    }

    private func dismissAlert() {
        for panel in panels { panel.orderOut(nil) }
        panels = []
        shownEvent = nil
        shownAt = nil
    }
}

/// A borderless panel can't be key by default, which would leave the
/// alert's ↩ and esc dead.
final class MeetingAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MeetingAlertView: View {
    let event: PaletteSchedule.Event
    let join: (() -> Void)?
    let snooze: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityHidden(true)
                Text(event.title).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(3)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.when(event, now: context.date)).font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
                }
                if let location = event.location {
                    Text(location).font(.system(size: 14)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if let join {
                        Button("Join", action: join).keyboardShortcut(.defaultAction).controlSize(.large)
                    }
                    Button("Remind in 1 Minute", action: snooze).controlSize(.large)
                    Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction).controlSize(.large)
                }
                .padding(.top, 10)
            }
            .padding(40)
            .frame(maxWidth: 640)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting starting: \(event.title)")
    }

    static func when(_ event: PaletteSchedule.Event, now: Date) -> String {
        let seconds = Int(event.start.timeIntervalSince(now))
        let range = "\(PaletteSchedule.clock(event.start))–\(PaletteSchedule.clock(event.end))"
        if seconds > 0 { return "Starts in \(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(range)" }
        return "Started · \(range)"
    }
}
