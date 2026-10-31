import Darwin
import Foundation

// MARK: - Memory, stability and limits

/// What Folder Rules remembers between passes (state.json). Like Hazel, a
/// rule that ran on an item leaves it alone afterwards, unless the rule's
/// conditions change or the item stops matching and later matches again.
struct FolderRuleMemory: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var signature: String
        /// The rule ran successfully, or the person chose Skip.
        var handled: Bool
        var failures: Int
        var lastSeen: Date
    }

    /// A rule stops retrying an item after this many failed runs in a row
    /// (until the item or the rule changes).
    static let maxFailures = 3
    /// Entries for items not seen for this long are dropped.
    static let retention: TimeInterval = 30 * 86_400

    var entries: [String: Entry] = [:]
    /// The next `{counter}` per rule.
    var counters: [String: Int] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case entries, counters }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent([String: Entry].self, forKey: .entries)) ?? [:]
        counters = (try? c.decodeIfPresent([String: Int].self, forKey: .counters)) ?? [:]
    }

    /// The item's identity: volume, inode and creation date, so a rename or
    /// a move keeps it and a new file with a reused inode doesn't inherit it.
    static func key(rule: UUID, device: UInt64, inode: UInt64, created: Date?) -> String {
        "\(rule.uuidString)|\(device)|\(inode)|\(Int((created ?? .distantPast).timeIntervalSince1970))"
    }

    static func key(rule: UUID, _ info: FolderRuleFileInfo) -> String {
        key(rule: rule, device: info.device, inode: info.inode, created: info.dateCreated)
    }

    /// The rule is done with the item: handled, or out of retries.
    func isSettled(_ key: String, signature: String) -> Bool {
        guard let entry = entries[key], entry.signature == signature else { return false }
        return entry.handled || entry.failures >= Self.maxFailures
    }

    mutating func markHandled(_ key: String, signature: String, now: Date) {
        entries[key] = Entry(signature: signature, handled: true, failures: 0, lastSeen: now)
    }

    mutating func markFailed(_ key: String, signature: String, now: Date) {
        var entry = entries[key].flatMap { $0.signature == signature ? $0 : nil }
            ?? Entry(signature: signature, handled: false, failures: 0, lastSeen: now)
        entry.handled = false
        entry.failures += 1
        entry.lastSeen = now
        entries[key] = entry
    }

    mutating func touch(_ key: String, now: Date) { entries[key]?.lastSeen = now }

    /// The item no longer matches the rule: if it matches again later, the rule runs again.
    mutating func forget(_ key: String) { entries.removeValue(forKey: key) }

    mutating func prune(now: Date, ruleIDs: Set<UUID>) {
        let live = Set(ruleIDs.map(\.uuidString))
        entries = entries.filter { key, entry in
            guard let rule = key.split(separator: "|").first, live.contains(String(rule)) else { return false }
            return now.timeIntervalSince(entry.lastSeen) < Self.retention
        }
        counters = counters.filter { live.contains($0.key) }
    }

    func counter(for rule: UUID) -> Int { max(1, counters[rule.uuidString] ?? 1) }
    mutating func advanceCounter(for rule: UUID) { counters[rule.uuidString] = counter(for: rule) + 1 }
}

/// Waits until an item stops changing: a file being written (a download, a
/// copy) keeps its modification time fresh and its size growing.
struct FolderRuleStability {
    struct Observation: Equatable {
        var size: Int64
        var modified: Date?
        var since: Date
    }

    /// No write for this long before an item counts.
    static let quietPeriod: TimeInterval = 3
    /// Two looks this far apart must see the same size.
    static let settleInterval: TimeInterval = 2
    /// Untouched this long: not being written, no second look needed.
    static let settledAge: TimeInterval = 60

    private(set) var observations: [String: Observation] = [:]

    mutating func isStable(_ info: FolderRuleFileInfo, now: Date) -> Bool {
        let path = info.url.path
        let age = info.dateModified.map { now.timeIntervalSince($0) } ?? .infinity
        if age >= Self.settledAge {
            observations.removeValue(forKey: path)
            return true
        }
        let current = Observation(size: info.size, modified: info.dateModified, since: now)
        guard age >= Self.quietPeriod else {
            observations[path] = current
            return false
        }
        if let previous = observations[path], previous.size == info.size, previous.modified == info.dateModified {
            return now.timeIntervalSince(previous.since) >= Self.settleInterval
        }
        observations[path] = current
        return false
    }

