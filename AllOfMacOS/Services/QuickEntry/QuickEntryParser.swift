import Foundation

// 7.23 (DeepSeek design reference 2026-11-25 §2.1–2.2, Things Quick Entry and
// Fantastical's add popover): one sentence — "내일 3시 회의", "meeting
// friday 4pm" — becomes a title and a time. Pure and clock-free (the caller
// passes `now` and the calendar), so every rule is unit-tested. A sentence
// that doesn't parse is not an error: the launcher keeps searching and
// Quick Entry saves the text as it is.

/// What a sentence names: a title and when.
struct QuickEntrySentence: Equatable {
    var title: String
    var date: Date
    /// False for a day without a time ("내일 장보기"): an all-day event, a
    /// reminder due that day.
    var hasTime: Bool
    var duration: TimeInterval = 3_600
}

enum QuickEntryParser {
    private enum Meridiem { case am, pm }

    /// Longest accepted sentence; longer text is a note, not an event.
    static let maximumLength = 200

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> QuickEntrySentence? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= maximumLength, !trimmed.contains("\n") else { return nil }
        var text = " " + trimmed + " "
        var found = false

        /// Removes the first match of `pattern` and returns its groups ("" for
        /// a group that took no part).
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), let whole = Range(match.range, in: text) else { return nil }
            var groups: [String] = []
            for index in 1..<max(1, match.numberOfRanges) {
                let r = match.range(at: index)
                groups.append(r.location == NSNotFound ? "" : (Range(r, in: text).map { String(text[$0]) } ?? ""))
            }
            text.replaceSubrange(whole, with: " ")
            found = true
            return groups
        }

        var monthDay: (month: Int, day: Int)?
        var dayOffset: Int?
        var weekday: (value: Int, nextWeek: Bool)?
        var hour: Int?
        var minute = 0
        var meridiem: Meridiem?
        var koreanHour = false

        if let g = take(#"(\d{1,2})\s*월\s*(\d{1,2})\s*일(?:에|날)?"#) {
            monthDay = (Int(g[0]) ?? 0, Int(g[1]) ?? 0)
        } else if let g = take(#"(?<![\d/.])(\d{1,2})/(\d{1,2})(?![\d/.])"#) {
            monthDay = (Int(g[0]) ?? 0, Int(g[1]) ?? 0)
        }
        if monthDay == nil {
            if let g = take(#"(오늘|내일|모레|글피)(?:은|에)?(?=\s|$|[가-힣])"#) {
                dayOffset = ["오늘": 0, "내일": 1, "모레": 2, "글피": 3][g[0]]
            } else if let g = take(#"\b(today|tonight|tomorrow)\b"#) {
                dayOffset = g[0].lowercased() == "tomorrow" ? 1 : 0
                if g[0].lowercased() == "tonight" { meridiem = .pm; if hour == nil { hour = 20 } }
            }
        }
        if monthDay == nil, dayOffset == nil {
            let korean = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]
            if let g = take(#"(다음\s*주|담주|이번\s*주)?\s*(월|화|수|목|금|토|일)(?:요일|욜)(?:에|날)?"#) {
                weekday = (korean[g[1]] ?? 2, g[0].hasPrefix("다") || g[0].hasPrefix("담"))
            } else if let g = take(#"\b(?:on\s+)?(next\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#) {
                let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
                weekday = ((names.firstIndex(of: g[1].lowercased()) ?? 1) + 1, !g[0].isEmpty)
            }
        }

        if let g = take(#"(오전|오후|아침|저녁|밤|새벽|낮)"#) {
            meridiem = ["오전", "아침", "새벽"].contains(g[0]) ? .am : .pm
            if g[0] == "낮" { meridiem = .pm }
        }
        if let g = take(#"(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분|\s*(반))?(?:에|부터|까지)?"#) {
            hour = Int(g[0]); minute = g[2].isEmpty ? (Int(g[1]) ?? 0) : 30; koreanHour = true
        } else if let g = take(#"(?<![\d:])(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?(?![\d:])"#) {
            hour = Int(g[0]); minute = Int(g[1]) ?? 0
            if !g[2].isEmpty { meridiem = g[2].lowercased().hasPrefix("a") ? .am : .pm }
        } else if let g = take(#"\b(?:at\s+)?(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?=\s|$)"#) {
            hour = Int(g[0]); meridiem = g[1].lowercased().hasPrefix("a") ? .am : .pm
        } else if take(#"\bnoon\b|정오"#) != nil {
            hour = 12; meridiem = .pm
        } else if let g = take(#"\bat\s+(\d{1,2})\b"#) {
            hour = Int(g[0]); koreanHour = true
        }

        guard found else { return nil }
        if let h = hour, !(0...23).contains(h) || !(0...59).contains(minute) { return nil }

        // The title is what is left, without connecting words.
        let filler: Set<String> = ["에", "에서", "at", "on", "for", "-", "–", ",", "·"]
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !filler.contains($0.lowercased()) }
        let title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–·"))
        guard title.contains(where: \.isLetter) else { return nil }

        // The day.
        let today = calendar.startOfDay(for: now)
        var day: Date
        if let monthDay {
            guard (1...12).contains(monthDay.month), (1...31).contains(monthDay.day) else { return nil }
            var parts = calendar.dateComponents([.year], from: now)
            parts.month = monthDay.month; parts.day = monthDay.day
            guard let thisYear = calendar.date(from: parts) else { return nil }
            day = thisYear < calendar.date(byAdding: .day, value: -1, to: today)! ? calendar.date(byAdding: .year, value: 1, to: thisYear)! : thisYear
        } else if let weekday {
            let current = calendar.component(.weekday, from: today)
            if weekday.nextWeek {
                // Monday-based weeks: "다음 주 수요일" on a Tuesday is eight days on.
                let sinceMonday = (current + 5) % 7
                let nextMonday = calendar.date(byAdding: .day, value: 7 - sinceMonday, to: today)!
                day = calendar.date(byAdding: .day, value: (weekday.value + 5) % 7, to: nextMonday)!
            } else {
                var ahead = (weekday.value - current + 7) % 7
                if ahead == 0 { ahead = 7 }
                day = calendar.date(byAdding: .day, value: ahead, to: today)!
            }
        } else {
            day = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: today)!
        }

        guard var resolved = hour else {
            return QuickEntrySentence(title: title, date: day, hasTime: false)
        }
        switch meridiem {
        case .pm?: if resolved < 12 { resolved += 12 }
        case .am?: if resolved == 12 { resolved = 0 }
        case nil:
            // "3시 회의" is three in the afternoon: an unmarked 1–6 o'clock is PM.
            if koreanHour, (1...6).contains(resolved) { resolved += 12 }
        }
        guard var date = calendar.date(bySettingHour: resolved, minute: minute, second: 0, of: day) else { return nil }
        // Only a time, already past today: the next one.
        if monthDay == nil, weekday == nil, dayOffset == nil, date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return QuickEntrySentence(title: title, date: date, hasTime: true)
    }

    /// "Tomorrow 3:00 PM", "Fri 28 Nov" — the preview line.
    static func describe(_ sentence: QuickEntrySentence, now: Date = Date(), calendar: Calendar = .current) -> String {
        let dayText: String
        if calendar.isDate(sentence.date, inSameDayAs: now) { dayText = "Today" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(sentence.date, inSameDayAs: tomorrow) { dayText = "Tomorrow" }
        else { dayText = sentence.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return sentence.hasTime ? "\(dayText) \(sentence.date.formatted(date: .omitted, time: .shortened))" : "\(dayText) · all day"
    }
}
