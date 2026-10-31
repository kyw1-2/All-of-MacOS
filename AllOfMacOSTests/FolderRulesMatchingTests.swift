import Foundation
import XCTest
@testable import AllOfMacOS

/// Folder Rules conditions: every attribute and operator, all/any/none, the
/// top-level default, and the metadata decoders (fixture bytes, no disk).
final class FolderRulesMatchingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let folder = UUID()

    private func rule(_ conditions: [FolderRuleCondition], match: FolderRuleMatch = .all, subfolders: Bool = false) -> FolderRule {
        FolderRule(folderID: folder, name: "Test", match: match, conditions: conditions, actions: [.moveToTrash],
                   includeSubfolders: subfolders)
    }

    private func matches(_ condition: FolderRuleCondition, _ info: FolderRuleFileInfo) -> Bool {
        FolderRuleMatcher.matches(condition, info, now: now)
    }

    func testNameOperatorsIgnoreCaseAndTheExtension() {
        let info = FolderRuleFileInfo.fixture("Invoice-October.PDF", kind: "com.adobe.pdf")
        XCTAssertEqual(info.baseName, "Invoice-October")
        XCTAssertTrue(matches(.name(.contains, ["invoice"]), info))
        XCTAssertTrue(matches(.name(.contains, ["receipt", "october"]), info), "any of the words")
        XCTAssertFalse(matches(.name(.contains, ["pdf"]), info), "the extension isn't part of the name")
        XCTAssertTrue(matches(.name(.doesNotContain, ["receipt", "bill"]), info))
        XCTAssertFalse(matches(.name(.doesNotContain, ["receipt", "INVOICE"]), info), "none of the words may appear")
        XCTAssertTrue(matches(.name(.startsWith, ["inv"]), info))
        XCTAssertFalse(matches(.name(.startsWith, ["october"]), info))
        XCTAssertTrue(matches(.name(.endsWith, ["OCTOBER"]), info))
        XCTAssertTrue(matches(.name(.is, ["invoice-october"]), info))
        XCTAssertFalse(matches(.name(.is, ["invoice"]), info))
        XCTAssertTrue(matches(.name(.isNot, ["Archive"]), info))
        XCTAssertTrue(matches(.namePattern(#"^invoice-\w+$"#), info))
        XCTAssertFalse(matches(.namePattern(#"^receipt"#), info))
        XCTAssertFalse(matches(.namePattern("("), info), "an invalid pattern never matches")
        XCTAssertFalse(matches(.name(.contains, []), info), "no words, no match")
    }

    func testKoreanNamesMatchWhetherDecomposedOrComposed() {
        // Browsers and HFS-era tools often write decomposed (NFD) Hangul.
        let decomposed = "쿠팡 영수증".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(decomposed.unicodeScalars), Array("쿠팡 영수증".unicodeScalars))
        let info = FolderRuleFileInfo.fixture(decomposed + ".pdf", kind: "com.adobe.pdf")
        XCTAssertTrue(matches(.name(.contains, ["영수증"]), info))
        XCTAssertTrue(matches(.name(.endsWith, ["영수증"]), info))
        XCTAssertTrue(matches(.namePattern("영수증|청구서"), info))
        let composedTag = FolderRuleFileInfo.fixture("a.txt", tags: ["영수증".decomposedStringWithCanonicalMapping])
        XCTAssertTrue(matches(.tags(.has, ["영수증"]), composedTag))
    }

    func testExtensionsCompareWithoutDotsOrCase() {
        let info = FolderRuleFileInfo.fixture("Setup.DMG")
        XCTAssertTrue(matches(.fileExtension(.is, [".dmg", "pkg"]), info))
        XCTAssertFalse(matches(.fileExtension(.isNot, ["DMG"]), info))
        XCTAssertTrue(matches(.fileExtension(.isNot, ["zip"]), info))
        let folderInfo = FolderRuleFileInfo.fixture("Project.v2", directory: true)
        XCTAssertEqual(folderInfo.fileExtension, "", "a folder's dot is part of its name")
        XCTAssertFalse(matches(.fileExtension(.is, ["v2"]), folderInfo))
    }

    func testKindsComeFromTypeConformance() {
        let screenshot = FolderRuleFileInfo.fixture("Screen.png", kind: "public.png", screenshot: true)
        XCTAssertTrue(matches(.kind(.screenshot), screenshot))
        XCTAssertTrue(matches(.kind(.image), screenshot), "a screenshot is an image too")
        XCTAssertEqual(screenshot.primaryKind, .screenshot)
        let photo = FolderRuleFileInfo.fixture("IMG_1.heic", kind: "public.heic")
        XCTAssertTrue(matches(.kind(.image), photo))
        XCTAssertFalse(matches(.kind(.screenshot), photo))
        XCTAssertTrue(matches(.kind(.screenshot, is: false), photo))
        let dmg = FolderRuleFileInfo.fixture("App.dmg", kind: "com.apple.disk-image-udif")
        XCTAssertTrue(matches(.kind(.diskImage), dmg))
        XCTAssertFalse(matches(.kind(.archive), dmg), "a disk image is not sorted as an archive")
        let pkg = FolderRuleFileInfo.fixture("Install.pkg", kind: "com.apple.installer-package-archive")
        XCTAssertTrue(matches(.kind(.installerPackage), pkg))
        XCTAssertFalse(matches(.kind(.archive), pkg))
        XCTAssertTrue(matches(.kind(.archive), .fixture("data.zip", kind: "public.zip-archive")))
        XCTAssertTrue(matches(.kind(.archive), .fixture("data.rar")), "rar has no system type; the extension counts")
        let pdf = FolderRuleFileInfo.fixture("a.pdf", kind: "com.adobe.pdf")
        XCTAssertTrue(matches(.kind(.pdf), pdf))
        XCTAssertTrue(matches(.kind(.document), pdf))
        XCTAssertEqual(pdf.primaryKind, .pdf)
        XCTAssertTrue(matches(.kind(.document), .fixture("report.docx", kind: "org.openxmlformats.wordprocessingml.document")))
        XCTAssertTrue(matches(.kind(.document), .fixture("과제.hwp")), "Hangul documents count")
        XCTAssertFalse(matches(.kind(.document), .fixture("main.swift", kind: "public.swift-source")), "source code isn't a document")
        XCTAssertTrue(matches(.kind(.movie), .fixture("clip.mov", kind: "com.apple.quicktime-movie")))
        XCTAssertTrue(matches(.kind(.audio), .fixture("song.mp3", kind: "public.mp3")))
        XCTAssertFalse(matches(.kind(.movie), .fixture("song.mp3", kind: "public.mp3")))
        let app = FolderRuleFileInfo.fixture("Ice.app", kind: "com.apple.application-bundle", directory: true, package: true)
        XCTAssertTrue(matches(.kind(.application), app))
        XCTAssertFalse(matches(.kind(.folder), app), "an app is a package, not a folder")
        XCTAssertTrue(matches(.kind(.folder), .fixture("Photos", directory: true)))
    }

    func testDatesCountBackFromNow() {
        let fourDays = now.addingTimeInterval(-4 * 86_400)
        let info = FolderRuleFileInfo.fixture("a.dmg", added: fourDays, created: fourDays, modified: now.addingTimeInterval(-90))
        XCTAssertTrue(matches(.date(.dateAdded, .olderThan, 3, .days), info))
        XCTAssertFalse(matches(.date(.dateAdded, .olderThan, 5, .days), info))
        XCTAssertTrue(matches(.date(.dateAdded, .newerThan, 5, .days), info))
        XCTAssertTrue(matches(.date(.dateModified, .newerThan, 2, .minutes), info))
        XCTAssertFalse(matches(.date(.dateModified, .olderThan, 2, .minutes), info))
        XCTAssertTrue(matches(.date(.dateCreated, .olderThan, 95, .hours), info))
        XCTAssertFalse(matches(.date(.dateCreated, .olderThan, 97, .hours), info))
        // Never opened: counts as opened when it arrived.
        XCTAssertTrue(matches(.date(.dateLastOpened, .olderThan, 3, .days), info))
        let opened = FolderRuleFileInfo.fixture("b.pdf", added: fourDays, opened: now.addingTimeInterval(-3_600))
        XCTAssertFalse(matches(.date(.dateLastOpened, .olderThan, 3, .days), opened))
        XCTAssertTrue(matches(.date(.dateLastOpened, .newerThan, 2, .hours), opened))
        let unknown = FolderRuleFileInfo.fixture("c.txt")
        XCTAssertFalse(matches(.date(.dateCreated, .olderThan, 1, .days), unknown), "no date, no match")
    }

    func testSizesUseDecimalUnits() {
        let info = FolderRuleFileInfo.fixture("movie.mp4", size: 1_500_000)
        XCTAssertTrue(matches(.size(.greaterThan, 1, .megabytes), info))
        XCTAssertFalse(matches(.size(.greaterThan, 2, .megabytes), info))
        XCTAssertTrue(matches(.size(.lessThan, 1_501, .kilobytes), info))
        XCTAssertFalse(matches(.size(.lessThan, 1_500, .kilobytes), info))
        XCTAssertTrue(matches(.size(.lessThan, 1, .gigabytes), info))
    }

    func testDownloadedFromMatchesHostsInWhereFroms() {
        let info = FolderRuleFileInfo.fixture("lecture.pdf", whereFroms: ["https://uclass.uos.ac.kr/pluginfile.php/1/a.pdf",
                                                                           "https://uclass.uos.ac.kr/course/view.php"])
        XCTAssertEqual(info.downloadHosts, ["uclass.uos.ac.kr"])
        XCTAssertTrue(matches(.downloadedFrom(["uos.ac.kr"]), info))
        XCTAssertTrue(matches(.downloadedFrom(["https://UCLASS.uos.ac.kr/anything"]), info), "a pasted URL means its host")
        XCTAssertFalse(matches(.downloadedFrom(["github.com"]), info))
        XCTAssertTrue(matches(.downloadedFrom(["github.com"], .doesNotContain), info))
        XCTAssertFalse(matches(.downloadedFrom(["uos"], .doesNotContain), info))
        XCTAssertFalse(matches(.downloadedFrom(["uos.ac.kr"]), .fixture("local.pdf")), "no source, no match")
    }

    func testTagsHaveAndHaveNot() {
        let info = FolderRuleFileInfo.fixture("a.pdf", tags: ["Receipt", "Red"])
        XCTAssertTrue(matches(.tags(.has, ["receipt"]), info))
        XCTAssertTrue(matches(.tags(.has, ["Work", "Red"]), info))
        XCTAssertFalse(matches(.tags(.has, ["Work"]), info))
        XCTAssertTrue(matches(.tags(.hasNot, ["Work"]), info))
        XCTAssertFalse(matches(.tags(.hasNot, ["Work", "RED"]), info))
    }

    func testAllAnyNoneAndTheTopLevelDefault() {
        let screenshot = FolderRuleFileInfo.fixture("Shot.png", kind: "public.png", screenshot: true)
        let both = [FolderRuleCondition.kind(.screenshot), .name(.contains, ["invoice"])]
        XCTAssertFalse(FolderRuleMatcher.matches(rule(both), screenshot, now: now))
        XCTAssertTrue(FolderRuleMatcher.matches(rule(both, match: .any), screenshot, now: now))
        XCTAssertFalse(FolderRuleMatcher.matches(rule(both, match: .none), screenshot, now: now))
        XCTAssertTrue(FolderRuleMatcher.matches(rule([.name(.contains, ["invoice"])], match: .none), screenshot, now: now))
        XCTAssertEqual(FolderRuleMatcher.evaluate(rule(both), screenshot, now: now), [true, false])
        XCTAssertFalse(FolderRuleMatcher.matches(rule([]), screenshot, now: now), "a rule without conditions never matches")
        let nested = FolderRuleFileInfo.fixture("Deep.png", kind: "public.png", screenshot: true, depth: 1)
        XCTAssertFalse(FolderRuleMatcher.matches(rule([.kind(.screenshot)]), nested, now: now), "top level only by default")
        XCTAssertTrue(FolderRuleMatcher.matches(rule([.kind(.screenshot)], subfolders: true), nested, now: now))
    }

    func testRuleProblemsBlockIncompleteRules() {
        XCTAssertEqual(rule([]).problems.first, "Add at least one condition.")
        XCTAssertTrue(rule([.name(.contains, [" "])]).problems.contains("Name: add a value."))
        XCTAssertTrue(rule([.namePattern("[")]).problems.contains { $0.contains("isn't a valid pattern") })
        var trashFirst = rule([.kind(.pdf)])
        trashFirst.actions = [.moveToTrash, .addTags(["x"])]
        XCTAssertTrue(trashFirst.problems.contains { $0.contains("must be the last action") })
        var move = rule([.kind(.pdf)])
        move.actions = [.move(to: "relative/path")]
        XCTAssertTrue(move.problems.contains { $0.contains("full path") })
        move.actions = [.move(to: "/tmp", subfolders: "{weekday}")]
        XCTAssertTrue(move.problems.contains { $0.contains("{weekday}") })
        XCTAssertEqual(rule([.kind(.pdf)]).problems, [])
    }

    // MARK: Metadata decoders

    func testWhereFromsDecodeFromTheBinaryPropertyListBrowsersWrite() throws {
        // The exact layout Safari and Chrome write: a binary plist array of strings.
        let urls = ["https://dl.example.com/files/App-1.2.dmg", "https://example.com/download"]
        let data = try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        XCTAssertEqual(Array(data.prefix(8)), Array("bplist00".utf8))
        XCTAssertEqual(FolderRuleMetadata.decodeWhereFroms(data), urls)
        XCTAssertEqual(FolderRuleMetadata.hosts(from: urls), ["dl.example.com", "example.com"])
        // Hand-written bytes: bplist00, an array of one ASCII string "http://a.kr".
        var fixture = Array("bplist00".utf8)
        fixture += [0xA1, 0x01, 0x5B] + Array("http://a.kr".utf8)
        let offsets: [UInt8] = [0x08, 0x0A]
        let tableOffset = UInt8(fixture.count)
        fixture += offsets
        fixture += [0, 0, 0, 0, 0, 0, 1, 1] + [0, 0, 0, 0, 0, 0, 0, 2] + [0, 0, 0, 0, 0, 0, 0, 0] + [0, 0, 0, 0, 0, 0, 0, tableOffset]
        XCTAssertEqual(FolderRuleMetadata.decodeWhereFroms(Data(fixture)), ["http://a.kr"])
        XCTAssertEqual(FolderRuleMetadata.decodeWhereFroms(Data("not a plist".utf8)), [])
        let single = try PropertyListSerialization.data(fromPropertyList: "https://one.example", format: .binary, options: 0)
        XCTAssertEqual(FolderRuleMetadata.decodeWhereFroms(single), ["https://one.example"])
    }

    func testScreenshotFlagLastUsedDateAndFinderCopyMarker() throws {
        // `xattr -px com.apple.metadata:kMDItemIsScreenCapture` on a real screenshot.
        let flag = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x09, 0x08, 0, 0, 0, 0, 0, 0, 1, 1,
                         0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09])
        XCTAssertEqual(FolderRuleMetadata.decodeBool(flag), true)
        XCTAssertNil(FolderRuleMetadata.decodeBool(Data([1, 2, 3])))
        var timespec = Data()
        withUnsafeBytes(of: Int64(1_761_905_670).littleEndian) { timespec.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(500_000_000).littleEndian) { timespec.append(contentsOf: $0) }
        XCTAssertEqual(FolderRuleMetadata.decodeLastUsedDate(timespec)?.timeIntervalSince1970 ?? 0, 1_761_905_670.5, accuracy: 0.001)
        XCTAssertNil(FolderRuleMetadata.decodeLastUsedDate(Data(count: 8)))
        var finder = Data("brokMACS".utf8)
        finder.append(Data(count: 24))
        XCTAssertTrue(FolderRuleMetadata.isFinderCopyInProgress(finder))
        XCTAssertFalse(FolderRuleMetadata.isFinderCopyInProgress(Data(count: 32)))
    }

    func testTheReaderSkipsUnfinishedDownloadsHiddenItemsAndLinks() throws {
        let kit = try FolderRulesTestKit()
        defer { kit.remove() }
        for name in ["Movie.mp4.crdownload", "Report.pdf.download", "iso.part", "big.partial"] {
            try kit.write(name)
            XCTAssertTrue(FolderRuleFileReader.isInProgressName(name))
            XCTAssertNil(FolderRuleFileReader.read(kit.watched.appendingPathComponent(name)), name)
        }
        try kit.write(".hidden")
        XCTAssertNil(FolderRuleFileReader.read(kit.watched.appendingPathComponent(".hidden")))
        let target = try kit.write("real.txt")
        let link = kit.watched.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(FolderRuleFileReader.read(link), "links are never acted on")
        let copying = try kit.write("copying.mov")
        var finderInfo = Data("brokMACS".utf8)
        finderInfo.append(Data(count: 24))
        XCTAssertTrue(FolderRuleMetadata.setAttribute(FolderRuleMetadata.finderInfoAttribute, finderInfo, at: copying.path))
        XCTAssertNil(FolderRuleFileReader.read(copying), "Finder is still copying it")
        let whereFroms = try PropertyListSerialization.data(fromPropertyList: ["https://github.com/a.zip"], format: .binary, options: 0)
        let zip = try kit.write("a.zip")
        XCTAssertTrue(FolderRuleMetadata.setAttribute(FolderRuleMetadata.whereFromsAttribute, whereFroms, at: zip.path))
        let info = try XCTUnwrap(FolderRuleFileReader.read(zip))
        XCTAssertEqual(info.downloadHosts, ["github.com"])
        XCTAssertEqual(info.contentType, "public.zip-archive")
        XCTAssertGreaterThan(info.inode, 0)
        guard case .success(let listed) = FolderRuleFileReader.list(kit.watched, includeSubfolders: false) else {
            return XCTFail("the folder lists")
        }
        XCTAssertFalse(listed.contains { $0.url.lastPathComponent == ".hidden" })
    }

    func testListingNeverEntersPackagesAndReportsMissingFolders() throws {
        let kit = try FolderRulesTestKit()
        defer { kit.remove() }
        try kit.write("inner.txt", in: kit.watched.appendingPathComponent("Sub", isDirectory: true))
        try kit.write("Info.plist", in: kit.watched.appendingPathComponent("Tool.app/Contents", isDirectory: true))
        guard case .success(let deep) = FolderRuleFileReader.list(kit.watched, includeSubfolders: true) else { return XCTFail() }
        let names = deep.map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains("inner.txt"))
        XCTAssertTrue(names.contains("Tool.app"))
        XCTAssertFalse(names.contains("Contents"), "nothing inside a package")
        XCTAssertEqual(deep.first { $0.url.lastPathComponent == "inner.txt" }?.depth, 1)
        guard case .success(let top) = FolderRuleFileReader.list(kit.watched, includeSubfolders: false) else { return XCTFail() }
        XCTAssertFalse(top.contains { $0.url.lastPathComponent == "inner.txt" })
        XCTAssertTrue(FolderRuleFileReader.isInsidePackage(kit.watched.appendingPathComponent("Tool.app/Contents")))
        let missing = FolderRuleFileReader.list(kit.root.appendingPathComponent("Nope"), includeSubfolders: false)
        XCTAssertEqual(missing.failureValue, .missing)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
