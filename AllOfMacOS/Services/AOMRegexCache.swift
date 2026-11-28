import Foundation

/// 7.24.1 (7.19 P1-1): compiled regular expressions, kept. Several hot paths
/// (trigger filters on every signal, Folder Rules on every file, workflow
/// conditions, the Quick Entry parser on every keystroke) compiled the same
/// pattern each call. Patterns are keyed with their options; at most 256 are
/// kept, and a pattern that doesn't compile is remembered as such.
enum AOMRegexCache {
    private struct Key: Hashable { let pattern: String; let options: UInt }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: NSRegularExpression?] = [:]

    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        lock.lock()
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = .some(compiled)
        lock.unlock()
        return compiled
    }

    static var count: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
}
