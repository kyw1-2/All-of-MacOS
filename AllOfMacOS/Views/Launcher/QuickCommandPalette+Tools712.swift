import AppKit
import SwiftUI

// AOM 7.12 (Codex "상용앱 30종 기능확장 명세서", top three): saved file
// searches (HoudahSpot), comparing two clipboard texts (Kaleidoscope) and
// copying free times (Fantastical). Each is a launcher screen built from the
// same rows, groups and headers as the rest (Oracle reports 03–05), so it
// looks and moves like the screens around it.

/// The free-time screen's state: the meeting length, the times picked and
/// the busy times read from the calendars.
@MainActor
final class PaletteAvailability: ObservableObject {
    static let shared = PaletteAvailability()

    @Published var minutes = 60
    @Published var chosen: [PaletteFreeSlots.Slot] = []
    @Published private(set) var busy: [PaletteFreeSlots.Busy]?
    @Published private(set) var loadedAt: Date?
    /// 7.13 (GPT F07): the last read failed (access taken away meanwhile) —
    /// not the same as a calendar with nothing on it.
    @Published private(set) var readFailed = false

    static let maxChosen = 3
    /// Working hours, in Settings' defaults (minutes from midnight).
    var hours: PaletteFreeSlots.Hours {
        let defaults = UserDefaults.standard
        // 7.13 (GPT F09): a value out of the day falls back inside it.
        let start = min(max(defaults.object(forKey: "AOMFreeTimesStart") as? Int ?? 540, 0), 1410)
        let end = min(max(defaults.object(forKey: "AOMFreeTimesEnd") as? Int ?? 1080, start + 30), 1440)
        return PaletteFreeSlots.Hours(start: start, end: end)
    }

    func reset() { chosen = []; minutes = 60; readFailed = false }

    /// Reads the next seven days of your calendars (titles are not kept).
    func load(now: Date = Date()) async {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 8, to: start) ?? now.addingTimeInterval(8 * 86_400)
        guard let events = await PaletteSchedule.shared.busyTimes(from: start, to: end) else {
            readFailed = true
            return
        }
        readFailed = false
        busy = events
        loadedAt = Date()
    }

    func toggle(_ slot: PaletteFreeSlots.Slot) -> Bool {
        if let index = chosen.firstIndex(of: slot) { chosen.remove(at: index); return true }
        guard chosen.count < Self.maxChosen else { return false }
        chosen.append(slot)
        return true
    }
}

extension QuickCommandPalette {
    // MARK: Saved searches (#1)

    /// Search Files' "Save This Search…" row, above the results.
    func saveSearchRow() -> PaletteItem? {
        let parsed = PaletteFileQuery.parse(trimmed)
        guard !parsed.isEmpty else { return nil }
        var row = screenRow("files.saveSearch", "Save This Search…", parsed.summary + " · found again each time you open it",
                            icon: "magnifyingglass.circle", group: "Saved Search",
                            primary: PaletteAction(title: "Save…", symbol: "square.and.arrow.down", effect: .push(.saveSearch(parsed.text))) {})
        row.placement = .fallback
        return row
    }

