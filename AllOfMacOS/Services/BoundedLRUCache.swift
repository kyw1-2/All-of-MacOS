/// A small, caller-synchronized cache with deterministic count and cost bounds.
/// Hits update recency in O(1); only insertion at capacity scans for a victim.
/// Cost is supplied by the owner (decoded pixel bytes for image caches).
struct BoundedLRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var access: UInt64
    }

    let countLimit: Int
    let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var totalCost = 0
    var count: Int { entries.count }

    init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }

    subscript(key: Key) -> Value? {
        mutating get {
            guard var entry = entries[key] else { return nil }
            entry.access = nextAccess()
            entries[key] = entry
            return entry.value
        }
        set {
            if let newValue { insert(newValue, forKey: key) }
            else { removeValue(forKey: key) }
        }
    }

    mutating func insert(_ value: Value, forKey key: Key, cost: Int = 1) {
        // A changed value that no longer fits must not leave a stale value.
        removeValue(forKey: key)
        guard countLimit > 0, cost >= 0, cost <= costLimit else { return }
        // Subtract before adding to avoid overflow, even with Int.max costs.
        while entries.count >= countLimit || totalCost > costLimit - cost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            removeValue(forKey: oldest)
        }
        let access = nextAccess()
        entries[key] = Entry(value: value, cost: cost, access: access)
        totalCost += cost
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        totalCost -= removed.cost
        return removed.value
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
        clock = 0
    }

    private mutating func nextAccess() -> UInt64 {
        if clock == .max {
            let ordered = entries.sorted { $0.value.access < $1.value.access }.map(\.key)
            for (index, key) in ordered.enumerated() { entries[key]?.access = UInt64(index) }
            clock = UInt64(ordered.count)
        }
        clock += 1
        return clock
    }
}
