import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Why a step failed, in the words the activity log shows.
struct FolderRuleFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }

    static func wrapping(_ error: Error, _ fallback: String) -> FolderRuleFailure {
        if let failure = error as? FolderRuleFailure { return failure }
        let text = (error as NSError).localizedDescription
        return FolderRuleFailure(text.isEmpty ? fallback : text)
    }
}

/// How to reverse one step. Moves, renames and the Trash keep where the item
/// went, and undo moves it back (the Trash too: Put Back is a move).
enum FolderRuleUndo: Codable, Equatable {
    /// The item is now at `current`; undo moves it back to `original`.
    case moveBack(current: String, original: String)
    /// Optimize Image put the original in the Trash: undo moves the
    /// optimized file to the Trash and the original back.
    case restoreOriginal(trashed: String, original: String, replacement: String)
}

/// One step of one rule run, as the activity log keeps it.
struct FolderRuleStepRecord: Codable, Equatable {
    enum Result: String, Codable { case done, skipped, failed }

    var action: FolderRuleActionKind
    var result: Result
    var summary: String
    var undo: FolderRuleUndo?
    var undone = false

    init(action: FolderRuleActionKind, result: Result, summary: String, undo: FolderRuleUndo? = nil) {
        self.action = action
        self.result = result
        self.summary = summary
        self.undo = undo
    }

    enum CodingKeys: String, CodingKey { case action, result, summary, undo, undone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(FolderRuleActionKind.self, forKey: .action)
        result = (try? c.decodeIfPresent(Result.self, forKey: .result)) ?? .done
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        undo = try? c.decodeIfPresent(FolderRuleUndo.self, forKey: .undo)
        undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
    }

    var canUndo: Bool { undo != nil && !undone && result == .done }
}

/// What one rule did to one item.
struct FolderRuleRunOutcome: Equatable {
    var steps: [FolderRuleStepRecord] = []
    /// Where the item ended up; nil once it went to the Trash.
    var finalURL: URL?
    var failed = false
    /// New items the run created (copies, archives, optimized images): the
    /// same rule never acts on them, which keeps a rule out of loops.
    var produced: [URL] = []
    var usedCounter = false
    /// Show Notification texts, posted once per pass and rule.
    var notifications: [String] = []
    /// The step's failure, when `failed`.
    var failure: String? { steps.last(where: { $0.result == .failed })?.summary }
}

enum FolderRuleReplaceChoice: Equatable { case replace, keepBoth, cancel }

/// Everything a run touches outside the file system calls it makes itself,
/// so the tests swap in a temporary Trash and fake helpers and never touch
/// the real system.
struct FolderRulesEnvironment {
    var now: () -> Date = Date.init
    /// Moves an item to the Trash and returns where it went.
    var trash: (URL) throws -> URL
    /// Runs ditto, hdiutil or shortcuts.
    var run: (FolderRulesProcess.Request) -> FolderRulesProcess.Result
    var applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    /// Opens a file, with an app or the default one.
    var open: (_ file: URL, _ app: URL?) -> Bool
    var runAutomation: (_ id: UUID, _ name: String, _ file: URL) -> Result<Void, FolderRuleFailure>
    var isAppRunning: (URL) -> Bool
    /// "Replace “X” in Applications?" Replace, Keep Both or Cancel.
    var confirmReplace: (_ appName: String) -> FolderRuleReplaceChoice
    /// Several apps in one disk image: the manual install asks which one;
    /// rules get nil (they never guess).
    var chooseApp: ([URL]) -> URL?
    /// Copies into a folder the user can't write to, through the standard
    /// administrator prompt. Nil means success.
    var copyAsAdministrator: (_ source: URL, _ destination: URL) -> FolderRuleFailure?
}

extension FolderRulesEnvironment {
    /// The real system: the Finder Trash, real helpers, NSWorkspace, the
    /// Automation engine and alerts on the main thread.
    static var live: FolderRulesEnvironment {
        FolderRulesEnvironment(
            trash: { url in
                // An isolated UI preview works on sample files: its "Trash"
                // is a folder inside the preview's data folder.
                if let root = FolderRulesLocations.sampleRoot {
                    let trash = root.appendingPathComponent("Trash", isDirectory: true)
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    let place = FolderRulePatterns.uniqueURL(trash.appendingPathComponent(url.lastPathComponent)) {
                        FolderRulesSafety.exists($0.path)
                    }
                    try FileManager.default.moveItem(at: url, to: place)
                    return place
                }
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                guard let place = resulting as URL? else { throw FolderRuleFailure("macOS didn't say where “\(url.lastPathComponent)” went in the Trash.") }
                return place
            },
            run: FolderRulesProcess.run,
            open: { file, app in FolderRulesLive.open(file, with: app) },
            runAutomation: { id, name, file in FolderRulesLive.runAutomation(id: id, name: name, file: file) },
            isAppRunning: { url in FolderRulesLive.isRunning(url) },
            confirmReplace: { name in FolderRulesLive.confirmReplace(name) },
            chooseApp: { _ in nil },
            copyAsAdministrator: { source, destination in FolderRulesLive.copyAsAdministrator(source, destination) })
    }
}

