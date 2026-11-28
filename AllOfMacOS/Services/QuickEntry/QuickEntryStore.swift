import AppKit
import EventKit

/// 7.23: where a Quick Entry goes — a clipboard note (pinned history item),
/// a reminder or a calendar event. Calendar and Reminders access is asked
/// the first time that destination is used (Fantastical's "ask at use"),
/// never at launch.
@MainActor
final class QuickEntryStore {
    static let shared = QuickEntryStore()

    enum Destination: String, CaseIterable, Identifiable {
        case note, reminder, event
        var id: String { rawValue }
        var title: String {
            switch self {
            case .note: "Note"
            case .reminder: "Reminder"
            case .event: "Event"
            }
        }
        var symbol: String {
            switch self {
            case .note: "note.text"
            case .reminder: "checklist"
            case .event: "calendar"
            }
        }
    }

    enum Outcome: Equatable {
        case saved(String)
        case failed(title: String, why: String, fix: String?)
    }

    private let store = EKEventStore()

    static let destinationKey = "AOMQuickEntryDestination"
    var lastDestination: Destination {
        get { Destination(rawValue: UserDefaults.standard.string(forKey: Self.destinationKey) ?? "") ?? .note }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.destinationKey) }
    }

    func save(_ text: String, to destination: Destination, now: Date = Date()) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(title: "Nothing to save", why: "The field is empty.", fix: nil) }
        let sentence = QuickEntryParser.parse(trimmed, now: now)
        switch destination {
        case .note:
            guard ClipboardStore.shared.createTextItem(trimmed) != nil else {
                return .failed(title: "The note wasn't saved", why: ClipboardStore.shared.lastError ?? "Clipboard history is off or full.",
                               fix: "Turn on Clipboard history in Settings")
            }
            return .saved("Saved to Clipboard history")
        case .reminder:
            guard await access(.reminder) else { return Self.denied(.reminder) }
            let reminder = EKReminder(eventStore: store)
            reminder.title = sentence?.title ?? trimmed
            guard let list = store.defaultCalendarForNewReminders() else {
                return .failed(title: "No reminders list", why: "Reminders has no default list to add to.", fix: "Open Reminders and make a list")
            }
            reminder.calendar = list
            if let sentence {
                var parts = Calendar.current.dateComponents([.year, .month, .day], from: sentence.date)
                if sentence.hasTime {
                    parts.hour = Calendar.current.component(.hour, from: sentence.date)
                    parts.minute = Calendar.current.component(.minute, from: sentence.date)
                    reminder.addAlarm(EKAlarm(absoluteDate: sentence.date))
                }
                reminder.dueDateComponents = parts
            }
            do { try store.save(reminder, commit: true) }
            catch { return .failed(title: "The reminder wasn't added", why: error.localizedDescription, fix: nil) }
            return .saved(sentence.map { "Reminder · \(QuickEntryParser.describe($0, now: now))" } ?? "Added to Reminders")
        case .event:
            guard let sentence else {
                return .failed(title: "No time in this sentence", why: "An event needs a day or a time, like “tomorrow 3pm” or “내일 3시”.",
                               fix: "Add a day or time, or save it as a note")
            }
            guard await access(.event) else { return Self.denied(.event) }
            guard let calendar = store.defaultCalendarForNewEvents else {
                return .failed(title: "No calendar", why: "Calendar has no default calendar to add to.", fix: "Choose a default calendar in Calendar › Settings")
            }
            let event = EKEvent(eventStore: store)
            event.title = sentence.title
            event.calendar = calendar
            event.startDate = sentence.date
            event.isAllDay = !sentence.hasTime
            event.endDate = sentence.hasTime ? sentence.date.addingTimeInterval(sentence.duration) : sentence.date
            do { try store.save(event, span: .thisEvent, commit: true) }
            catch { return .failed(title: "The event wasn't added", why: error.localizedDescription, fix: nil) }
            return .saved("\(sentence.title) · \(QuickEntryParser.describe(sentence, now: now))")
        }
    }

    private func access(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess, .authorized: return true
        case .writeOnly: return type == .event
        case .notDetermined:
            do {
                return type == .reminder ? try await store.requestFullAccessToReminders()
                    : try await store.requestWriteOnlyAccessToEvents()
            } catch { return false }
        default: return false
        }
    }

    private static func denied(_ type: EKEntityType) -> Outcome {
        let name = type == .reminder ? "Reminders" : "Calendars"
        return .failed(title: "AOM can't add to \(name)", why: "Access to \(name) is off for All of MacOS.",
                       fix: "Allow it in System Settings › Privacy & Security › \(name)")
    }

    static func openPrivacy(for destination: Destination) {
        let pane = destination == .reminder ? "Privacy_Reminders" : "Privacy_Calendars"
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
