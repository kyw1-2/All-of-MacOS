import Foundation

// AOM 7.2 (Oracle report 05 §3-D, Alfred's previous queries): what was
// searched before comes back under "Recent searches" in the empty launcher.
// Picking one puts the text back in the field and shows its results — it
// never runs anything by itself.

struct PaletteRecentQueries: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var text: String
        var date: Date
    }

    static let limit = 30
    /// Older searches fade out after a week.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    private(set) var entries: [Entry] = []

    /// Whether `text` is worth keeping: 2–120 characters, not a lone
    /// keyword, and nothing that looks like a password or a token.
    static func isRecordable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(trimmed.count) else { return false }
        return !ClipboardSecretScanner.looksLikePassword(trimmed) && !ClipboardSecretScanner.containsSecret(inText: trimmed)
    }

    mutating func record(_ text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isRecordable(trimmed) else { return }
        entries.removeAll { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(Entry(text: trimmed, date: now), at: 0)
        entries = Array(entries.filter { now.timeIntervalSince($0.date) < Self.maxAge }.prefix(Self.limit))
    }

    /// The newest first, within the week.
    func recent(limit: Int, now: Date = Date()) -> [Entry] {
        Array(entries.filter { now.timeIntervalSince($0.date) < Self.maxAge }.prefix(limit))
    }

    mutating func remove(_ text: String) {
        entries.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
    }

    mutating func clear() { entries.removeAll() }

    /// 7.3 (7.2.1 audit B15): drops what is past a week, so an expired search
    /// doesn't stay in the stored preferences until the next one is recorded.
    @discardableResult
    mutating func pruneExpired(now: Date = Date()) -> Bool {
        let kept = entries.filter { now.timeIntervalSince($0.date) < Self.maxAge }
        guard kept.count != entries.count else { return false }
        entries = kept
        return true
    }
}

@MainActor
final class PaletteRecentQueryStore {
    static let shared = PaletteRecentQueryStore()
    static let key = "AOMLauncherRecentQueries"

    private(set) var value = PaletteRecentQueries()
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        // Tests and previews never touch the installed app's history.
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = (PresetManager.isRunningTests || PresetManager.isUIPreview) ? nil : .standard
        }
        if let data = self.defaults?.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(PaletteRecentQueries.self, from: data) {
            value = saved
            if value.pruneExpired() { save() }
        } else if PresetManager.isUIPreview {
            value.record("homepod")
            value.record("brew outdated")
            value.record("환율 1 usd")
        }
    }

    func record(_ text: String) { value.record(text); save() }
    func remove(_ text: String) { value.remove(text); save() }
    func clear() { value.clear(); save() }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