    mutating func prune(keeping paths: Set<String>) {
        observations = observations.filter { paths.contains($0.key) }
    }
}

/// Rate limits and the loop guard.
struct FolderRuleRateLimiter {
    /// A rule acts on at most this many items a minute; the rest wait.
    static let perMinute = 120
    /// A rule that acts on items Folder Rules itself just made this many
    /// times within `loopWindow` is in a loop and gets turned off.
    static let loopLimit = 20
    static let loopWindow: TimeInterval = 600

    private var runs: [UUID: [Date]] = [:]
    private var runsOnProduced: [UUID: [Date]] = [:]
    private var produced: [String: Date] = [:]

    mutating func allows(_ rule: UUID, now: Date) -> Bool {
        let recent = (runs[rule] ?? []).filter { now.timeIntervalSince($0) < 60 }
        runs[rule] = recent
        return recent.count < Self.perMinute
    }

    /// Records a run; true when the rule just tripped the loop guard.
    mutating func record(_ rule: UUID, now: Date, onProducedItem: Bool) -> Bool {
        runs[rule, default: []].append(now)
        guard onProducedItem else { return false }
        var recent = (runsOnProduced[rule] ?? []).filter { now.timeIntervalSince($0) < Self.loopWindow }
        recent.append(now)
        runsOnProduced[rule] = recent
        return recent.count >= Self.loopLimit
    }

    mutating func noteProduced(device: UInt64, inode: UInt64, now: Date) {
        produced = produced.filter { now.timeIntervalSince($0.value) < Self.loopWindow }
        produced["\(device)|\(inode)"] = now
    }

    func isProduced(_ info: FolderRuleFileInfo, now: Date) -> Bool {
        guard let made = produced["\(info.device)|\(info.inode)"] else { return false }
        return now.timeIntervalSince(made) < Self.loopWindow
    }

    mutating func reset(_ rule: UUID) {
        runs.removeValue(forKey: rule)
        runsOnProduced.removeValue(forKey: rule)
    }
}

// MARK: - Results

enum FolderRuleFolderState: Equatable {
    case ok(items: Int)
    case denied
    case missing
    case unreadable(String)

    var problem: String? {
        switch self {
        case .ok: return nil
        case .denied: return "macOS doesn't let All of MacOS read this folder."
        case .missing: return "The folder is missing."
        case .unreadable(let message): return message
        }
    }
}

/// An item a rule wants to change, waiting for the person's OK.
struct FolderRuleApprovalRequest: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let ruleID: UUID
    let folderID: UUID
    let info: FolderRuleFileInfo
}

/// One finished run, ready for the activity log.
struct FolderRuleRunRecord: Equatable {
    let ruleID: UUID
    let ruleName: String
    let folderID: UUID
    let folderName: String
    let fileName: String
    let originalPath: String
    let outcome: FolderRuleRunOutcome
}

struct FolderRulePassOutput: Equatable {
    var runs: [FolderRuleRunRecord] = []
    var approvals: [FolderRuleApprovalRequest] = []
    var folderStates: [UUID: FolderRuleFolderState] = [:]
    /// Run again this soon: items still changing, or a rate limit.
    var recheckAfter: TimeInterval?
    /// Rules the loop guard stopped, with the reason.
    var stoppedRules: [UUID: String] = [:]
    var consumedGrants: Set<String> = []
    /// Show Notification texts per rule, posted once per pass.
    var notifications: [UUID: [String]] = [:]

    mutating func recheck(_ seconds: TimeInterval) {
        recheckAfter = min(recheckAfter ?? seconds, seconds)
    }
}

// MARK: - Preview

struct FolderRulePreviewItem: Identifiable, Equatable {
    enum State: Equatable {
        case willRun
        /// Still downloading or being written.
        case waiting
        /// The rule already ran on it.
        case handled
        /// An earlier rule in the folder takes it first.
        case earlierRule(String)
        /// The rule's conditions don't match (testing one file).
        case noMatch
    }

