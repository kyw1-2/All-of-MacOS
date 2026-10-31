import Foundation
import XCTest
@testable import AllOfMacOS

/// Pattern tokens, safe path components and Finder-style conflict names.
final class FolderRulesPatternTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    /// 2026-03-07 09:30 in Seoul.
    private var added: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 30))!
    }

    private func context(_ info: FolderRuleFileInfo, counter: Int = 1) -> FolderRulePatterns.Context {
        var context = FolderRulePatterns.Context(info: info, now: added.addingTimeInterval(86_400 * 40), counter: counter)
        context.calendar = calendar
        return context
    }

    func testFolderTokensUseTheDateTheItemArrived() {
        let shot = FolderRuleFileInfo.fixture("Screenshot 1.png", kind: "public.png", added: added, screenshot: true)
        XCTAssertEqual(FolderRulePatterns.expand("{year}-{month}", context(shot)), "2026-03")
        XCTAssertEqual(FolderRulePatterns.expand("{year}/{month}/{day}", context(shot)), "2026/03/07")
        XCTAssertEqual(FolderRulePatterns.expand("{kind}", context(shot)), "Screenshots")
        XCTAssertEqual(FolderRulePatterns.expand("{ext}", context(shot)), "png")
        XCTAssertEqual(FolderRulePatterns.expand("{KIND} · {unknown}", context(shot)), "Screenshots · {unknown}",
                       "tokens ignore case; unknown ones stay as written")
        XCTAssertEqual(FolderRulePatterns.subfolderComponents("Screenshots/{year}-{month}", context(shot)), ["Screenshots", "2026-03"])
        let other = FolderRuleFileInfo.fixture("notes.xyz123", added: added)
        XCTAssertEqual(FolderRulePatterns.expand("{kind}", context(other)), "Other")
        let undated = FolderRuleFileInfo.fixture("x.pdf", kind: "com.adobe.pdf")
        XCTAssertEqual(FolderRulePatterns.expand("{year}", context(undated)), "2026", "no date known: now")
        XCTAssertEqual(FolderRulePatterns.unknownTokens(in: "{year}-{weekday}", allowed: FolderRulePatterns.folderTokens), ["weekday"])
    }

    func testSubfolderPatternsCanNeverClimbOut() {
        let info = FolderRuleFileInfo.fixture("a.pdf", kind: "com.adobe.pdf", added: added)
        XCTAssertEqual(FolderRulePatterns.subfolderComponents("../../etc/{year}", context(info)), ["etc", "2026"])
        XCTAssertEqual(FolderRulePatterns.subfolderComponents("/./Receipts//{month}/", context(info)), ["Receipts", "03"])
        XCTAssertEqual(FolderRulePatterns.subfolderComponents(".hidden/{kind}", context(info)), ["hidden", "PDFs"])
        XCTAssertEqual(FolderRulePatterns.subfolderComponents("   ", context(info)), [])
        XCTAssertEqual(FolderRulePatterns.sanitized("a:b/c\u{0}d"), "a-b-cd")
        XCTAssertEqual(FolderRulePatterns.sanitized("  ..secret  "), "secret")
        XCTAssertLessThanOrEqual(FolderRulePatterns.sanitized(String(repeating: "가", count: 200)).utf8.count, 255)
    }

    func testRenameTokensKeepTheExtensionUnlessAsked() {
        let info = FolderRuleFileInfo.fixture("IMG_0042.HEIC", kind: "public.heic", added: added)
        XCTAssertEqual(FolderRulePatterns.fileName("{name} {date:yyyy-MM-dd}", context(info)), "IMG_0042 2026-03-07.HEIC")
        XCTAssertEqual(FolderRulePatterns.fileName("Photo {counter:3}", context(info, counter: 7)), "Photo 007.HEIC")
        XCTAssertEqual(FolderRulePatterns.fileName("Photo {counter}", context(info, counter: 12)), "Photo 12.HEIC")
        XCTAssertEqual(FolderRulePatterns.fileName("{name}.jpeg", context(info)), "IMG_0042.jpeg.HEIC",
                       "without {ext} the extension is kept even if the pattern writes one")
        XCTAssertEqual(FolderRulePatterns.fileName("{name}.{ext}", context(info)), "IMG_0042.HEIC")
        XCTAssertEqual(FolderRulePatterns.fileName("{date:yyyyMMdd}_{name}.{ext}", context(info)), "20260307_IMG_0042.HEIC")
        XCTAssertEqual(FolderRulePatterns.fileName("{date}", context(info)), "2026-03-07.HEIC", "{date} defaults to yyyy-MM-dd")
        XCTAssertNil(FolderRulePatterns.fileName("   ", context(info)))
        XCTAssertNil(FolderRulePatterns.fileName("...", context(.fixture("folder", directory: true))))
        XCTAssertEqual(FolderRulePatterns.fileName("Re/port: {name}", context(info)), "Re-port- IMG_0042.HEIC")
        XCTAssertTrue(FolderRulePatterns.usesCounter("Photo {counter:2}"))
        XCTAssertFalse(FolderRulePatterns.usesCounter("{name}"))
        let folderInfo = FolderRuleFileInfo.fixture("Lecture.v2", directory: true, depth: 0)
        XCTAssertEqual(FolderRulePatterns.fileName("{name} (old)", context(folderInfo)), "Lecture.v2 (old)", "folders have no extension")
    }

    func testConflictNamesCountUpLikeFinder() {
        let directory = URL(fileURLWithPath: "/tmp/aom-conflicts", isDirectory: true)
        var taken: Set<String> = ["Report.pdf", "Report 2.pdf", "Folder"]
        let free = FolderRulePatterns.uniqueURL(directory.appendingPathComponent("Other.pdf")) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(free.lastPathComponent, "Other.pdf")
        let third = FolderRulePatterns.uniqueURL(directory.appendingPathComponent("Report.pdf")) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(third.lastPathComponent, "Report 3.pdf")
        let folder = FolderRulePatterns.uniqueURL(directory.appendingPathComponent("Folder")) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(folder.lastPathComponent, "Folder 2")
        taken.insert("archive.tar 2.gz")
        let dotted = FolderRulePatterns.uniqueURL(directory.appendingPathComponent("archive.tar.gz")) { $0.lastPathComponent == "archive.tar.gz" }
        XCTAssertEqual(dotted.lastPathComponent, "archive.tar 2.gz")
    }

    func testConflictNamesOnDiskDuringAMove() throws {
        let kit = try FolderRulesTestKit()
        defer { kit.remove() }
        let destination = try kit.folder("Receipts")
        try kit.write("bill.pdf", in: destination)
        try kit.write("bill 2.pdf", in: destination)
        let source = try kit.writeSettled("bill.pdf")
        let info = try XCTUnwrap(FolderRuleFileReader.read(source))
        let rule = FolderRule(folderID: UUID(), name: "Receipts", conditions: [.kind(.pdf)],
                              actions: [.move(to: destination.path)])
        let outcome = FolderRuleExecutor(environment: kit.environment()).run(rule, on: info, in: kit.watched)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertEqual(kit.names(in: destination), ["bill 2.pdf", "bill 3.pdf", "bill.pdf"])
        XCTAssertEqual(outcome.finalURL?.lastPathComponent, "bill 3.pdf")
        XCTAssertTrue(outcome.steps[0].summary.contains("as “bill 3.pdf”"))
    }
}
