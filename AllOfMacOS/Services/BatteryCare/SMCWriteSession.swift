import Foundation

protocol SMCWriting {
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, value: SMCValue) throws
}

/// A root-owned write-ahead journal also covers a helper crash during a write.
/// Only keys owned by this narrowly scoped helper can be recovered.
final class SMCWriteSession {
    struct Entry: Codable {
        let original: SMCValue
        var written: [SMCValue]
    }
    private let smc: SMCWriting
    private let journal: URL
    private var entries: [String: Entry] = [:]
    static let keys: Set<String> = Set(["CH0B", "CH0C", "CHTE", "FS! "] +
        (0..<4).flatMap { ["F\($0)Md", "F\($0)Tg"] })

    init(smc: SMCWriting, journal: URL) throws {
        self.smc = smc
        self.journal = journal
        if FileManager.default.fileExists(atPath: journal.path) {
            entries = try PropertyListDecoder().decode([String: Entry].self, from: Data(contentsOf: journal))
            guard entries.count <= Self.keys.count,
                  entries.allSatisfy({ key, entry in
                      Self.keys.contains(key) && !entry.written.isEmpty && entry.written.count <= 3 &&
                      (1...4).contains(entry.original.bytes.count) &&
                      entry.written.allSatisfy { $0.type == entry.original.type && $0.bytes.count == entry.original.bytes.count }
                  }) else { throw HardwareControlError.unavailable("Invalid hardware recovery journal") }
            try restore()
        }
    }

    private func persist() throws {
        let data = try PropertyListEncoder().encode(entries)
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    func owns(_ key: String) -> Bool { entries[key] != nil }

    func write(_ key: String, _ value: SMCValue) throws {
        guard Self.keys.contains(key) else { throw HardwareControlError.unavailable("Hardware key is not permitted") }
        let current = try smc.read(key)
        guard current.type == value.type, current.bytes.count == value.bytes.count else {
            throw HardwareControlError.unavailable("Hardware format changed")
        }
        if let entry = entries[key], current != entry.original && !entry.written.contains(current) {
            throw HardwareControlError.unavailable("Another utility changed \(key); control stopped")
        }
        guard current != value else { return }
        var entry = entries[key] ?? Entry(original: current, written: [])
        // Keep both old and pending values until the new write is confirmed.
        entry.written = Array(SetValues.unique(entry.written + [value]).suffix(3))
        entries[key] = entry
        try persist()
        try smc.write(key, value: value)
        entries[key]?.written = [value]
        try persist()
    }

    func restore(keys: Set<String> = SMCWriteSession.keys) throws {
        var failures: [String] = []
        var relinquishedTargets = Set<String>()
        let selected = entries.keys.filter { keys.contains($0) }.sorted {
            func order(_ key: String) -> Int { key == "FS! " || key.hasSuffix("Md") ? 0 : 1 }
            return order($0) == order($1) ? $0 < $1 : order($0) < order($1)
        }
        for key in selected {
            guard let entry = entries[key] else { continue }
            if key.hasSuffix("Tg") {
                if relinquishedTargets.contains(key) { entries.removeValue(forKey: key); continue }
                let mode = String(key.prefix(2)) + "Md"
                // Never restore an automatic-mode target (possibly zero RPM)
                // until manual mode has been confirmed released.
                if entries[mode] != nil || entries["FS! "] != nil { failures.append(key); continue }
            }
            do {
                let current = try smc.read(key)
                if current != entry.original && !entry.written.contains(current) {
                    if key == "FS! " { relinquishedTargets.formUnion((0..<4).map { "F\($0)Tg" }) }
                    else if key.hasSuffix("Md") { relinquishedTargets.insert(String(key.prefix(2)) + "Tg") }
                }
                if current != entry.original && entry.written.contains(current) {
                    try smc.write(key, value: entry.original)
                }
                entries.removeValue(forKey: key)
            } catch { failures.append(key) }
        }
        try persist()
        if !failures.isEmpty { throw HardwareControlError.unavailable("Could not restore \(failures.joined(separator: ", ")); recovery will retry") }
    }
}

private enum SetValues {
    static func unique(_ values: [SMCValue]) -> [SMCValue] {
        values.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