    func saveSearchItems(_ text: String) -> [PaletteItem] {
        let query = PaletteFileQuery.parse(text)
        let name = trimmed
        guard !name.isEmpty else {
            return [screenRow("savesearch.wait", "Type a name above", query.summary, icon: "keyboard", group: nil,
                              primary: PaletteAction(title: "Waiting", effect: .stay) {}, dimmed: true)]
        }
        let replaces = savedSearches.searches.contains { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        return [screenRow("savesearch.save", replaces ? "Replace Saved Search “\(name)”" : "Save as “\(name)”",
                          query.summary, icon: "checkmark.circle.fill", group: nil,
                          primary: PaletteAction(title: "Save", symbol: "checkmark", effect: .stay) {
                              savedSearches.save(name, query: query)
                              pop()
                              screens.show("Saved — type “\(name)” in the launcher to search again")
                          })]
    }

    /// The root's rows for saved searches: ↩ runs the conditions again.
    func savedSearchRootItems() -> [PaletteItem] {
        savedSearches.searches.map { search in
            var item = PaletteItem(id: "files.saved.\(search.id.uuidString)", title: search.name,
                                   subtitle: "Saved search · \(search.query.summary)", icon: "magnifyingglass.circle", section: .commands,
                                   primary: PaletteAction(title: "Search", symbol: "magnifyingglass",
                                                          effect: .push(.tool(.files(search.query.text)))) {},
                                   secondaries: [
                                       PaletteAction(title: "Edit Conditions", symbol: "slider.horizontal.3",
                                                     effect: .push(.tool(.files(search.query.text)))) {},
                                       PaletteAction(title: "Delete Saved Search", symbol: "trash", effect: .stay, isDestructive: true) {
                                           savedSearches.delete(search.id)
                                           screens.show("Deleted “\(search.name)” — your files are untouched")
                                       },
                                   ])
            item.keywords = "saved search houdahspot spotlight 저장된 검색 \(search.query.text)"
            return item
        }
    }

    // MARK: Compare clipboard texts (#2)

    private func clipText(_ entry: ClipboardEntry) -> String? {
        guard entry.kind == .text || entry.kind == .link else { return nil }
        return entry.text
    }

    func clipboardCompareItems(_ id: UUID) -> [PaletteItem] {
        guard let first = clipboardStore.entries.first(where: { $0.id == id }), clipText(first) != nil else {
            return [screenRow("clipcompare.gone", "That copy isn't in the history any more", "Go back with esc",
                              icon: "exclamationmark.triangle", group: nil, primary: PaletteAction(title: "Back", effect: .stay) { pop() }, dimmed: true)]
        }
        let search = isSearching ? ClipboardSearchQuery(trimmed) : nil
        let boards = clipboardStore.boards
        let others = clipboardStore.entries.lazy.filter { $0.id != id && self.clipText($0) != nil }
            .filter { search?.matches($0, boards: boards) ?? true }.prefix(200)
        return others.map { entry in
            // 7.13 (GPT F04): the older copy goes on the left once, here;
            // the route keeps that order so Swap Sides really swaps.
            let pair = first.lastCopiedAt <= entry.lastCopiedAt ? (id, entry.id) : (entry.id, id)
            return screenRow("clipcompare.\(entry.id.uuidString)", ClipboardSecretDisplay.title(entry),
                      [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                      icon: entry.kind.symbol, group: "Compare “\(first.title.prefix(40))” with", section: .clipboard,
                      primary: PaletteAction(title: "Compare", symbol: "arrow.left.arrow.right.square", effect: .push(.clipboardDiff(pair.0, pair.1))) {})
        }
    }

    func clipboardDiffItems(_ a: UUID, _ b: UUID) -> [PaletteItem] {
        guard let one = clipboardStore.entries.first(where: { $0.id == a }), let two = clipboardStore.entries.first(where: { $0.id == b }),
              let oneText = clipText(one), let twoText = clipText(two) else {
            return [screenRow("clipdiff.gone", "One of the two copies isn't in the history any more", "Go back with esc",
                              icon: "exclamationmark.triangle", group: nil, primary: PaletteAction(title: "Back", effect: .stay) { pop() }, dimmed: true)]
        }
        // The route's first copy on the left (−), its second on the right (+):
        // the older one first when the screen opens, either way after Swap Sides.
        let (old, new) = ((one, oneText), (two, twoText))
        let label = { (entry: ClipboardEntry) in
            [entry.sourceName, entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
        }
        let header = "− \(label(old.0))   + \(label(new.0))"
        let swap = PaletteAction(title: "Swap Sides", symbol: "arrow.left.arrow.right", effect: .stay) {
            pop(); push(.clipboardDiff(new.0.id, old.0.id))
        }
        guard let changes = PaletteDiffJob.shared.changes(old.1, new.1, ready: { sourcesChanged() }) else {
            return [screenRow("clipdiff.working", "Comparing…", header, icon: "hourglass", group: nil,
                              primary: PaletteAction(title: "Waiting", effect: .stay) {}, secondaries: [swap], dimmed: true)]
        }
        guard !changes.isEmpty else {
            return [screenRow("clipdiff.same", "The two texts are the same", header, icon: "equal.circle", group: nil,
                              primary: PaletteAction(title: "Back", effect: .stay) { pop() })]
        }
        let total = changes.count
        // 7.13 (GPT UX-06): how much differs, in the header of every row.
        var counts = (changed: 0, added: 0, removed: 0)
        for change in changes {
            switch change {
            case .changed: counts.changed += 1
            case .added: counts.added += 1
            case .removed: counts.removed += 1
            case .same: break
            }
        }
        let tally = [counts.changed > 0 ? "\(counts.changed) changed" : nil, counts.added > 0 ? "\(counts.added) added" : nil,
                     counts.removed > 0 ? "\(counts.removed) removed" : nil].compactMap { $0 }.joined(separator: ", ")
        let groupHeader = header + "   ·   " + tally
        return changes.enumerated().map { index, change in
            let number = "\(index + 1) of \(total)"
            let title: String, subtitle: String, icon: String, copy: String
            switch change {
            case .changed(let before, let after, let oldSpan, let newSpan):
                title = "± " + PaletteTextDiff.display(PaletteTextDiff.marked(after, newSpan))
                subtitle = "was: " + PaletteTextDiff.display(PaletteTextDiff.marked(before, oldSpan))
                icon = "plusminus.circle"
                copy = PaletteTextDiff.display(after)
            case .added(let line):
                title = "+ " + (line.isEmpty ? "(empty line)" : PaletteTextDiff.display(line))
                subtitle = "only on the right (+)"
                icon = "plus.circle"
                copy = PaletteTextDiff.display(line)
            case .removed(let line):
                title = "− " + (line.isEmpty ? "(empty line)" : PaletteTextDiff.display(line))
                subtitle = "only on the left (−)"
                icon = "minus.circle"
                copy = PaletteTextDiff.display(line)
            case .same(let line):
                title = line; subtitle = ""; icon = "equal.circle"; copy = line
            }
            var row = screenRow("clipdiff.\(index)", title, subtitle, icon: icon, group: groupHeader, section: .clipboard,
                                primary: PaletteAction(title: "Copy This Line", symbol: "doc.on.doc", effect: .stay) {
                                    copyToClipboard(copy, announce: String(copy.prefix(60)))
                                }, secondaries: [swap])
            row.accessory = number
            return row
        }
    }

    // MARK: Free times (#3)

    func enterAvailability() {
        availability.reset()
        guard schedule.access == .granted else { return }
        Task { @MainActor in
            await availability.load()
            sourcesChanged()
        }
    }

    func availabilityItems() -> [PaletteItem] {
        switch schedule.access {
        case .notDetermined:
            return [screenRow("free.allow", "Allow Calendar Access…", "macOS asks once; AOM only reads when you're busy",
                              icon: "calendar.badge.checkmark", group: nil,
                              primary: PaletteAction(title: "Allow", effect: .stay) {
                                  Task { @MainActor in
                                      if await schedule.requestAccess() { await availability.load() } else { screens.show("Calendar access wasn't given") }
                                      sourcesChanged()
                                  }
                              })]
        case .denied:
            return [privacyRow("free.settings", "Calendars")]
        case .granted:
            break
        }
        // Typing 30, 45, 60 or 90 sets the meeting's length.
        if let typed = Int(trimmed), [15, 30, 45, 60, 90, 120].contains(typed), typed != availability.minutes {
            DispatchQueue.main.async { availability.minutes = typed; availability.chosen = []; query = ""; sourcesChanged() }
        }
        if availability.readFailed {
            return [screenRow("free.failed", "Couldn't read your calendars", "Nothing is copied until they can be read · ↩ tries again",
                              icon: "exclamationmark.triangle", group: nil,
                              primary: PaletteAction(title: "Try Again", effect: .stay) {
                                  Task { @MainActor in await availability.load(); sourcesChanged() }
                              })]
        }
        guard let busy = availability.busy else {
            return [screenRow("free.loading", "Reading your calendars…", "Only when you're busy — titles, people and places stay out",
                              icon: "hourglass", group: nil, primary: PaletteAction(title: "Waiting", effect: .stay) {}, dimmed: true)]
        }
        let now = Date()
        let slots = PaletteFreeSlots.slots(busy: busy, now: now, days: 7, minutes: availability.minutes, hours: availability.hours)
        let chosen = availability.chosen
        var rows: [PaletteItem] = []
        let korean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        if !chosen.isEmpty {
            let preview = PaletteFreeSlots.text(chosen, korean: korean)
            var copy = screenRow("free.copy", "Copy \(chosen.count == 1 ? "This Time" : "These \(chosen.count) Times")", preview,
                                 icon: "doc.on.doc.fill", group: "Ready to paste",
                                 primary: PaletteAction(title: "Copy", symbol: "doc.on.doc") {
                                     Task { @MainActor in
                                         // Checked again right before copying: a meeting booked meanwhile drops out.
                                         await availability.load()
                                         // 7.13 (GPT F07): a failed read is not an empty calendar.
                                         guard !availability.readFailed, let fresh = availability.busy else {
                                             GestureHUD.shared.show(title: "Not Copied", detail: "Your calendars couldn't be read, so AOM can't tell whether those times are free.")
                                             sourcesChanged()
                                             return
                                         }
                                         let free = PaletteFreeSlots.stillFree(chosen, busy: fresh, now: Date())
                                         guard !free.isEmpty else {
                                             GestureHUD.shared.show(title: "Not Copied", detail: "Those times aren't free any more.")
                                             return
                                         }
                                         let text = PaletteFreeSlots.text(free, korean: korean)
                                         copyToClipboard(text, announce: free.count < chosen.count ? "\(text) — \(chosen.count - free.count) no longer free" : text)
                                     }
                                 })
            copy.placement = .pinned
            rows.append(copy)
        }
        let hours = availability.hours
        let window = String(format: "%02d:%02d–%02d:%02d", hours.start / 60, hours.start % 60, hours.end / 60, hours.end % 60)
        guard !slots.isEmpty else {
            rows.append(screenRow("free.none", "No free \(availability.minutes)-minute time in the next 7 days", "Weekdays \(window) · type 30 for a shorter meeting",
                                  icon: "calendar.badge.exclamationmark", group: nil,
                                  primary: PaletteAction(title: "OK", effect: .stay) {}, dimmed: true))
            return rows
        }
        for slot in slots.prefix(60) {
            let picked = chosen.contains(slot)
            var row = screenRow("free.\(Int(slot.start.timeIntervalSince1970))",
                                "\(PaletteSchedule.clock(slot.start))–\(PaletteSchedule.clock(slot.end))",
                                picked ? "Picked · ↩ to take it out" : "\(availability.minutes) min · ↩ to pick (up to \(PaletteAvailability.maxChosen))",
                                icon: "clock", group: PaletteSchedule.dayTitle(slot.start, now: now),
                                primary: PaletteAction(title: picked ? "Take Out" : "Pick", symbol: picked ? "minus.circle" : "plus.circle", effect: .stay) {
                                    if !availability.toggle(slot) { screens.show("Up to \(PaletteAvailability.maxChosen) times — take one out first") }
                                    sourcesChanged()
                                })
            row.checked = picked
            row.accessory = picked ? "✓" : nil
            rows.append(row)
        }
        return rows
    }
}
