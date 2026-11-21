import AppKit
import Contacts
import EventKit

// AOM 7.2 (Oracle report 05 §3-B): the calendar and contacts in the
// launcher — "My Schedule" lists the next seven days and joins a meeting
// link, "Search Contacts" copies an address or starts a call. Access is
// asked only when one of those screens is opened and the Allow row is
// chosen; the root search shows events and people only once access was
// given, and never makes an empty section.

@MainActor
final class PaletteSchedule: ObservableObject {
    static let shared = PaletteSchedule()

    enum Access: Equatable { case notDetermined, denied, granted }

    struct Event: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String
        let location: String?
        let meetingLink: URL?
    }

    @Published private(set) var events: [Event]?
    @Published private(set) var lastError: String?
    /// 7.3 (7.2.1 audit B17): how many events the week holds when more than are listed.
    @Published private(set) var totalCount = 0
    /// When the list was read (the empty launcher reads it again after five minutes).
    private(set) var loadedAt: Date?
    private let store = EKEventStore()
    private var ticket = 0

    var access: Access {
        if PresetManager.isUIPreview { return .granted }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .granted
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        guard !PresetManager.isUIPreview, access == .notDetermined else { return access == .granted }
        do { return try await store.requestFullAccessToEvents() } catch { lastError = error.localizedDescription; return false }
    }

    /// The next `days` days, from the start of today.
    func load(days: Int = 7, now: Date = Date()) {
        if PresetManager.isUIPreview { events = Self.samples(now: now); return }
        guard access == .granted else { events = nil; return }
        ticket &+= 1
        let current = ticket
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? now.addingTimeInterval(Double(days) * 86_400)
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let all = store.events(matching: predicate)
                .filter { $0.status != .canceled }
                .sorted { $0.startDate < $1.startDate }
            let total = all.count
            let found = all
                .prefix(500)
                .map { event in
                    Event(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                          start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                          calendar: event.calendar?.title ?? "", location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                          meetingLink: Self.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]))
                }
            await MainActor.run { [weak self] in
                guard let self, self.ticket == current else { return }
                self.events = Array(found)
                self.totalCount = total
                self.loadedAt = Date()
            }
        }
    }

    /// Pure: a Zoom, Meet, Teams, Webex or FaceTime link in the event's texts.
    nonisolated static func meetingLink(in texts: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    /// Pure: "Now", "in 25 min", "14:00–15:00", "All day".
    nonisolated static func timing(of event: Event, now: Date, calendar: Calendar = .current) -> String {
        if event.isAllDay { return "All day" }
        if event.start <= now, event.end > now { return "Now · until \(clock(event.end))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes >= 0, minutes < 60, calendar.isDate(event.start, inSameDayAs: now) { return "in \(max(1, minutes)) min" }
        return "\(clock(event.start))–\(clock(event.end))"
    }

    nonisolated static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Pure: "Today", "Tomorrow", "Monday 24 November".
    nonisolated static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The Calendar app on the event's day (Calendar has no public link to one event).
    static func open(_ event: Event) {
        let seconds = Int(event.start.timeIntervalSinceReferenceDate)
        if let url = URL(string: "ical://ekevent/\(event.id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple-calevent://\(seconds)") { NSWorkspace.shared.open(url) }
    }

    nonisolated static func samples(now: Date) -> [Event] {
        let calendar = Calendar.current
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let start = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .minute, value: (day * 24 + hour) * 60 + minute, to: start) ?? now
        }
        return [
            Event(id: "s1", title: "Design review", start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(80 * 60),
                  isAllDay: false, calendar: "Work", location: "Zoom", meetingLink: URL(string: "https://zoom.us/j/123")),
            Event(id: "s2", title: "Lunch with Minji", start: at(0, 12, 30), end: at(0, 13, 30), isAllDay: false,
                  calendar: "Home", location: "Seongsu", meetingLink: nil),
            Event(id: "s3", title: "Algorithms lecture", start: at(1, 10), end: at(1, 11, 30), isAllDay: false,
                  calendar: "School", location: "Room 301", meetingLink: nil),
            Event(id: "s4", title: "Mom's birthday", start: at(2, 0), end: at(3, 0), isAllDay: true,
                  calendar: "Family", location: nil, meetingLink: nil),
        ]
    }
}

