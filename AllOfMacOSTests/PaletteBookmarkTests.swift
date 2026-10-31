import XCTest
@testable import AllOfMacOS

/// Browser bookmarks (Fastmarks parity): Chrome's per-profile JSON and
/// Safari's Bookmarks.plist from fixtures, profile names from Local State,
/// search, and the loader on a temporary home folder (never the user's).
final class PaletteBookmarkTests: XCTestCase {
    private let chrome = PaletteBrowser.chromiumFamily[0]

    private func chromeJSON() -> Data {
        let json = """
        {
          "checksum": "x", "version": 1,
          "roots": {
            "bookmark_bar": { "name": "Bookmarks bar", "type": "folder", "children": [
              { "type": "url", "name": "GitHub", "url": "https://github.com/", "guid": "g1" },
              { "type": "folder", "name": "Dev", "children": [
                { "type": "url", "name": "Swift Forums", "url": "https://forums.swift.org/", "guid": "g2" },
                { "type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)", "guid": "g3" }
              ]}
            ]},
            "other": { "name": "", "type": "folder", "children": [
              { "type": "url", "name": "", "url": "https://www.uos.ac.kr/main", "guid": "g4" },
              { "type": "url", "name": "Settings", "url": "chrome://settings", "guid": "g5" }
            ]},
            "synced": { "name": "Mobile bookmarks", "type": "folder", "children": [] }
          }
        }
        """
        return Data(json.utf8)
    }

