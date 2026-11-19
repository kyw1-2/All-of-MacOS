import Foundation

/// What ⌘K learns from use, after Alfred's knowledge (the item picked for a
/// query comes first the next time that query is typed) and Raycast's root
/// search (items used often and lately rank higher, and lead an empty
/// palette as Suggestions). Item IDs and short queries only, on this Mac.
struct PaletteKnowledge: Codable, Equatable {
    struct Use: Codable, Equatable {
        /// Uses, decayed with a one-week half-life: the ranking weight.
        var score: Double
        var last: Date
        /// Plain number of picks: whether it is a habit at all (Codex D02:
        /// two picks a second apart decayed to 1.99999 and missed a floor of 2).
        var count: Int = 0

        enum CodingKeys: String, CodingKey { case score, last, count }

        init(score: Double, last: Date, count: Int) {
            self.score = score; self.last = last; self.count = count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            score = try c.decode(Double.self, forKey: .score)
            last = try c.decode(Date.self, forKey: .last)
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? Int(score.rounded(.up))
        }
    }

    /// Picks before a row becomes a suggestion, and how long since the last
    /// pick it still counts (a habit from a month ago is not one now).
    static let suggestionMinimumUses = 2
    static let suggestionWindow: TimeInterval = 30 * 86_400

    static let halfLife: TimeInterval = 7 * 86_400
    static let maxItems = 300
    static let maxQueries = 300

    private(set) var uses: [String: Use] = [:]
    /// Lowercased query → the item picked for it last.
    private(set) var picks: [String: String] = [:]
    // Older archives retained picks without their chronological order.
    private var queryOrder: [String]?

    /// Rows that change with the query or the moment (the calculator's
    /// answer, fallbacks, clipboard and capture rows, the latest file) and
    /// permission prompts teach nothing.
    static let unlearnablePrefixes = ["calculator", "fallback.", "files.search", "files.latest", "clipboard.",
                                      "capture.", "menu.permission", "bookmark.safari.permission"]

    static func isLearnable(_ id: String) -> Bool {
        !unlearnablePrefixes.contains { id.hasPrefix($0) }
    }

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func decayedScore(_ id: String, now: Date) -> Double {
        guard let use = uses[id] else { return 0 }
        return use.score * pow(0.5, max(0, now.timeIntervalSince(use.last)) / Self.halfLife)
    }

    mutating func record(itemID: String, query: String, now: Date = Date()) {
        guard Self.isLearnable(itemID) else { return }
        uses[itemID] = Use(score: decayedScore(itemID, now: now) + 1, last: now, count: (uses[itemID]?.count ?? 0) + 1)
        let key = Self.normalized(query)
        if uses.count > Self.maxItems {
            let oldest = uses.keys.filter { $0 != itemID }.min {
                let lhs = decayedScore($0, now: now), rhs = decayedScore($1, now: now)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            if let oldest { forget(oldest) }
        }
        if !key.isEmpty, key.count <= 40 {
            var order = queryOrder ?? picks.keys.sorted()
            order.removeAll { $0 == key }
            order.append(key)
            picks[key] = itemID
            if order.count > Self.maxQueries {
                picks.removeValue(forKey: order.removeFirst())
            }
            queryOrder = order
        }
    }

    /// The item last picked for exactly this query.
    func pick(for query: String) -> String? { picks[Self.normalized(query)] }

    /// Rows picked at least twice and within the last month, ranked by
    /// decayed use: one stray click never becomes a suggestion.
    func suggestions(among candidates: [String], limit: Int, now: Date = Date()) -> [String] {
        candidates.compactMap { id -> (String, Double)? in
            guard let use = uses[id], use.count >= Self.suggestionMinimumUses,
                  now.timeIntervalSince(use.last) <= Self.suggestionWindow else { return nil }
            return (id, decayedScore(id, now: now))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }

    mutating func forget(_ id: String) {
        uses.removeValue(forKey: id)
        picks = picks.filter { $0.value != id }
        let liveKeys = Set(picks.keys)
        queryOrder?.removeAll { !liveKeys.contains($0) }
    }
}

/// The stored knowledge, read once and saved after each pick.
@MainActor
final class PaletteKnowledgeStore {
    static let shared = PaletteKnowledgeStore()
    static let defaultsKey = "AOMPaletteKnowledge.v1"
    private(set) var knowledge: PaletteKnowledge
    /// Reads, saves and resets all go to the one store it was made with (Codex D03).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        knowledge = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(PaletteKnowledge.self, from: $0) } ?? PaletteKnowledge()
    }

    func record(itemID: String, query: String) {
        knowledge.record(itemID: itemID, query: query)
        save()
    }

    func forget(_ id: String) {
        knowledge.forget(id)
        save()
    }

    func reset() {
        knowledge = PaletteKnowledge()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(knowledge) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
