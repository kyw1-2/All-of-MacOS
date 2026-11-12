import Foundation

/// A single owner-resolution sweep's lookup table. Negative results matter:
/// many audio helpers walk the same non-application ancestors. Never retain
/// this table across sweeps, where PIDs and activation policies can change.
final class AudioOwnerLookup<Value> {
    private var values: [pid_t: Value] = [:]
    private var missing = Set<pid_t>()
    private let load: (pid_t) -> Value?

    init(load: @escaping (pid_t) -> Value?) { self.load = load }

    func value(for pid: pid_t, orLoad read: (() -> Value?)? = nil) -> Value? {
        if let value = values[pid] { return value }
        if missing.contains(pid) { return nil }
        guard let value = (read ?? { self.load(pid) })() else {
            missing.insert(pid)
            return nil
        }
        values[pid] = value
        return value
    }
}