    private func safariPlist() throws -> Data {
        let root: [String: Any] = [
            "Title": "", "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["Title": "History", "WebBookmarkType": "WebBookmarkTypeProxy"],
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://www.apple.com/kr/",
                     "URIDictionary": ["title": "Apple (대한민국)"], "WebBookmarkUUID": "s1"],
                    ["Title": "School", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://portal.uos.ac.kr/",
                         "URIDictionary": ["title": "UOS Portal"], "WebBookmarkUUID": "s2"],
                    ]],
                ]],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "file:///etc/hosts",
                     "URIDictionary": ["title": "Hosts"], "WebBookmarkUUID": "s3"],
                ]],
                ["Title": "com.apple.ReadingList", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.com/article",
                     "URIDictionary": ["title": "An article"], "WebBookmarkUUID": "s4", "ReadingList": ["PreviewText": "…"]],
                ]],
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func testChromeBookmarksWithFoldersAndOnlyWebPages() throws {
        let bookmarks = try PaletteBookmarkParser.chrome(chromeJSON(), browser: chrome, profileDirectory: "Profile 1",
                                                         profileName: "Work")
        XCTAssertEqual(bookmarks.map(\.title), ["GitHub", "Swift Forums", "www.uos.ac.kr"],
                       "bookmarklets and chrome:// pages are left out; an untitled bookmark shows its host")
        XCTAssertEqual(bookmarks[1].folder, ["Bookmarks bar", "Dev"])
        XCTAssertEqual(bookmarks[2].folder, ["Other bookmarks"], "an unnamed root gets Chrome's name")
        XCTAssertEqual(bookmarks[0].profileDirectory, "Profile 1")
        XCTAssertEqual(bookmarks[0].profileName, "Work")
        XCTAssertEqual(bookmarks[0].id, "com.google.Chrome|Profile 1|g1")
        XCTAssertEqual(bookmarks[0].browser, chrome)
    }

    func testChromeRejectsOtherJSON() {
        XCTAssertThrowsError(try PaletteBookmarkParser.chrome(Data("{\"a\": 1}".utf8), browser: chrome, profileDirectory: "Default",
                                                              profileName: nil))
        XCTAssertThrowsError(try PaletteBookmarkParser.chrome(Data("not json".utf8), browser: chrome, profileDirectory: "Default",
                                                              profileName: nil))
    }

    func testSafariBookmarksFavoritesFoldersAndReadingList() throws {
        let bookmarks = try PaletteBookmarkParser.safari(safariPlist())
        XCTAssertEqual(bookmarks.map(\.title), ["Apple (대한민국)", "UOS Portal", "An article"],
                       "History is skipped and file: links are left out")
        XCTAssertEqual(bookmarks[0].folder, ["Favorites"], "BookmarksBar is Favorites")
        XCTAssertEqual(bookmarks[1].folder, ["Favorites", "School"])
        XCTAssertEqual(bookmarks[2].folder, ["Reading List"])
        XCTAssertEqual(bookmarks[0].browser, .safari)
        XCTAssertNil(bookmarks[0].profileDirectory)
        XCTAssertThrowsError(try PaletteBookmarkParser.safari(Data("<plist/>".utf8)))
    }

    func testProfilesFromLocalState() {
        let localState = Data("""
        {"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 4": {"name": "School"}, "Profile 9": {}}}}
        """.utf8)
        let profiles = PaletteBookmarkParser.chromeProfiles(localState: localState,
                                                            folders: ["Profile 9", "Default", "Guest Profile", "System Profile",
                                                                      "Profile 4", "Crashpad", "Local State"])
        XCTAssertEqual(profiles.map(\.directory), ["Default", "Profile 4", "Profile 9"])
        XCTAssertEqual(profiles.map(\.name), ["Personal", "School", nil])
        XCTAssertEqual(PaletteBookmarkParser.chromeProfiles(localState: nil, folders: ["Default"]).first?.name, nil)
    }

    func testSearchRanksTitlesThenHostsAndKeepsOnePerProfileURL() throws {
        let work = try PaletteBookmarkParser.chrome(chromeJSON(), browser: chrome, profileDirectory: "Profile 1", profileName: "Work")
        let home = try PaletteBookmarkParser.chrome(chromeJSON(), browser: chrome, profileDirectory: "Default", profileName: "Home")
        let safari = try PaletteBookmarkParser.safari(safariPlist())
        let all = work + work + home + safari
        XCTAssertEqual(PaletteBookmarkSearch.results(all, query: "git").map(\.title), ["GitHub", "GitHub"],
                       "the same URL twice in one profile shows once; another profile shows again")
        XCTAssertEqual(PaletteBookmarkSearch.results(all, query: "uos").first?.title, "UOS Portal", "a title beats a host")
        XCTAssertTrue(PaletteBookmarkSearch.results(all, query: "uos").contains { $0.title == "www.uos.ac.kr" })
        XCTAssertEqual(PaletteBookmarkSearch.results(all, query: "대한").first?.title, "Apple (대한민국)")
        XCTAssertTrue(PaletteBookmarkSearch.results(all, query: "g").isEmpty, "one letter is too little to search bookmarks")
        XCTAssertEqual(PaletteBookmarkSearch.results(all, query: "o", limit: 2).count, 0)
        XCTAssertEqual(PaletteBookmarkSearch.results(all, query: "or", limit: 1).count, 1)
    }

    // MARK: Loader

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aom-bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func testLoaderReadsEveryProfileAndSafariFromAHome() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let chromeRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        for profile in ["Default", "Profile 4"] {
            let folder = chromeRoot.appendingPathComponent(profile, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try chromeJSON().write(to: folder.appendingPathComponent("Bookmarks"))
        }
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 4":{"name":"School"}}}}"#.utf8)
            .write(to: chromeRoot.appendingPathComponent("Local State"))
        let safariFolder = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safariFolder, withIntermediateDirectories: true)
        try safariPlist().write(to: safariFolder.appendingPathComponent("Bookmarks.plist"))

        let loader = PaletteBookmarkLoader()
        loader.home = home
        loader.isInstalled = { $0 == "com.google.Chrome" || $0 == "com.apple.Safari" }
        let snapshot = loader.load()
        XCTAssertEqual(snapshot.safari, .readable)
        XCTAssertEqual(snapshot.bookmarks.filter { $0.browser == self.chrome }.count, 6, "three per profile")
        XCTAssertEqual(Set(snapshot.bookmarks.compactMap(\.profileName)), ["Personal", "School"])
        XCTAssertEqual(snapshot.bookmarks.filter { $0.browser == .safari }.count, 3)

        loader.isInstalled = { _ in false }
        XCTAssertTrue(loader.load().bookmarks.isEmpty, "browsers that aren't installed are not read")
    }

    func testLoaderReportsAMissingAndARefusedSafariFile() throws {
        let home = try makeHome()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: home.appendingPathComponent("Library/Safari/Bookmarks.plist").path)
            try? FileManager.default.removeItem(at: home)
        }
        let loader = PaletteBookmarkLoader()
        loader.home = home
        loader.isInstalled = { $0 == "com.apple.Safari" }
        XCTAssertEqual(loader.load().safari, .missing)

        let folder = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Bookmarks.plist")
        try safariPlist().write(to: file)
        // An unreadable file stands in for the Full Disk Access refusal.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        XCTAssertEqual(loader.load().safari, .needsFullDiskAccess)
    }

    func testLoaderKeepsAFileUntilItChanges() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Bookmarks")
        try chromeJSON().write(to: file)
        let loader = PaletteBookmarkLoader()
        loader.home = home
        loader.isInstalled = { $0 == "com.google.Chrome" }
        XCTAssertEqual(loader.load().bookmarks.count, 3)
        let fewer = Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"url","name":"A","url":"https://a.example/"}]}}}"#.utf8)
        try fewer.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(loader.load().bookmarks.map(\.title), ["A"], "a changed file is read again")
    }
}