    var id: String
    var info: FolderRuleFileInfo
    var state: State
    /// What each action would do ("Move to ~/Pictures/Screenshots/2026-10").
    var steps: [String]
    /// The verdict of each condition, in order (✓ / ✗ in the inspector).
    var conditionResults: [Bool]
}

struct FolderRulePreview: Equatable {
    var ruleID: UUID
    var folderState: FolderRuleFolderState
    var items: [FolderRulePreviewItem]
    /// Unfinished downloads (.crdownload, .download, .part …) left alone.
    var inProgress: Int
    var scanned: Int

    var willRun: [FolderRulePreviewItem] { items.filter { $0.state == .willRun } }
}

/// Describes what an action would do, without doing it (the dry run).
enum FolderRulePlanDescriber {
    static func describe(_ rule: FolderRule, info: FolderRuleFileInfo, now: Date, counter: Int) -> [String] {
        var simulated = info
        var lines: [String] = []
        for action in rule.actions {
            let context = FolderRulePatterns.Context(info: simulated, now: now, counter: counter)
            lines.append(describe(action, context: context))
            switch action.kind {
            case .move, .copy:
                var folder = URL(fileURLWithPath: (action.folderPath as NSString).expandingTildeInPath, isDirectory: true)
                for component in FolderRulePatterns.subfolderComponents(action.subfolderPattern, context) {
                    folder.appendPathComponent(component, isDirectory: true)
                }
                simulated.url = folder.appendingPathComponent(simulated.name)
            case .rename:
                if let name = FolderRulePatterns.fileName(action.pattern, context) {
                    simulated.name = name
                    simulated.url = simulated.url.deletingLastPathComponent().appendingPathComponent(name)
                }
            case .compress:
                simulated.name += ".zip"
                simulated.url = simulated.url.deletingLastPathComponent().appendingPathComponent(simulated.name)
                simulated.contentType = "public.zip-archive"
            case .optimizeImage:
                if info.isScreenCapture, FolderRulesImageOptimizer.Format.of(simulated.contentType) == .png,
                   action.image.screenshotOutput != .keep {
                    let format: FolderRulesImageOptimizer.Format = action.image.screenshotOutput == .jpeg ? .jpeg : .heic
                    simulated.name = "\(simulated.baseName).\(format.fileExtension)"
                    simulated.contentType = format.type.identifier
                }
            default:
                break
            }
            if action.kind.endsChain { break }
        }
        return lines
    }

    static func describe(_ action: FolderRuleAction, context: FolderRulePatterns.Context) -> String {
        switch action.kind {
        case .move, .copy:
            var folder = URL(fileURLWithPath: (action.folderPath as NSString).expandingTildeInPath, isDirectory: true)
            for component in FolderRulePatterns.subfolderComponents(action.subfolderPattern, context) {
                folder.appendPathComponent(component, isDirectory: true)
            }
            return "\(action.kind == .move ? "Move" : "Copy") to \(FolderRulesSafety.display(folder))"
        case .rename:
            guard let name = FolderRulePatterns.fileName(action.pattern, context) else { return "Rename (the pattern leaves no name)" }
            return "Rename to “\(name)”"
        case .addTags:
            let tags = action.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "Add \(tags.count == 1 ? "the tag" : "the tags") \(tags.map { "“\($0)”" }.joined(separator: ", "))"
        case .setColorLabel:
            return action.colorLabel == .none ? "Remove the color label" : "Set the \(action.colorLabel.title.lowercased()) label"
        case .moveToTrash:
            return "Move to the Trash"
        case .compress:
            return "Compress to “\(context.info.name).zip”" + (action.trashOriginal ? ", then move the original to the Trash" : "")
        case .extract:
            return "Extract the archive" + (action.trashOriginal ? ", then move it to the Trash" : "")
        case .optimizeImage:
            var parts: [String] = []
            if action.image.maxDimension > 0 { parts.append("longest side at most \(action.image.maxDimension) px") }
            parts.append("quality \(Int((action.image.clampedQuality * 100).rounded()))%")
            if action.image.stripLocation { parts.append("no location") }
            if action.image.screenshotOutput != .keep, context.info.isScreenCapture,
               FolderRulesImageOptimizer.Format.of(context.info.contentType) == .png {
                parts.append("as \(action.image.screenshotOutput.title)")
            }
            let original = action.image.original == .trash ? "original to the Trash" : "overwrite"
            return "Optimize (\(parts.joined(separator: ", ")); \(original))"
        case .installApp:
            return "Install the app" + (action.install.trashDiskImage ? ", then move the disk image to the Trash" : "")
        case .openWith:
            if action.appPath.isEmpty { return "Open with the default app" }
            return "Open with \(URL(fileURLWithPath: action.appPath).deletingPathExtension().lastPathComponent)"
        case .notify:
            let text = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Show “\(text.isEmpty ? context.info.name : FolderRulePatterns.expand(text, context))”"
        case .runAutomation:
            return action.automationName.isEmpty ? "Run an automation" : "Run “\(action.automationName)”"
        case .runShortcut:
            return "Run the “\(action.shortcutName.trimmingCharacters(in: .whitespaces))” shortcut"
        }
    }
}

