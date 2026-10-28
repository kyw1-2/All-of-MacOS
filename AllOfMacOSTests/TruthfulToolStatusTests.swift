import XCTest
import Darwin
@testable import AllOfMacOS

/// Audit 2026-10-28 F08 (a clipboard storage failure is not an empty
/// history), F09 (system tools report what really happened) and F10 (the
/// Desktop Icons tool's first toggle). Only temporary folders, throwaway
/// preference suites and stand-in commands are used: the real Finder
/// settings, Trash and DNS resolver are never touched.
final class TruthfulToolStatusTests: XCTestCase {
    private var cleanups: [() -> Void] = []
    private let tools = MacMagicSystemToolService.shared

    override func tearDown() {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups.removeAll()
        super.tearDown()
    }

    private func suite() throws -> UserDefaults {
        let name = "AOMAuditF10.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        cleanups.append { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AOMAuditF09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanups.append { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: F10 — Desktop Icons

    /// The audit's probe: with no `CreateDesktop` key (Finder's default,
    /// icons shown) 3.3.0 computed "current false, next true", so the first
    /// toggle wrote true and nothing changed.
    func testTheFirstDesktopIconsToggleHidesTheIconsOnADefaultMac() throws {
        let finder = try suite()
        XCTAssertFalse(MacMagicSystemToolService.nextDesktopIconsState(in: finder), "missing key: icons are shown, so hide them")
        finder.set(true, forKey: "CreateDesktop")
        XCTAssertFalse(MacMagicSystemToolService.nextDesktopIconsState(in: finder))
        finder.set(false, forKey: "CreateDesktop")
        XCTAssertTrue(MacMagicSystemToolService.nextDesktopIconsState(in: finder))
        finder.set("NO", forKey: "CreateDesktop")      // `defaults write … CreateDesktop NO` stores a string
        XCTAssertTrue(MacMagicSystemToolService.nextDesktopIconsState(in: finder))
        XCTAssertFalse(MacMagicSystemToolService.nextDesktopIconsState(in: nil), "no readable domain: Finder's default")
    }

    func testHiddenFilesKeepTheirHiddenDefault() throws {
        let finder = try suite()
        XCTAssertFalse(MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false))
        finder.set("YES", forKey: "AppleShowAllFiles")
        XCTAssertTrue(MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false))
    }

    // MARK: F09 — Flush DNS

    /// The review found the administrator prompt unreachable: run by anyone
    /// but root, the real `killall` answers "No matching processes belonging
    /// to you were found" (exit 1), not a permission error. `-s` only prints
    /// what it would do, so this sends no signal to anything.
    func testTheRealUnprivilegedKillallAnswerOffersTheAdministratorPrompt() async throws {
        try XCTSkipIf(getuid() == 0, "root may signal mDNSResponder")
        let dryRun = MacMagicSystemToolService.ToolCommand(path: "/usr/bin/killall", arguments: ["-s", "-HUP", "mDNSResponder"])
        do {
            try await tools.flushDNSCache(commands: [dryRun])
            XCTFail("an unprivileged killall cannot reach mDNSResponder")
        } catch let error as SystemToolError {
            XCTAssertTrue(error.needsAdministrator, error.localizedDescription)
        }
    }

    func testAFailingDNSStepIsReportedWithItsExitStatusAndMessage() async throws {
        typealias Command = MacMagicSystemToolService.ToolCommand
        let succeeds = Command(path: "/usr/bin/true", arguments: [])
        let refused = Command(path: "/bin/sh", arguments: ["-c", "echo 'killall: warning: kill -HUP 123: Operation not permitted' >&2; exit 1"])
        do {
            try await tools.flushDNSCache(commands: [succeeds, refused])
            XCTFail("a step that exits 1 must not read as flushed (3.3.0 never looked at the status)")
        } catch let error as SystemToolError {
            guard case .commandFailed(let command, let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(command, "sh")
            XCTAssertEqual(status, 1)
            XCTAssertTrue(message.contains("Operation not permitted"), message)
            XCTAssertTrue(error.needsAdministrator, "a refused signal offers the administrator prompt")
            XCTAssertTrue(error.localizedDescription.contains("exit status 1"), error.localizedDescription)
        }
        do {
            try await tools.flushDNSCache(commands: [Command(path: "/usr/bin/false", arguments: [])])
            XCTFail("exit status 1 without a message is still a failure")
        } catch let error as SystemToolError {
            XCTAssertFalse(error.needsAdministrator, "only a privilege refusal asks for a password")
        }
        try await tools.flushDNSCache(commands: [succeeds, succeeds])
    }

    // MARK: F09 — Empty Trash

    func testEmptyTrashCountsWhatItCouldNotDeleteAndNeverCallsThatEmptied() async throws {
        let trash = try folder()
        try Data("a".utf8).write(to: trash.appendingPathComponent("a.txt"))
        let nested = trash.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        let locked = trash.appendingPathComponent("locked.txt")
        try Data("c".utf8).write(to: locked)
        try tools.setFileLocked(url: locked, locked: true)
        cleanups.append { [tools] in try? tools.setFileLocked(url: locked, locked: false) }

        let partial = try await tools.forceEmptyTrash(at: trash)
        XCTAssertEqual(partial.deleted, 2)
        XCTAssertEqual(partial.failures.count, 1)
        XCTAssertTrue(partial.failures[0].hasPrefix("locked.txt: "), partial.failures[0])
        XCTAssertFalse(partial.succeeded)
        XCTAssertFalse(partial.summary.lowercased().contains("emptied"), "no success message: \(partial.summary)")
        XCTAssertTrue(partial.summary.contains("1 could not be deleted"), partial.summary)

        try tools.setFileLocked(url: locked, locked: false)
        let rest = try await tools.forceEmptyTrash(at: trash)
        XCTAssertTrue(rest.succeeded)
        XCTAssertEqual(rest.summary, "Trash emptied (1 item)")
        let again = try await tools.forceEmptyTrash(at: trash)
        XCTAssertEqual(again.summary, "Trash was already empty")
    }

    func testATrashAOMMayNotReadSaysWhatToDo() async throws {
        let trash = try folder()
        XCTAssertEqual(chmod(trash.path, 0), 0)
        cleanups.append { chmod(trash.path, 0o700) }
        do {
            _ = try await tools.forceEmptyTrash(at: trash)
            XCTFail("an unreadable Trash is not an empty one")
        } catch let error as SystemToolError {
            XCTAssertEqual(error, .trashNotReadable)
            XCTAssertTrue(error.localizedDescription.contains("Full Disk Access"), error.localizedDescription)
        }
    }

    // MARK: F08 — clipboard storage failures

    /// Normal empty history, a Keychain that is not available yet and a
    /// damaged archive each read differently; 3.3.0 showed "Your Clipboard
    /// Is Empty" for all three.
    func testStorageFailuresAreNeverShownAsAnEmptyHistory() {
        let empty = ClipboardEmptyContent.resolve(isLoading: false, storage: .ok, paused: false)
        let keychain = ClipboardEmptyContent.resolve(isLoading: false, storage: .transientFailure, paused: false)
        let damaged = ClipboardEmptyContent.resolve(isLoading: false, storage: .unreadableArchive, paused: false)
        XCTAssertEqual(empty, .empty(paused: false))
        XCTAssertEqual(keychain, .keychainUnavailable)
        XCTAssertEqual(damaged, .unreadableArchive)
        XCTAssertEqual(Set([empty.title, keychain.title, damaged.title]).count, 3)
        XCTAssertEqual(Set([empty.message, keychain.message, damaged.message]).count, 3)
        XCTAssertEqual(Set([empty.compactMessage, keychain.compactMessage, damaged.compactMessage]).count, 3)
        for problem in [keychain, damaged] {
            XCTAssertTrue(problem.isStorageProblem)
            XCTAssertFalse(problem.title.localizedCaseInsensitiveContains("empty"), problem.title)
        }
        XCTAssertFalse(empty.isStorageProblem)
        XCTAssertTrue(keychain.message.contains("Nothing has been deleted"))
        XCTAssertTrue(damaged.message.contains("has not been changed"))
        // A storage failure is reported even while loading or paused.
        XCTAssertEqual(ClipboardEmptyContent.resolve(isLoading: true, storage: .transientFailure, paused: true), .keychainUnavailable)
        XCTAssertEqual(ClipboardEmptyContent.resolve(isLoading: true, storage: .unreadableArchive, paused: false), .unreadableArchive)
        XCTAssertEqual(ClipboardEmptyContent.resolve(isLoading: true, storage: .ok, paused: false), .loading)
        XCTAssertEqual(ClipboardEmptyContent.resolve(isLoading: false, storage: .ok, paused: true), .empty(paused: true))
    }
}
