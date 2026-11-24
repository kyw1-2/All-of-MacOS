import Foundation

// AOM 7.12 (Codex 30-app spec #3, Fantastical's proposals): free times in
// your own calendars, copied as plain text — "화요일 11/25 14:00–15:00" —
// with no titles, people or places. Nothing is created or sent. Pure.
enum PaletteFreeSlots {
    struct Busy: Equatable {
        var start: Date
        var end: Date
        var isAllDay: Bool
        /// The event is marked Free: it doesn't block the time.
        var isFree: Bool
    }

    struct Slot: Equatable, Hashable, Identifiable {
        var start: Date
        var end: Date
        var id: Date { start }
    }

    struct Hours: Equatable {
        /// Minutes from midnight: 540 is 09:00.
        var start = 540
        var end = 1080
    }

    /// Start times every `step` minutes inside working hours on weekdays,
    /// from `now` for `days` days, where a meeting of `minutes` fits without
    /// touching a busy event. A busy all-day event takes the whole day; a
    /// Free one blocks nothing. Times are wall-clock times in `calendar`'s
    /// time zone (daylight-saving days have their real hours).
    static func slots(busy: [Busy], now: Date, days: Int = 7, minutes: Int, hours: Hours = Hours(), step: Int = 30,
                      weekdaysOnly: Bool = true, calendar: Calendar = .current) -> [Slot] {
        guard minutes > 0, step > 0, hours.end > hours.start else { return [] }
        let blocking = busy.filter { !$0.isFree }
        var result: [Slot] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if weekdaysOnly, calendar.isDateInWeekend(day) { continue }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            if blocking.contains(where: { $0.isAllDay && $0.start < nextDay && $0.end > day }) { continue }
            var minute = hours.start
            while minute + minutes <= hours.end {
                defer { minute += step }
                guard let start = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
                      let end = calendar.date(byAdding: .minute, value: minutes, to: start) else { continue }
                // The wall clock must read what was asked (a DST gap moves it).
                guard calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start) == minute else { continue }
                guard start >= now else { continue }
                let clash = blocking.contains { !$0.isAllDay && $0.start < end && $0.end > start }
                if !clash { result.append(Slot(start: start, end: end)) }
            }
        }
        return result
    }

    /// The slots still free in `busy` (checked again right before copying).
    /// 7.13 (GPT F08): a time that has already started is no longer offered.
    static func stillFree(_ chosen: [Slot], busy: [Busy], now: Date? = nil, calendar: Calendar = .current) -> [Slot] {
        let blocking = busy.filter { !$0.isFree }
        return chosen.filter { slot in
            if let now, slot.start < now || slot.end <= slot.start { return false }
            return !blocking.contains { event in
                if event.isAllDay {
                    let day = calendar.startOfDay(for: slot.start)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
                    return event.start < next && event.end > day
                }
                return event.start < slot.end && event.end > slot.start
            }
        }
    }

    /// "화요일 11/25 14:00–15:00 또는 목요일 11/27 10:00–11:00 (KST)" in Korean,
    /// "Tue 25 Nov 14:00–15:00 or Thu 27 Nov 10:00–11:00 (GMT+9)" otherwise.
    static func text(_ slots: [Slot], korean: Bool, calendar: Calendar = .current) -> String {
        let zone = calendar.timeZone
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = zone
        day.locale = Locale(identifier: korean ? "ko_KR" : "en_GB")
        day.dateFormat = korean ? "EEEE M/d" : "EEE d MMM"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = zone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let parts = slots.sorted { $0.start < $1.start }.map { "\(day.string(from: $0.start)) \(time.string(from: $0.start))–\(time.string(from: $0.end))" }
        let zoneName = zone.abbreviation(for: slots.first?.start ?? Date()) ?? zone.identifier
        return parts.joined(separator: korean ? " 또는 " : " or ") + " (\(zoneName))"
    }
}