/// Runs a rule's actions on one item, in order. Blocking and synchronous:
/// the engine calls it on its own serial queue, the tests call it directly.
struct FolderRuleExecutor {
    var environment: FolderRulesEnvironment
    private let fileManager = FileManager.default

    init(environment: FolderRulesEnvironment) { self.environment = environment }

    struct Step {
        var record: FolderRuleStepRecord
        /// The item the next action works on (a copy, an archive, the renamed file).
        var next: URL?
        var produced: URL?
        var usedCounter = false
        var notification: String?
    }

    /// Runs every action until one fails (Hazel: later actions don't run,
    /// and the next pass tries again). `folder` is the watched folder: an
    /// item outside it is never touched.
    func run(_ rule: FolderRule, on info: FolderRuleFileInfo, in folder: URL, counter: Int = 1,
             interactive: Bool = false) -> FolderRuleRunOutcome {
        var outcome = FolderRuleRunOutcome(finalURL: info.url)
        guard FolderRulesSafety.isInside(info.url, folder) else {
            outcome.failed = true
            outcome.steps.append(FolderRuleStepRecord(action: rule.actions.first?.kind ?? .move, result: .failed,
                                                      summary: "Skipped: “\(info.name)” isn't inside \(FolderRulesSafety.display(folder))."))
            return outcome
        }
        guard FolderRulesSafety.exists(info.url.path) else {
            outcome.failed = true
            outcome.steps.append(FolderRuleStepRecord(action: rule.actions.first?.kind ?? .move, result: .failed,
                                                      summary: "“\(info.name)” is no longer in \(FolderRulesSafety.display(folder))."))
            return outcome
        }
        var current = info.url
        var currentInfo = info
        for action in rule.actions {
            do {
                let step = try perform(action, item: current, info: currentInfo, counter: counter, interactive: interactive)
                outcome.steps.append(step.record)
                if let produced = step.produced { outcome.produced.append(produced) }
                if step.usedCounter { outcome.usedCounter = true }
                if let note = step.notification { outcome.notifications.append(note) }
                guard let next = step.next else { outcome.finalURL = nil; break }
                if next != current {
                    current = next
                    var refreshed = FolderRuleFileReader.read(next, depth: currentInfo.depth) ?? currentInfo
                    refreshed.url = next
                    refreshed.name = next.lastPathComponent
                    currentInfo = refreshed
                }
                outcome.finalURL = current
            } catch {
                let failure = FolderRuleFailure.wrapping(error, "\(action.kind.title) failed.")
                outcome.steps.append(FolderRuleStepRecord(action: action.kind, result: .failed, summary: failure.message))
                outcome.failed = true
                break
            }
        }
        return outcome
    }