@MainActor
final class PaletteContacts: ObservableObject {
    static let shared = PaletteContacts()

    struct Person: Identifiable, Hashable {
        let id: String
        let name: String
        let organization: String?
        let emails: [String]
        let phones: [String]
    }

    @Published private(set) var people: [Person]?
    /// 7.3 (7.2.1 audit B18): reading Contacts failed (and why), instead of an empty list.
    @Published private(set) var lastError: String?
    /// The address book holds more than the 5,000 read.
    @Published private(set) var truncated = false
    private let store = CNContactStore()
    private var loading = false

    var access: PaletteSchedule.Access {
        if PresetManager.isUIPreview { return .granted }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        @unknown default: return .granted
        }
    }

    func requestAccess() async -> Bool {
        guard !PresetManager.isUIPreview, access == .notDetermined else { return access == .granted }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Everyone once per launcher session (names, companies, addresses,
    /// numbers); searching filters this list.
    func load() {
        if PresetManager.isUIPreview { people = Self.samples; return }
        guard access == .granted, !loading else { return }
        loading = true
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                           CNContactOrganizationNameKey as CNKeyDescriptor,
                                           CNContactEmailAddressesKey as CNKeyDescriptor,
                                           CNContactPhoneNumbersKey as CNKeyDescriptor]
            var found: [Person] = []
            var failure: String?
            var more = false
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .userDefault
            do { try store.enumerateContacts(with: request) { contact, stop in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
                guard !name.isEmpty || organization != nil else { return }
                found.append(Person(id: contact.identifier, name: name.isEmpty ? organization ?? "" : name, organization: name.isEmpty ? nil : organization,
                                    emails: contact.emailAddresses.map { $0.value as String },
                                    phones: contact.phoneNumbers.map { $0.value.stringValue }))
                if found.count >= 5_000 { more = true; stop.pointee = true }
            } } catch { failure = error.localizedDescription }
            let result = found, problem = failure, truncated = more
            await MainActor.run { [weak self] in
                self?.people = result
                self?.lastError = problem
                self?.truncated = truncated
                self?.loading = false
            }
        }
    }

    func reset() { people = nil }

    /// Pure: name prefix, a word of the name, the company, then an address or number.
    nonisolated static func matching(_ query: String, in people: [Person], limit: Int) -> [Person] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(people.prefix(limit)) }
        let digits = needle.filter(\.isNumber)
        func rank(_ person: Person) -> Int? {
            let name = person.name.lowercased()
            if name.hasPrefix(needle) { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 1 }
            if name.contains(needle) || person.organization?.lowercased().contains(needle) == true { return 2 }
            if person.emails.contains(where: { $0.lowercased().contains(needle) }) { return 3 }
            if digits.count >= 3, person.phones.contains(where: { $0.filter(\.isNumber).contains(digits) }) { return 3 }
            return nil
        }
        return people.compactMap { person in rank(person).map { (person, $0) } }
            .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
            .prefix(limit).map(\.0)
    }

    static func open(_ person: Person) {
        if let url = URL(string: "addressbook://\(person.id)") { NSWorkspace.shared.open(url) }
    }

    nonisolated static let samples: [Person] = [
        Person(id: "p1", name: "Minji Park", organization: "Studio Orbit", emails: ["minji@example.com"], phones: ["+82 10-1234-5678"]),
        Person(id: "p2", name: "Daniel Kim", organization: nil, emails: ["daniel.kim@example.com"], phones: []),
        Person(id: "p3", name: "Seoyeon Lee", organization: "Korea University", emails: [], phones: ["+82 2-3290-1114"]),
    ]
}
