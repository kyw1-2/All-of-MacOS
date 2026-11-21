import AppKit
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
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

    // MARK: Loop

    private func tick() {
        let schedule = PaletteSchedule.shared
        guard schedule.access == .granted else { updateStatus(nil); return }
        if schedule.loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { schedule.load(days: 1) }
        let now = Date()
        let next = Self.next(schedule.events ?? [], now: now, window: Double(Self.countdownMinutes) * 60)
        updateStatus(next.map { Self.countdown($0, now: now) })
        guard let event = next, shownEvent == nil else { return }
        let key = Self.key(event)
        if Self.alertDue(event, now: now, lead: Self.leadSeconds, alerted: alerted, snoozedUntil: snoozed[key]) {
            alerted.insert(key)
            snoozed[key] = nil
            showAlert(event)
        }
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
        guard let event = Self.next(PaletteSchedule.shared.events ?? [], now: Date(), window: Double(Self.countdownMinutes) * 60) else { return }
        if let link = event.meetingLink { NSWorkspace.shared.open(link) } else { PaletteSchedule.open(event) }
    }

    // MARK: Alert

    private func showAlert(_ event: PaletteSchedule.Event) {
        dismissAlert()
        shownEvent = event
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
                self?.dismissAlert()
            }, snooze: { [weak self] in
                self?.snoozed[Self.key(event)] = Date().addingTimeInterval(60)
                self?.dismissAlert()
            }, dismiss: { [weak self] in self?.dismissAlert() })
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