    func perform(_ action: FolderRuleAction, item: URL, info: FolderRuleFileInfo, counter: Int,
                 interactive: Bool) throws -> Step {
        let context = FolderRulePatterns.Context(info: info, now: environment.now(), counter: counter)
        switch action.kind {
        case .move, .copy:
            return try transfer(item, action: action, context: context, copies: action.kind == .copy)
        case .rename:
            return try rename(item, action: action, context: context)
        case .addTags:
            return try addTags(item, action.tags)
        case .setColorLabel:
            try (item as NSURL).setResourceValue(NSNumber(value: action.colorLabel.rawValue), forKey: .labelNumberKey)
            let summary = action.colorLabel == .none ? "Removed the color label" : "Set the \(action.colorLabel.title.lowercased()) label"
            return Step(record: FolderRuleStepRecord(action: .setColorLabel, result: .done, summary: summary), next: item)
        case .moveToTrash:
            let place = try environment.trash(item)
            return Step(record: FolderRuleStepRecord(action: .moveToTrash, result: .done, summary: "Moved to the Trash",
                                                     undo: .moveBack(current: place.path, original: item.path)), next: nil)
        case .compress:
            return try compress(item, trashOriginal: action.trashOriginal)
        case .extract:
            return try extract(item, info: info, trashOriginal: action.trashOriginal)
        case .optimizeImage:
            return try FolderRulesImageOptimizer.optimize(item, info: info, options: action.image, environment: environment)
        case .installApp:
            return try FolderRulesDiskImageInstaller.install(item, options: action.install, environment: environment,
                                                             interactive: interactive)
        case .openWith:
            let app = action.appPath.isEmpty ? nil : URL(fileURLWithPath: action.appPath)
            if let app, !FolderRulesSafety.exists(app.path) {
                throw FolderRuleFailure("“\(app.deletingPathExtension().lastPathComponent)” isn't installed anymore.")
            }
            guard environment.open(item, app) else { throw FolderRuleFailure("macOS couldn't open “\(item.lastPathComponent)”.") }
            let summary = app.map { "Opened with \($0.deletingPathExtension().lastPathComponent)" } ?? "Opened"
            return Step(record: FolderRuleStepRecord(action: .openWith, result: .done, summary: summary), next: item)
        case .notify:
            let message = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = message.isEmpty ? item.lastPathComponent : FolderRulePatterns.expand(message, context)
            return Step(record: FolderRuleStepRecord(action: .notify, result: .done, summary: "Notified: \(text)"),
                        next: item, notification: text)
        case .runAutomation:
            guard let id = action.automationID else { throw FolderRuleFailure("Choose an automation to run.") }
            let name = action.automationName.isEmpty ? "the automation" : "“\(action.automationName)”"
            switch environment.runAutomation(id, action.automationName, item) {
            case .success:
                return Step(record: FolderRuleStepRecord(action: .runAutomation, result: .done, summary: "Ran \(name)"), next: item)
            case .failure(let failure):
                throw failure
            }
        case .runShortcut:
            let name = action.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, !name.contains("\0") else { throw FolderRuleFailure("Enter the shortcut's name.") }
            let request = FolderRulesProcess.Request("/usr/bin/shortcuts", ["run", name, "--input-path", item.path], timeout: 120)
            let result = environment.run(request)
            guard result.succeeded else { throw FolderRuleFailure(result.failure(request)) }
            return Step(record: FolderRuleStepRecord(action: .runShortcut, result: .done, summary: "Ran the “\(name)” shortcut"),
                        next: item)
        }
    }

    // MARK: Move, copy, rename

    private func transfer(_ item: URL, action: FolderRuleAction, context: FolderRulePatterns.Context,
                          copies: Bool) throws -> Step {
        let kind: FolderRuleActionKind = copies ? .copy : .move
        let path = (action.folderPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw FolderRuleFailure("Choose a folder to \(copies ? "copy" : "move") to.") }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        // The chosen folder must exist: creating it could put a folder named
        // after an unplugged drive on the startup disk. Only the pattern's
        // subfolders are created.
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FolderRuleFailure("The folder “\(FolderRulesSafety.display(root))” doesn't exist. Is its drive connected?")
        }
        var destination = root
        for component in FolderRulePatterns.subfolderComponents(action.subfolderPattern, context) {
            destination.appendPathComponent(component, isDirectory: true)
        }
        let source = item.standardizedFileURL
        if destination.path == source.path || destination.path.hasPrefix(source.path + "/") {
            throw FolderRuleFailure("“\(item.lastPathComponent)” can't go into itself.")
        }
        if !copies, destination.path == source.deletingLastPathComponent().path {
            return Step(record: FolderRuleStepRecord(action: kind, result: .skipped,
                                                     summary: "Already in \(FolderRulesSafety.display(destination))"), next: item)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = FolderRulePatterns.uniqueURL(destination.appendingPathComponent(item.lastPathComponent)) {
            FolderRulesSafety.exists($0.path)
        }
        if copies { try fileManager.copyItem(at: item, to: target) } else { try fileManager.moveItem(at: item, to: target) }
        let renamed = target.lastPathComponent == item.lastPathComponent ? "" : " as “\(target.lastPathComponent)”"
        let summary = "\(copies ? "Copied" : "Moved") to \(FolderRulesSafety.display(destination))\(renamed)"
        return Step(record: FolderRuleStepRecord(action: kind, result: .done, summary: summary,
                                                 undo: copies ? nil : .moveBack(current: target.path, original: item.path)),
                    next: target, produced: copies ? target : nil)
    }