// MARK: - Runner

/// Runs passes, approved runs, previews and undo on one serial queue, and
/// owns what is remembered between them. Every method here is synchronous
/// and expects to be on `queue` (the engine dispatches; tests call directly),
/// which is what makes the unchecked Sendable conformance hold.
final class FolderRulesRunner: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.kyw.allofmacos.folder-rules", qos: .utility)
    var environment: FolderRulesEnvironment
    private(set) var memory: FolderRuleMemory
    private var stability = FolderRuleStability()
    private var limiter = FolderRuleRateLimiter()
    /// At most this many runs per pass, so one pass never holds the queue long.
    static let maxRunsPerPass = 200

    init(environment: FolderRulesEnvironment, memory: FolderRuleMemory = FolderRuleMemory()) {
        self.environment = environment
        self.memory = memory
    }

    private var executor: FolderRuleExecutor { FolderRuleExecutor(environment: environment) }

    struct PassInput {
        var config: FolderRulesConfig
        /// Only these folders; nil for all.
        var folderIDs: Set<UUID>?
        /// Items already waiting for approval.
        var pending: Set<String> = []
        /// Items the person approved in advance (Turn On after the preview).
        var granted: Set<String> = []
    }

    /// One pass over the watched folders: each item goes to the first rule
    /// that matches it and hasn't handled it yet (Hazel's order).
    func pass(_ input: PassInput) -> FolderRulePassOutput {
        var output = FolderRulePassOutput()
        let now = environment.now()
        var seenPaths: Set<String> = []
        var runsThisPass = 0
        for folder in input.config.folders where input.folderIDs?.contains(folder.id) ?? true {
            let rules = input.config.rules(in: folder.id).filter { $0.isEnabled && $0.problems.isEmpty }
            guard !rules.isEmpty else { continue }
            let listing = FolderRuleFileReader.list(folder.url, includeSubfolders: rules.contains(where: \.includeSubfolders))
            let entries: [(url: URL, depth: Int)]
            switch listing {
            case .failure(let error):
                output.folderStates[folder.id] = Self.state(error)
                continue
            case .success(let found):
                entries = found
                output.folderStates[folder.id] = .ok(items: found.count)
            }
            let sizes = rules.contains { $0.conditions.contains { $0.attribute == .size } }
            for entry in entries {
                guard let info = FolderRuleFileReader.read(entry.url, depth: entry.depth, directorySizes: sizes) else { continue }
                seenPaths.insert(info.url.path)
                guard stability.isStable(info, now: now) else {
                    output.recheck(FolderRuleStability.quietPeriod + 0.5)
                    continue
                }
                for rule in rules {
                    let key = FolderRuleMemory.key(rule: rule.id, info)
                    guard FolderRuleMatcher.matches(rule, info, now: now) else {
                        memory.forget(key)
                        continue
                    }
                    memory.touch(key, now: now)
                    if memory.isSettled(key, signature: rule.conditionSignature) { continue }
                    if input.pending.contains(key) { break }
                    if rule.needsApproval, !input.granted.contains(key) {
                        output.approvals.append(FolderRuleApprovalRequest(key: key, ruleID: rule.id, folderID: folder.id, info: info))
                        break
                    }
                    guard runsThisPass < Self.maxRunsPerPass, limiter.allows(rule.id, now: now) else {
                        output.recheck(runsThisPass >= Self.maxRunsPerPass ? 1 : 15)
                        break
                    }
                    runsThisPass += 1
                    if input.granted.contains(key) { output.consumedGrants.insert(key) }
                    run(rule, info: info, key: key, folder: folder, now: now, into: &output)
                    break
                }
            }
        }
        stability.prune(keeping: seenPaths)
        memory.prune(now: now, ruleIDs: Set(input.config.rules.map(\.id)))
        return output
    }

    /// Runs the items the person approved, if they still match.
    func runApproved(_ requests: [FolderRuleApprovalRequest], config: FolderRulesConfig) -> FolderRulePassOutput {
        var output = FolderRulePassOutput()
        let now = environment.now()
        for request in requests {
            guard let rule = config.rules.first(where: { $0.id == request.ruleID }),
                  let folder = config.folder(request.folderID),
                  let info = FolderRuleFileReader.read(request.info.url, depth: request.info.depth,
                                                       directorySizes: rule.conditions.contains { $0.attribute == .size }),
                  FolderRuleMatcher.matches(rule, info, now: now) else { continue }
            let key = FolderRuleMemory.key(rule: rule.id, info)
            guard !memory.isSettled(key, signature: rule.conditionSignature) else { continue }
            run(rule, info: info, key: key, folder: folder, now: now, into: &output)
        }
        return output
    }

    /// The manual "Install Disk Image…": no folder rule, the person chose the file.
    func installManually(_ image: URL, options: FolderRuleInstallOptions) -> FolderRuleRunOutcome {
        var outcome = FolderRuleRunOutcome(finalURL: image)
        do {
            let info = FolderRuleFileReader.read(image) ?? FolderRuleFileInfo(url: image)
            let step = try FolderRulesDiskImageInstaller.install(info.url, options: options, environment: environment, interactive: true)
            outcome.steps.append(step.record)
            outcome.finalURL = step.next
            if let produced = step.produced { outcome.produced.append(produced) }
        } catch {
            outcome.failed = true
            outcome.steps.append(FolderRuleStepRecord(action: .installApp, result: .failed,
                                                      summary: FolderRuleFailure.wrapping(error, "The install failed.").message))
        }
        return outcome
    }

    private func run(_ rule: FolderRule, info: FolderRuleFileInfo, key: String, folder: FolderRuleFolder, now: Date,
                     into output: inout FolderRulePassOutput) {
        let onProduced = limiter.isProduced(info, now: now)
        let outcome = executor.run(rule, on: info, in: folder.url, counter: memory.counter(for: rule.id))
        if outcome.failed {
            memory.markFailed(key, signature: rule.conditionSignature, now: now)
        } else {
            memory.markHandled(key, signature: rule.conditionSignature, now: now)
            if outcome.usedCounter { memory.advanceCounter(for: rule.id) }
        }
        for made in outcome.produced {
            guard let produced = FolderRuleFileReader.read(made) else { continue }
            limiter.noteProduced(device: produced.device, inode: produced.inode, now: now)
            memory.markHandled(FolderRuleMemory.key(rule: rule.id, produced), signature: rule.conditionSignature, now: now)
        }
        if limiter.record(rule.id, now: now, onProducedItem: onProduced) {
            output.stoppedRules[rule.id] = "it kept acting on files Folder Rules had just made (\(FolderRuleRateLimiter.loopLimit) times in \(Int(FolderRuleRateLimiter.loopWindow / 60)) minutes), which looks like a loop"
            limiter.reset(rule.id)
        }
        if !outcome.notifications.isEmpty { output.notifications[rule.id, default: []].append(contentsOf: outcome.notifications) }
        output.runs.append(FolderRuleRunRecord(ruleID: rule.id, ruleName: rule.name, folderID: folder.id, folderName: folder.name,
                                               fileName: info.name, originalPath: info.url.path, outcome: outcome))
    }

    /// The person chose Skip: those items count as handled by their rule.
    func markSkipped(_ requests: [FolderRuleApprovalRequest], config: FolderRulesConfig) {
        let now = environment.now()
        for request in requests {
            guard let rule = config.rules.first(where: { $0.id == request.ruleID }) else { continue }
            memory.markHandled(request.key, signature: rule.conditionSignature, now: now)
        }
    }

    /// Forgets what a rule did, so it runs on everything that matches again.
    func forget(rule: UUID) {
        memory.entries = memory.entries.filter { !$0.key.hasPrefix(rule.uuidString + "|") }
        limiter.reset(rule)
    }

    func undo(_ steps: [FolderRuleStepRecord]) -> (steps: [FolderRuleStepRecord], failure: String?) {
        executor.undo(steps)
    }

    /// The dry run: what `rule` would do now in its folder, as if it were on,
    /// with the folder's other rules in their order. Nothing is changed.
    func preview(_ rule: FolderRule, config: FolderRulesConfig) -> FolderRulePreview {
        let now = environment.now()
        guard let folder = config.folder(rule.folderID) else {
            return FolderRulePreview(ruleID: rule.id, folderState: .missing, items: [], inProgress: 0, scanned: 0)
        }
        var ordered = config.rules(in: folder.id).filter { $0.isEnabled || $0.id == rule.id }
        if let index = ordered.firstIndex(where: { $0.id == rule.id }) { ordered[index] = rule } else { ordered.append(rule) }
        let listing = FolderRuleFileReader.list(folder.url, includeSubfolders: rule.includeSubfolders)
        guard case .success(let entries) = listing else {
            if case .failure(let error) = listing {
                return FolderRulePreview(ruleID: rule.id, folderState: Self.state(error), items: [], inProgress: 0, scanned: 0)
            }
            return FolderRulePreview(ruleID: rule.id, folderState: .missing, items: [], inProgress: 0, scanned: 0)
        }
        var items: [FolderRulePreviewItem] = []
        var inProgress = 0
        let sizes = rule.conditions.contains { $0.attribute == .size }
        for entry in entries {
            if FolderRuleFileReader.isInProgressName(entry.url.lastPathComponent) { inProgress += 1; continue }
            guard let info = FolderRuleFileReader.read(entry.url, depth: entry.depth, directorySizes: sizes),
                  FolderRuleMatcher.matches(rule, info, now: now) else { continue }
            let key = FolderRuleMemory.key(rule: rule.id, info)
            var state = FolderRulePreviewItem.State.willRun
            for earlier in ordered.prefix(while: { $0.id != rule.id }) where earlier.problems.isEmpty {
                let earlierKey = FolderRuleMemory.key(rule: earlier.id, info)
                if FolderRuleMatcher.matches(earlier, info, now: now),
                   !memory.isSettled(earlierKey, signature: earlier.conditionSignature) {
                    state = .earlierRule(earlier.name)
                    break
                }
            }
            if state == .willRun {
                if memory.isSettled(key, signature: rule.conditionSignature) {
                    state = .handled
                } else if let modified = info.dateModified, now.timeIntervalSince(modified) < FolderRuleStability.quietPeriod {
                    state = .waiting
                }
            }
            items.append(FolderRulePreviewItem(id: key, info: info, state: state,
                                               steps: FolderRulePlanDescriber.describe(rule, info: info, now: now,
                                                                                      counter: memory.counter(for: rule.id)),
                                               conditionResults: FolderRuleMatcher.evaluate(rule, info, now: now)))
        }
        return FolderRulePreview(ruleID: rule.id, folderState: .ok(items: entries.count), items: items,
                                 inProgress: inProgress, scanned: entries.count)
    }

    /// One file against one rule (the inspector's "Test a file").
    func test(_ rule: FolderRule, file: URL) -> FolderRulePreviewItem? {
        let now = environment.now()
        guard let info = FolderRuleFileReader.read(file, directorySizes: rule.conditions.contains { $0.attribute == .size }) else {
            return nil
        }
        let matches = FolderRuleMatcher.matches(rule, info, now: now)
        return FolderRulePreviewItem(id: FolderRuleMemory.key(rule: rule.id, info), info: info,
                                     state: matches ? .willRun : .noMatch,
                                     steps: matches ? FolderRulePlanDescriber.describe(rule, info: info, now: now,
                                                                                      counter: memory.counter(for: rule.id)) : [],
                                     conditionResults: FolderRuleMatcher.evaluate(rule, info, now: now))
    }

    static func state(_ error: FolderRuleFileReader.ListingError) -> FolderRuleFolderState {
        switch error {
        case .denied: return .denied
        case .missing: return .missing
        case .unreadable(let message): return .unreadable(message)
        }
    }
}
