import Foundation

struct TriggerTimeWindow: Codable, Hashable {
    var weekdays: [Int] = Array(1...7)
    var startMinute = 0
    var endMinute = 1439
    var firstDate: Date?
    var lastDate: Date?

    /// Inclusive local date bounds and minute bounds. An overnight interval
    /// (22:00–06:00) belongs to its starting weekday, including the next morning.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard (0...1439).contains(startMinute), (0...1439).contains(endMinute) else { return false }
        if let firstDate, date < calendar.startOfDay(for: firstDate) { return false }
        if let lastDate, date >= (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDate)) ?? .distantPast) { return false }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var weekday = parts.weekday ?? 0
        if startMinute <= endMinute { return weekdays.contains(weekday) && (startMinute...endMinute).contains(minute) }
        if minute <= endMinute { weekday = weekday == 1 ? 7 : weekday - 1 }
        return weekdays.contains(weekday) && (minute >= startMinute || minute <= endMinute)
    }
}
