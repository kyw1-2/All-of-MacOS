import AppKit
import XCTest
@testable import AllOfMacOS

/// The Open and Save dialog helper's pure rules: classifying Accessibility
/// snapshots, the folder a jump goes to, the clipboard's path and where the
/// panel sits beside a dialog. No live dialogs, no Accessibility, no events.
@MainActor
final class FilesDialogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-files-dialog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Classification (snapshots as macOS 27.2 reports them)

    func testInProcessOpenPanelIsAnOpenDialog() {
        let snapshot = FilesDialogSnapshot(role: "AXWindow", subrole: "AXStandardWindow", identifier: "open-panel", title: "Open")
        XCTAssertEqual(FilesDialogClassifier.classify(snapshot), FilesDialogClassification(kind: .open, isSheet: false, isRemote: false))
    }

    func testSaveSheetIsASaveDialogOnASheet() {
        let snapshot = FilesDialogSnapshot(role: "AXSheet", subrole: nil, identifier: "save-panel", title: nil, roleDescription: "save",
                                           containsPanelServiceContent: true)
        XCTAssertEqual(FilesDialogClassifier.classify(snapshot), FilesDialogClassification(kind: .save, isSheet: true, isRemote: true))
    }

    func testRemotePanelWithoutIdentifiersIsRecognised() {
        var open = FilesDialogSnapshot(role: "AXWindow", subrole: "AXDialog", identifier: nil, title: "Open")
        open.ownedByPanelService = true
        open.buttonTitles = ["Cancel", "Open"]
        XCTAssertEqual(FilesDialogClassifier.classify(open), FilesDialogClassification(kind: .open, isSheet: false, isRemote: true))

        var save = open
        save.descendantIdentifiers = ["saveAsNameTextField"]
        XCTAssertEqual(FilesDialogClassifier.classify(save)?.kind, .save)

        var korean = open
        korean.buttonTitles = ["취소", "열기"]
        XCTAssertEqual(FilesDialogClassifier.classify(korean)?.kind, .open)
    }

    func testPanelControlsClassifyAPanelWithoutAWindowIdentifier() {
        var open = FilesDialogSnapshot(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, title: "Choose a File")
        open.descendantIdentifiers = ["OKButton", "CancelButton", "where popup"]
        XCTAssertEqual(FilesDialogClassifier.classify(open)?.kind, .open)

        var save = FilesDialogSnapshot(role: "AXSheet", identifier: nil)
        save.descendantIdentifiers = ["OKButton", "CancelButton", "saveAsNameTextField", "where popup"]
        XCTAssertEqual(FilesDialogClassifier.classify(save), FilesDialogClassification(kind: .save, isSheet: true, isRemote: false))
    }

    func testOtherWindowsAreNotDialogs() {
        // A document window, a settings window with OK and Cancel, an alert
        // sheet, a button and the Go to Folder sheet the helper opens itself.
        XCTAssertNil(FilesDialogClassifier.classify(FilesDialogSnapshot(role: "AXWindow", subrole: "AXStandardWindow",
                                                                         identifier: nil, title: "Untitled")))
        var settings = FilesDialogSnapshot(role: "AXWindow", subrole: "AXDialog", identifier: nil, title: "Settings")
        settings.descendantIdentifiers = ["OKButton", "CancelButton"]
        settings.buttonTitles = ["OK", "Cancel"]
        XCTAssertNil(FilesDialogClassifier.classify(settings))
        var alert = FilesDialogSnapshot(role: "AXSheet", identifier: nil)
        alert.buttonTitles = ["Cancel", "Delete"]
        XCTAssertNil(FilesDialogClassifier.classify(alert))
        XCTAssertNil(FilesDialogClassifier.classify(FilesDialogSnapshot(role: "AXButton", identifier: "open-panel")))
        let goTo = FilesDialogSnapshot(role: "AXSheet", identifier: "GoToWindow")
        XCTAssertNil(FilesDialogClassifier.classify(goTo))
        XCTAssertTrue(FilesDialogClassifier.isGoToSheet(goTo))
        XCTAssertNil(FilesDialogClassifier.classify(FilesDialogSnapshot()))
    }

    // MARK: The folder a jump goes to

    func testTildeExpandsAgainstHome() throws {
        let projects = try makeFolder("Projects")
        XCTAssertEqual(FilesPath.jumpFolder(for: "~/Projects", home: folder.path)?.path, FilesPath.key(projects.path))
        XCTAssertEqual(FilesPath.jumpFolder(for: "~", home: folder.path)?.path, FilesPath.key(folder.path))
        XCTAssertEqual(FilesPath.expandTilde("~/a b", home: "/Users/x"), "/Users/x/a b")
        XCTAssertEqual(FilesPath.expandTilde("/already/absolute", home: "/Users/x"), "/already/absolute")
    }

    func testSpacesAndUnicodeStayIntact() throws {
        let spaced = try makeFolder("My Folder/과제 자료")
        XCTAssertEqual(FilesPath.jumpFolder(for: spaced.path)?.path, FilesPath.key(spaced.path))
        XCTAssertEqual(FilesPath.jumpFolder(for: "  \(spaced.path)\n")?.path, FilesPath.key(spaced.path))
    }

    func testSymlinksResolveToTheRealFolder() throws {
        let real = try makeFolder("Real")
        let link = folder.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(FilesPath.jumpFolder(for: link.path)?.path, FilesPath.key(real.path))
        XCTAssertEqual(FilesPath.key(link.path), FilesPath.key(real.path))
        XCTAssertEqual(FilesPath.key(real.path + "/"), FilesPath.key(real.path))
        XCTAssertEqual(FilesPath.key(real.path + "/../Real/."), FilesPath.key(real.path))
    }

    func testFilesAndPackagesGoToTheirFolder() throws {
        let documents = try makeFolder("Documents")
        let file = documents.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        XCTAssertEqual(FilesPath.jumpFolder(for: file.path)?.path, FilesPath.key(documents.path))
        let app = try makeFolder("Documents/Sample.app")
        XCTAssertTrue(FilesPath.isPackage(app))
        XCTAssertEqual(FilesPath.jumpFolder(for: app.path)?.path, FilesPath.key(documents.path))
    }

    func testMissingAndRelativePathsHaveNoFolder() {
        XCTAssertNil(FilesPath.jumpFolder(for: folder.appendingPathComponent("nope").path))
        XCTAssertNil(FilesPath.jumpFolder(for: "Documents/report.pdf"))
        XCTAssertNil(FilesPath.jumpFolder(for: ""))
        XCTAssertNil(FilesPath.jumpFolder(for: "~nosuchuser-aom/x", home: folder.path))
    }

    // MARK: The clipboard's path

    func testFileURLOnTheClipboardUsesItsFolder() throws {
        let documents = try makeFolder("Docs")
        let file = documents.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(FilesClipboardPath.folder(fileURLs: [file], string: "ignored")?.path, FilesPath.key(documents.path))
        XCTAssertEqual(FilesClipboardPath.folder(fileURLs: [documents], string: nil)?.path, FilesPath.key(documents.path))
    }

    func testPathTextInTheSpellingsPeopleCopy() throws {
        let target = try makeFolder("My Folder")
        let expected = FilesPath.key(target.path)
        for text in [target.path, "\(target.path)/", "'\(target.path)'", "\"\(target.path)\"", "“\(target.path)”",
                     target.path.replacingOccurrences(of: " ", with: "\\ "), target.absoluteString, "  \(target.path)  \n"] {
            XCTAssertEqual(FilesClipboardPath.folder(fileURLs: [], string: text)?.path, expected, text)
        }
        let home = folder.path
        XCTAssertEqual(FilesClipboardPath.folder(fileURLs: [], string: "~/My Folder", home: home)?.path, expected)
    }

    func testTextThatIsNotAPathIsIgnored() {
        for text in ["hello", "https://example.com/My%20Folder", "Documents/report.pdf", "\(folder.path)\n\(folder.path)",
                     folder.appendingPathComponent("missing").path, "", "   ", String(repeating: "/a", count: 2000)] {
            XCTAssertNil(FilesClipboardPath.folder(fileURLs: [], string: text), text)
        }
        XCTAssertNil(FilesClipboardPath.folder(fileURLs: [URL(string: "https://example.com")!], string: nil))
        XCTAssertEqual(FilesClipboardPath.unescapeShell("It\\'s\\ here\\"), "It's here\\")
    }

    // MARK: Where the panel goes

    func testPanelSitsRightOfTheDialogWhenThereIsRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = FilesScreenGeometry.frame(beside: CGRect(x: 300, y: 300, width: 700, height: 400),
                                              size: CGSize(width: 248, height: 360), visibleFrames: [screen])
        XCTAssertEqual(frame, CGRect(x: 1008, y: 340, width: 248, height: 360))
    }

    func testPanelMovesLeftThenInsideWhenTheRightIsFull() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 248, height: 300)
        let left = FilesScreenGeometry.frame(beside: CGRect(x: 1000, y: 300, width: 400, height: 300), size: size, visibleFrames: [screen])
        XCTAssertEqual(left.minX, 744)
        let inside = FilesScreenGeometry.frame(beside: CGRect(x: 0, y: 100, width: 1440, height: 700), size: size, visibleFrames: [screen])
        XCTAssertEqual(inside.maxX, 1440 - 8)
        XCTAssertTrue(screen.contains(inside))
    }

    func testPanelStaysOnTheDialogsScreenAndOnScreen() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let upper = CGRect(x: 0, y: 900, width: 1920, height: 1055)
        let dialog = CGRect(x: 760, y: 1500, width: 880, height: 448)
        let frame = FilesScreenGeometry.frame(beside: dialog, size: CGSize(width: 248, height: 600), visibleFrames: [main, upper])
        XCTAssertTrue(upper.contains(frame), "\(frame)")
        let tall = FilesScreenGeometry.frame(beside: CGRect(x: 100, y: 10, width: 300, height: 200), size: CGSize(width: 248, height: 2000),
                                             visibleFrames: [main])
        XCTAssertTrue(main.contains(tall), "\(tall)")
        let atPointer = FilesScreenGeometry.frame(at: CGPoint(x: 1430, y: 20), size: CGSize(width: 320, height: 280), visibleFrames: [main])
        XCTAssertTrue(main.contains(atPointer), "\(atPointer)")
        XCTAssertLessThan(atPointer.maxX, 1430)
    }

    func testAccessibilityRectsFlipToAppKit() {
        XCTAssertEqual(FilesScreenGeometry.cocoaRect(fromAX: CGRect(x: 520, y: 182, width: 880, height: 448), primaryHeight: 1080),
                       CGRect(x: 520, y: 450, width: 880, height: 448))
    }

    private func makeFolder(_ relative: String) throws -> URL {
        let url = folder.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
