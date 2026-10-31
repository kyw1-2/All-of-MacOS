import Foundation

/// One day's focus in the stats chart.
struct FocusDayTotal: Identifiable, Equatable {
    /// Start of the day in the calendar used for the stats.
    let day: Date
    var sessions: Int
    var seconds: TimeInterval

    var id: Date { day }
    var minutes: Int { FocusDurationFormat.minutes(seconds) }
}

/// Today's and this week's counts and minutes, and the last seven days.
struct FocusStats: Equatable {
    var todaySessions = 0
    var todaySeconds: TimeInterval = 0
    var weekSessions = 0
    var weekSeconds: TimeInterval = 0
    /// Oldest first; the last one is today.
    var lastSevenDays: [FocusDayTotal] = []

    var todayMinutes: Int { FocusDurationFormat.minutes(todaySeconds) }
    var weekMinutes: Int { FocusDurationFormat.minutes(weekSeconds) }

    /// "2 sessions · 50 min today"
    var todaySummary: String {
        "\(todaySessions) \(todaySessions == 1 ? "session" : "sessions") · \(todayMinutes) min today"
    }
}

/// Log aggregation. A completed session counts on the day it ended; its
/// minutes are split across midnight in proportion to the time on each day,
/// so a session from 23:50 to 00:15 gives 10 minutes to one day and 15 to
/// the next. "This week" is the calendar's week (its first weekday).
enum FocusStatsCalculator {
    static func stats(for entries: [FocusLogEntry], now: Date, calendar: Calendar) -> FocusStats {
        let today = calendar.startOfDay(for: now)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return FocusStats() }
        var stats = FocusStats()
        var days: [Date: FocusDayTotal] = [:]
        let firstDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var cursor = firstDay
        while cursor <= today {
            days[cursor] = FocusDayTotal(day: cursor, sessions: 0, seconds: 0)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for entry in entries where entry.end >= min(firstDay, week.start) && entry.start <= now {
            let endDay = calendar.startOfDay(for: entry.end)
            if entry.completed {
                if endDay == today { stats.todaySessions += 1 }
                if week.contains(entry.end) { stats.weekSessions += 1 }
                days[endDay]?.sessions += 1
            }
            for (day, seconds) in split(entry, calendar: calendar) {
                if day == today { stats.todaySeconds += seconds }
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                if day >= week.start && dayEnd <= week.end { stats.weekSeconds += seconds }
                days[day]?.seconds += seconds
            }
        }
        stats.lastSevenDays = days.values.sorted { $0.day < $1.day }
        return stats
    }

    /// The entry's focused seconds per calendar day.
    static func split(_ entry: FocusLogEntry, calendar: Calendar) -> [(Date, TimeInterval)] {
        let span = entry.end.timeIntervalSince(entry.start)
        guard span > 0 else { return [(calendar.startOfDay(for: entry.end), entry.focusedSeconds)] }
        let scale = min(1, entry.focusedSeconds / span)
        var parts: [(Date, TimeInterval)] = []
        var segmentStart = entry.start
        var guardCount = 0
        while segmentStart < entry.end, guardCount < 400 {
            guardCount += 1
            let day = calendar.startOfDay(for: segmentStart)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? entry.end
            let segmentEnd = min(entry.end, nextDay)
            parts.append((day, segmentEnd.timeIntervalSince(segmentStart) * scale))
            segmentStart = segmentEnd
        }
        return parts
    }
}

/// The session log on disk: Application Support/AllOfMacOS/Focus/sessions.json.
/// It keeps about a year (at most 5000 entries) and is written off the main
/// thread; `flush()` waits for pending writes (tests).
@MainActor
final class FocusLogStore: ObservableObject {
    static let fileName = "sessions.json"
    static let retentionDays = 400
    static let maximumEntries = 5000

    @Published private(set) var entries: [FocusLogEntry] = []
    let directory: URL

    private struct File: Codable {
        var version = 1
        var entries: [FocusLogEntry]
    }

    init(directory: URL) {
        self.directory = directory
        if let file = FocusStorage.load(File.self, named: Self.fileName, in: directory) {
            entries = file.entries.sorted { $0.end < $1.end }
        }
    }

    func append(_ entry: FocusLogEntry, now: Date = Date()) {
        entries.append(entry)
        entries.sort { $0.end < $1.end }
        prune(now: now)
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Replaces the log (isolated previews only).
    func replace(with entries: [FocusLogEntry]) {
        self.entries = entries.sorted { $0.end < $1.end }
        save()
    }

    func stats(now: Date, calendar: Calendar = .current) -> FocusStats {
        FocusStatsCalculator.stats(for: entries, now: now, calendar: calendar)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        entries.removeAll { $0.end < cutoff }
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
    }

    private func save() {
        FocusStorage.save(File(entries: entries), named: Self.fileName, in: directory)
    }
}
