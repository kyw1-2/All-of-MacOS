import XCTest
@testable import AllOfMacOS

// MARK: - Mock network session

final class MockNetworkSession: NetworkSession, @unchecked Sendable {
    var dataHandler: ((URL) throws -> (Data, URLResponse))?
    var downloadHandler: ((URL) throws -> (URL, URLResponse))?

    func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        guard let handler = dataHandler else {
            throw URLError(.badServerResponse)
        }
        return try handler(url)
    }

    func downloadFile(from url: URL) async throws -> (URL, URLResponse) {
        guard let handler = downloadHandler else {
            throw URLError(.badServerResponse)
        }
        return try handler(url)
    }
}

// MARK: - Version comparison tests

final class UpdateCheckerVersionTests: XCTestCase {

    func testNewerMajorVersion() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.5.4"))
    }

    func testNewerMinorVersion() {
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0", than: "1.5.4"))
    }

    func testNewerPatchVersion() {
        XCTAssertTrue(UpdateChecker.isNewer("1.5.5", than: "1.5.4"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.5.4", than: "1.5.4"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.4.0", than: "1.5.4"))
    }

    func testOlderPatchIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.5.3", than: "1.5.4"))
    }

    func testMalformedVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("abc", than: "1.5.4"))
    }

    func testMalformedLocalVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: "abc"))
    }

    func testPartialVersionPadded() {
        // "2.0" should be treated as "2.0.0"
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.5.4"))
    }

    func testPartialLocalVersionPadded() {
        // "1.5" treated as "1.5.0" — older than "1.5.4"
        XCTAssertFalse(UpdateChecker.isNewer("1.5", than: "1.5.4"))
    }

    func testEmptyVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.5.4"))
    }

    func testBothZeroIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.0.0", than: "0.0.0"))
    }

    func testMajorBumpWithHigherLocal() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.99.99"))
    }
}

// MARK: - Update check tests (mocked network)

@MainActor
final class UpdateCheckerNetworkTests: XCTestCase {

