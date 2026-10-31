import Foundation

/// One thing Focus did on its own (or failed to do): hid or quit an app,
/// quit one under memory pressure, ran a shortcut. Shown on the Focus page
/// as live log rows, kept in Application Support/AllOfMacOS/Focus/activity.json.
struct FocusActivity: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case hid, quit, quitUnderPressure, quitRequested, quitDeclined, failed, shortcut, shortcutFailed
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var appName: String
    var bundleID: String?
    var idleSeconds: TimeInterval?
    /// The app's footprint (with its child processes) when it was quit.
    var memoryBytes: UInt64?
    var note: String?

    init(id: UUID = UUID(), date: Date, kind: Kind, appName: String, bundleID: String? = nil,
         idleSeconds: TimeInterval? = nil, memoryBytes: UInt64? = nil, note: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.appName = appName
        self.bundleID = bundleID
        self.idleSeconds = idleSeconds
        self.memoryBytes = memoryBytes
        self.note = note
    }

    /// Sentence case, past tense (design b.13).
    var message: String {
        switch kind {
        case .hid: return "Hid \(appName)"
        case .quit: return "Quit \(appName)"
        case .quitUnderPressure: return "Quit \(appName) to free memory"
        case .quitRequested: return "Asked \(appName) to quit"
        case .quitDeclined: return "\(appName) is still open"
        case .failed: return "Couldn't hide or quit \(appName)"
        case .shortcut: return "Ran \(appName)"
        case .shortcutFailed: return "Couldn't run \(appName)"
        }
    }

    var detail: String? {
        var parts: [String] = []
        if let idleSeconds { parts.append("Idle \(FocusDurationFormat.short(idleSeconds))") }
        if let memoryBytes, memoryBytes > 0 { parts.append(FocusByteFormat.string(memoryBytes)) }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var tone: AOMTone {
        switch kind {
        case .hid, .quit, .shortcut: return .success
        case .quitUnderPressure, .quitRequested: return .info
        case .quitDeclined: return .warning
        case .failed, .shortcutFailed: return .danger
        }
    }

    var logEntry: AOMLogEntry {
        AOMLogEntry(id: id, date: date, tone: tone, message: message, detail: detail, source: nil)
    }

    /// Memory this entry freed: the footprint of an app that really quit.
    var freedBytes: UInt64 {
        (kind == .quit || kind == .quitUnderPressure) ? (memoryBytes ?? 0) : 0
    }
}

@MainActor
final class FocusActivityStore: ObservableObject {
    static let fileName = "activity.json"
    static let limit = 200

    @Published private(set) var items: [FocusActivity] = []
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        items = FocusStorage.load([FocusActivity].self, named: Self.fileName, in: directory) ?? []
    }

    /// Newest first.
    func add(_ activity: FocusActivity) {
        items.insert(activity, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        FocusStorage.save(items, named: Self.fileName, in: directory)
    }

    func clear() {
        items.removeAll()
        FocusStorage.save(items, named: Self.fileName, in: directory)
    }

    func replace(with items: [FocusActivity]) {
        self.items = items.sorted { $0.date > $1.date }
        FocusStorage.save(self.items, named: Self.fileName, in: directory)
    }

    /// Memory freed by quits that finished today.
    func freedToday(now: Date = Date(), calendar: Calendar = .current) -> UInt64 {
        items.filter { calendar.isDate($0.date, inSameDayAs: now) }.reduce(0) { $0 + $1.freedBytes }
    }
}