    private func rename(_ item: URL, action: FolderRuleAction, context: FolderRulePatterns.Context) throws -> Step {
        guard let newName = FolderRulePatterns.fileName(action.pattern, context) else {
            throw FolderRuleFailure("The pattern “\(action.pattern)” leaves no name.")
        }
        let usedCounter = FolderRulePatterns.usesCounter(action.pattern)
        if newName == item.lastPathComponent {
            return Step(record: FolderRuleStepRecord(action: .rename, result: .skipped, summary: "Already named “\(newName)”"),
                        next: item, usedCounter: false)
        }
        let desired = item.deletingLastPathComponent().appendingPathComponent(newName)
        let target = FolderRulePatterns.uniqueURL(desired) { candidate in
            FolderRulesSafety.exists(candidate.path) && !FolderRulesSafety.sameItem(candidate, item)
        }
        if FolderRulesSafety.sameItem(target, item) {
            // A change of case only: the volume sees the same name, so
            // FileManager refuses; rename(2) does it.
            guard Darwin.rename(item.path, target.path) == 0 else {
                throw FolderRuleFailure("Couldn't rename “\(item.lastPathComponent)”: \(String(cString: strerror(errno))).")
            }
        } else {
            try fileManager.moveItem(at: item, to: target)
        }
        return Step(record: FolderRuleStepRecord(action: .rename, result: .done, summary: "Renamed to “\(target.lastPathComponent)”",
                                                 undo: .moveBack(current: target.path, original: item.path)),
                    next: target, usedCounter: usedCounter)
    }

    private func addTags(_ item: URL, _ wanted: [String]) throws -> Step {
        let existing = (try? item.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        let lowered = Set(existing.map { $0.lowercased() })
        var added: [String] = []
        for raw in wanted {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !lowered.contains(tag.lowercased()),
                  !added.contains(where: { $0.lowercased() == tag.lowercased() }) else { continue }
            added.append(tag)
        }
        guard !added.isEmpty else {
            return Step(record: FolderRuleStepRecord(action: .addTags, result: .skipped, summary: "Already tagged"), next: item)
        }
        try (item as NSURL).setResourceValue(existing + added, forKey: .tagNamesKey)
        return Step(record: FolderRuleStepRecord(action: .addTags, result: .done,
                                                 summary: "Tagged \(added.map { "“\($0)”" }.joined(separator: ", "))"), next: item)
    }

    // MARK: ZIP

    private func compress(_ item: URL, trashOriginal: Bool) throws -> Step {
        let zip = FolderRulePatterns.uniqueURL(item.deletingLastPathComponent()
            .appendingPathComponent(item.lastPathComponent + ".zip")) { FolderRulesSafety.exists($0.path) }
        let request = FolderRulesProcess.Request("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", item.path, zip.path],
                                                 timeout: 900)
        let result = environment.run(request)
        guard result.succeeded, FolderRulesSafety.exists(zip.path) else {
            // Only the unfinished archive this step started is removed.
            if FolderRulesSafety.exists(zip.path) { try? fileManager.removeItem(at: zip) }
            throw FolderRuleFailure(result.failure(request))
        }
        var undo: FolderRuleUndo?
        var summary = "Compressed to “\(zip.lastPathComponent)”"
        if trashOriginal {
            let place = try environment.trash(item)
            undo = .moveBack(current: place.path, original: item.path)
            summary += " and moved the original to the Trash"
        }
        return Step(record: FolderRuleStepRecord(action: .compress, result: .done, summary: summary, undo: undo), next: zip, produced: zip)
    }