    private func makeReleaseJSON(tag: String, dmgURL: String = "https://example.com/AllOfMacOS.dmg") -> Data {
        """
        {
            "tag_name": "\(tag)",
            "assets": [
                {
                    "name": "AllOfMacOS.dmg",
                    "browser_download_url": "\(dmgURL)"
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private func makeReleaseJSONWithoutDMG(tag: String) -> Data {
        """
        {
            "tag_name": "\(tag)",
            "assets": [
                {
                    "name": "source.tar.gz",
                    "browser_download_url": "https://example.com/source.tar.gz"
                }
            ]
        }
        """.data(using: .utf8)!
    }

    func testCheckForUpdate_newerAvailable() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = self.makeReleaseJSON(tag: "v2.0.0")
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .available(let version, let url) = checker.status {
            XCTAssertEqual(version, "2.0.0")
            XCTAssertEqual(url.absoluteString, "https://example.com/AllOfMacOS.dmg")
        } else {
            XCTFail("Expected .available, got \(checker.status)")
        }
    }

    func testCheckForUpdate_upToDate() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = self.makeReleaseJSON(tag: "v1.5.4")
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        XCTAssertEqual(checker.status, .upToDate)
    }

    func testCheckForUpdate_olderRelease() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = self.makeReleaseJSON(tag: "v1.4.0")
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        XCTAssertEqual(checker.status, .upToDate)
    }

    func testCheckForUpdate_noDMGAsset() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = self.makeReleaseJSONWithoutDMG(tag: "v2.0.0")
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .error(let msg) = checker.status {
            XCTAssertTrue(msg.contains("No DMG"))
        } else {
            XCTFail("Expected .error, got \(checker.status)")
        }
    }

    func testCheckForUpdate_networkError() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .error = checker.status {
            // Expected
        } else {
            XCTFail("Expected .error, got \(checker.status)")
        }
    }

    func testCheckForUpdate_malformedJSON() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = "not json at all".data(using: .utf8)!
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .error = checker.status {
            // Expected
        } else {
            XCTFail("Expected .error, got \(checker.status)")
        }
    }

    func testCheckForUpdate_emptyAssets() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = """
            { "tag_name": "v2.0.0", "assets": [] }
            """.data(using: .utf8)!
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .error(let msg) = checker.status {
            XCTAssertTrue(msg.contains("No DMG"))
        } else {
            XCTFail("Expected .error for empty assets, got \(checker.status)")
        }
    }

    func testCheckForUpdate_tagWithoutVPrefix() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let data = self.makeReleaseJSON(tag: "2.0.0")
            return (data, HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let checker = UpdateChecker(session: mock, currentVersion: "1.5.4")
        await checker.checkForUpdate()

        if case .available(let version, _) = checker.status {
            XCTAssertEqual(version, "2.0.0")
        } else {
            XCTFail("Expected .available, got \(checker.status)")
        }
    }
}

// MARK: - Published tag formats and policy (audit 2026-10-28 F11)

@MainActor
final class UpdatePolicyTests: XCTestCase {
    func testPublishedTagsParseToVersionAndBuild() {
        XCTAssertEqual(AOMReleaseTag("aom-v3.3.0-b2026102801-ge83fb23d936e"), AOMReleaseTag(version: "3.3.0", build: "2026102801"))
        XCTAssertEqual(AOMReleaseTag("aom-dev-v1.6.0-b2026101701-abcdef123456"), AOMReleaseTag(version: "1.6.0", build: "2026101701"))
        XCTAssertEqual(AOMReleaseTag("v1.5.4"), AOMReleaseTag(version: "1.5.4", build: nil))
        XCTAssertNil(AOMReleaseTag("aom-v3.3.0"), "an incomplete published tag is rejected")
        XCTAssertNil(AOMReleaseTag("nightly"))
    }

    /// The audit's UpdateProbe: both comparisons answered "not newer".
    func testRealReleasesAreRecognisedAsNewer() throws {
        let current = try XCTUnwrap(AOMReleaseTag("aom-v3.3.0-b2026102801-ge83fb23d936e"))
        XCTAssertTrue(UpdateChecker.isNewer(current, thanVersion: "3.2.0", build: "2026102706"))
        let major = try XCTUnwrap(AOMReleaseTag("aom-v4.0.0-b2026102901-gabcdef"))
        XCTAssertTrue(UpdateChecker.isNewer(major, thanVersion: "3.3.0", build: "2026102801"))
        let rebuild = try XCTUnwrap(AOMReleaseTag("aom-v3.3.0-b2026102802-g0123456789ab"))
        XCTAssertTrue(UpdateChecker.isNewer(rebuild, thanVersion: "3.3.0", build: "2026102801"), "same version, later build")
        XCTAssertFalse(UpdateChecker.isNewer(current, thanVersion: "3.3.0", build: "2026102801"), "the installed build itself")
        XCTAssertFalse(UpdateChecker.isNewer(current, thanVersion: "3.3.1", build: "2026102701"), "an older version with a later build number is not newer")
    }

    func testTheRealSessionNeverClaimsToBeUpToDate() async {
        let checker = UpdateChecker(currentVersion: "0.0.1")
        XCTAssertEqual(checker.status, .notChecked, "nothing is claimed before a check")
        await checker.checkForUpdate()
        XCTAssertEqual(checker.status, .disabled(UpdateChecker.disabledReason), "3.3.0 answered .upToDate without checking")
    }

    func testAMockedPublishedReleaseIsOffered() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            let json = #"{"tag_name":"aom-v3.3.1-b2026102802-g0123456789ab","assets":[{"name":"All-of-MacOS-3.3.1.dmg","browser_download_url":"https://example.com/a.dmg"}]}"#
            return (Data(json.utf8), HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let checker = UpdateChecker(session: mock, currentVersion: "3.3.0", currentBuild: "2026102801")
        await checker.checkForUpdate()
        XCTAssertEqual(checker.status, .available(version: "3.3.1", downloadURL: URL(string: "https://example.com/a.dmg")!))
    }

    func testAnHTTPErrorIsAnErrorNotUpToDate() async {
        let mock = MockNetworkSession()
        mock.dataHandler = { _ in
            (Data(#"{"message":"Not Found"}"#.utf8), HTTPURLResponse(url: UpdateChecker.releaseURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let checker = UpdateChecker(session: mock, currentVersion: "3.3.0")
        await checker.checkForUpdate()
        XCTAssertEqual(checker.status, .error("GitHub answered 404."))
    }
}

extension AOMReleaseTag {
    init(version: String, build: String?) {
        self = AOMReleaseTag(build.map { "aom-v\(version)-b\($0)-gtest" } ?? version)!
    }
}

// MARK: - GitHubRelease model tests

final class GitHubReleaseTests: XCTestCase {

    func testVersionStripsVPrefix() {
        let release = try! JSONDecoder().decode(GitHubRelease.self, from: """
        { "tag_name": "v1.5.4", "assets": [] }
        """.data(using: .utf8)!)
        XCTAssertEqual(release.version, "1.5.4")
    }

    func testVersionWithoutPrefix() {
        let release = try! JSONDecoder().decode(GitHubRelease.self, from: """
        { "tag_name": "1.5.4", "assets": [] }
        """.data(using: .utf8)!)
        XCTAssertEqual(release.version, "1.5.4")
    }

    func testDmgURLFound() {
        let release = try! JSONDecoder().decode(GitHubRelease.self, from: """
        {
            "tag_name": "v1.0.0",
            "assets": [
                { "name": "source.zip", "browser_download_url": "https://example.com/source.zip" },
                { "name": "AllOfMacOS.dmg", "browser_download_url": "https://example.com/App.dmg" }
            ]
        }
        """.data(using: .utf8)!)
        XCTAssertEqual(release.dmgURL?.absoluteString, "https://example.com/App.dmg")
    }

    func testDmgURLNilWhenMissing() {
        let release = try! JSONDecoder().decode(GitHubRelease.self, from: """
        {
            "tag_name": "v1.0.0",
            "assets": [
                { "name": "source.zip", "browser_download_url": "https://example.com/source.zip" }
            ]
        }
        """.data(using: .utf8)!)
        XCTAssertNil(release.dmgURL)
    }
}
