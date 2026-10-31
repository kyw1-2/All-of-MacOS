import Foundation
import XCTest
@testable import AllOfMacOS

/// A temporary world for Folder Rules tests: a watched folder, a stand-in
/// Trash, a clock and recorded helper calls. Nothing outside the temporary
/// folder is touched: no real Trash, no mounts, no notifications.
final class FolderRulesTestKit {
    let root: URL
    let watched: URL
    let trash: URL
    var now: Date
    private(set) var trashed: [URL] = []
    private(set) var requests: [FolderRulesProcess.Request] = []

    init(now: Date = Date()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-folderrules-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        watched = root.appendingPathComponent("Watched", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        self.now = now
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// `run` answers helper calls; the default runs only ditto for real
    /// (on files inside the temporary folder) and refuses everything else.
    func environment(run: ((FolderRulesProcess.Request) -> FolderRulesProcess.Result)? = nil,
                     confirmReplace: @escaping (String) -> FolderRuleReplaceChoice = { _ in .cancel },
                     applications: URL? = nil) -> FolderRulesEnvironment {
        FolderRulesEnvironment(
            now: { [unowned self] in self.now },
            trash: { [unowned self] url in
                let place = FolderRulePatterns.uniqueURL(self.trash.appendingPathComponent(url.lastPathComponent)) {
                    FolderRulesSafety.exists($0.path)
                }
                try FileManager.default.moveItem(at: url, to: place)
                self.trashed.append(place)
                return place
            },
            run: { [unowned self] request in
                self.requests.append(request)
                if let run { return run(request) }
                guard request.executable == "/usr/bin/ditto",
                      request.arguments.allSatisfy({ !$0.hasPrefix("/") || $0.hasPrefix(self.root.path) }) else {
                    return FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: "not allowed in tests")
                }
                return FolderRulesProcess.run(request)
            },
            applicationsFolder: applications ?? root.appendingPathComponent("Applications", isDirectory: true),
            open: { _, _ in true },
            runAutomation: { _, _, _ in .success(()) },
            isAppRunning: { _ in false },
            confirmReplace: confirmReplace,
            chooseApp: { _ in nil },
            copyAsAdministrator: { _, _ in FolderRuleFailure("no administrator in tests") })
    }

    @discardableResult
    func write(_ name: String, in folder: URL? = nil, _ data: Data = Data("hello".utf8), modified: Date? = nil) throws -> URL {
        let url = (folder ?? watched).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func names(in folder: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? watched).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A config watching `watched` with these rules (each switched on).
    func config(_ rules: [FolderRule], folderID: UUID) -> FolderRulesConfig {
        var enabled = rules
        for index in enabled.indices { enabled[index].isEnabled = true }
        return FolderRulesConfig(isEnabled: true, folders: [FolderRuleFolder(id: folderID, path: watched.path)], rules: enabled)
    }

    /// Writes an old file (modified a day before `now`) so it counts as settled.
    @discardableResult
    func writeSettled(_ name: String, in folder: URL? = nil, _ data: Data = Data("hello".utf8)) throws -> URL {
        try write(name, in: folder, data, modified: now.addingTimeInterval(-86_400))
    }
}

extension FolderRuleFileInfo {
    /// A plain fixture file in /tmp (never read from disk).
    static func fixture(_ name: String, kind: String? = nil, size: Int64 = 1_000, added: Date? = nil, created: Date? = nil,
                        modified: Date? = nil, opened: Date? = nil, whereFroms: [String] = [], tags: [String] = [],
                        screenshot: Bool = false, directory: Bool = false, package: Bool = false, depth: Int = 0) -> FolderRuleFileInfo {
        FolderRuleFileInfo(url: URL(fileURLWithPath: "/tmp/aom-fixture/\(name)"), name: name, isDirectory: directory,
                           isPackage: package, contentType: kind, isScreenCapture: screenshot, size: size, dateAdded: added,
                           dateCreated: created, dateModified: modified, dateLastOpened: opened, whereFroms: whereFroms,
                           tags: tags, device: 1, inode: UInt64(bitPattern: Int64(name.hashValue)) % 1_000_000, depth: depth)
    }
}

/// The kit itself: its Trash is a temporary folder and helpers other than
/// ditto on temporary files are refused.
final class FolderRulesFixturesTests: XCTestCase {
    func testTheKitsTrashAndHelpersStayInsideItsTemporaryFolder() throws {
        let kit = try FolderRulesTestKit()
        defer { kit.remove() }
        let file = try kit.write("note.txt")
        let environment = kit.environment()
        let place = try environment.trash(file)
        XCTAssertTrue(place.path.hasPrefix(kit.trash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let refused = environment.run(FolderRulesProcess.Request("/usr/bin/hdiutil", ["info"], timeout: 5))
        XCTAssertFalse(refused.succeeded, "the kit never lets a test run hdiutil")
        XCTAssertEqual(kit.requests.map(\.executable), ["/usr/bin/hdiutil"])
    }
}