    private func extract(_ item: URL, info: FolderRuleFileInfo, trashOriginal: Bool) throws -> Step {
        let isZip = info.contentType.flatMap(UTType.init)?.conforms(to: .zip) == true || info.fileExtension.lowercased() == "zip"
        guard isZip, !info.isDirectory else { throw FolderRuleFailure("“\(item.lastPathComponent)” isn't a ZIP archive.") }
        let parent = item.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".aom-extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { if FolderRulesSafety.exists(staging.path) { try? fileManager.removeItem(at: staging) } }
        let request = FolderRulesProcess.Request("/usr/bin/ditto", ["-x", "-k", item.path, staging.path], timeout: 900)
        let result = environment.run(request)
        guard result.succeeded else { throw FolderRuleFailure(result.failure(request)) }
        let contents = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        let extracted: URL
        if contents.count == 1, let only = contents.first {
            extracted = FolderRulePatterns.uniqueURL(parent.appendingPathComponent(only.lastPathComponent)) { FolderRulesSafety.exists($0.path) }
            try fileManager.moveItem(at: only, to: extracted)
        } else if contents.count > 1 {
            let name = FolderRulePatterns.sanitized(info.baseName).isEmpty ? "Archive" : FolderRulePatterns.sanitized(info.baseName)
            extracted = FolderRulePatterns.uniqueURL(parent.appendingPathComponent(name, isDirectory: true)) { FolderRulesSafety.exists($0.path) }
            for leftover in [staging.appendingPathComponent("__MACOSX"), staging.appendingPathComponent(".DS_Store")]
            where FolderRulesSafety.exists(leftover.path) {
                try? fileManager.removeItem(at: leftover)
            }
            try fileManager.moveItem(at: staging, to: extracted)
        } else {
            throw FolderRuleFailure("“\(item.lastPathComponent)” is empty.")
        }
        var undo: FolderRuleUndo?
        var summary = "Extracted “\(extracted.lastPathComponent)”"
        if trashOriginal {
            let place = try environment.trash(item)
            undo = .moveBack(current: place.path, original: item.path)
            summary += " and moved the archive to the Trash"
        }
        return Step(record: FolderRuleStepRecord(action: .extract, result: .done, summary: summary, undo: undo),
                    next: extracted, produced: extracted)
    }

    // MARK: Undo

    /// Reverses the undoable steps of a run, last first. Returns the records
    /// with `undone` set, and the first failure if a step couldn't be undone.
    func undo(_ steps: [FolderRuleStepRecord]) -> (steps: [FolderRuleStepRecord], failure: String?) {
        var records = steps
        for index in records.indices.reversed() where records[index].canUndo {
            guard let undo = records[index].undo else { continue }
            do {
                try reverse(undo)
                records[index].undone = true
            } catch {
                return (records, FolderRuleFailure.wrapping(error, "Couldn't undo.").message)
            }
        }
        return (records, nil)
    }

    private func reverse(_ undo: FolderRuleUndo) throws {
        switch undo {
        case .moveBack(let current, let original):
            try moveBack(URL(fileURLWithPath: current), to: URL(fileURLWithPath: original))
        case .restoreOriginal(let trashed, let original, let replacement):
            let replacementURL = URL(fileURLWithPath: replacement)
            if FolderRulesSafety.exists(replacement) { _ = try environment.trash(replacementURL) }
            try moveBack(URL(fileURLWithPath: trashed), to: URL(fileURLWithPath: original))
        }
    }

    private func moveBack(_ current: URL, to original: URL) throws {
        guard FolderRulesSafety.exists(current.path) else {
            throw FolderRuleFailure("“\(current.lastPathComponent)” is no longer at \(FolderRulesSafety.display(current.deletingLastPathComponent())).")
        }
        let folder = original.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FolderRuleFailure("The folder “\(FolderRulesSafety.display(folder))” is gone, so “\(original.lastPathComponent)” can't go back.")
        }
        let target = FolderRulePatterns.uniqueURL(original) { candidate in
            FolderRulesSafety.exists(candidate.path) && !FolderRulesSafety.sameItem(candidate, current)
        }
        if FolderRulesSafety.sameItem(target, current) {
            guard Darwin.rename(current.path, target.path) == 0 else {
                throw FolderRuleFailure("Couldn't rename “\(current.lastPathComponent)” back: \(String(cString: strerror(errno))).")
            }
        } else {
            try fileManager.moveItem(at: current, to: target)
        }
    }
}

/// Small file-system checks shared by the engine, the executor and the views.
enum FolderRulesSafety {
    /// Exists without following a final symbolic link.
    static func exists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    /// Two paths name the same item (a case-only rename on a case-insensitive volume).
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a.path, &first) == 0, lstat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// `item` lies inside `folder` (symbolic links in the folder's path resolved).
    static func isInside(_ item: URL, _ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let path = parent + "/" + item.lastPathComponent
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// "~/Pictures/Screenshots" for paths in the home folder. In an isolated
    /// UI preview the sample folders stand in for the home folder, so they
    /// show as "~/Downloads" too.
    static func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let sample = FolderRulesLocations.sampleRoot?.standardizedFileURL.path {
            if path == sample { return "~" }
            if path.hasPrefix(sample + "/") { return "~" + path.dropFirst(sample.count) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
