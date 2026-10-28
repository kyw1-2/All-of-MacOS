import Foundation
import AppKit

// MARK: - Network abstraction for testability

protocol NetworkSession: Sendable {
    func fetchData(from url: URL) async throws -> (Data, URLResponse)
    func downloadFile(from url: URL) async throws -> (URL, URLResponse)
}

extension URLSession: NetworkSession {
    func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        try await data(from: url)
    }

    func downloadFile(from url: URL) async throws -> (URL, URLResponse) {
        try await download(from: url)
    }
}

// MARK: - GitHub API models

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: String {
        AOMReleaseTag(tagName)?.version ?? (tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName)
    }

    var build: String? { AOMReleaseTag(tagName)?.build }

    var dmgURL: URL? {
        guard let asset = assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: asset.browserDownloadUrl) else { return nil }
        return url
    }
}

// MARK: - Release tags

/// A GitHub release tag as AOM publishes it: `aom-v<version>-b<build>-g<sha>`
/// from CI, `aom-dev-v<version>-b<build>-<hash>` from a local build, or a
/// plain `v1.2.3` / `1.2.3`. Until 3.3.1 only a leading "v" was stripped, so
/// `aom-v3.3.0-…` parsed as 3.0.0 and no real release was ever "newer"
/// (audit 2026-10-28 F11).
struct AOMReleaseTag: Equatable {
    let version: String
    let build: String?

    private static let published = try! NSRegularExpression(
        pattern: #"^aom(?:-dev)?-v([0-9]+(?:\.[0-9]+){1,3})-b([0-9]+)-[A-Za-z0-9]+$"#)

    init?(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let match = Self.published.firstMatch(in: trimmed, range: whole),
           let versionRange = Range(match.range(at: 1), in: trimmed),
           let buildRange = Range(match.range(at: 2), in: trimmed) {
            version = String(trimmed[versionRange])
            build = String(trimmed[buildRange])
            return
        }
        let plain = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard plain.range(of: #"^[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { return nil }
        version = plain
        build = nil
    }
}

// MARK: - Update status

enum UpdateStatus: Equatable {
    /// No check has run. Never shown as "up to date".
    case notChecked
    /// This build does not contact the network for updates (policy).
    case disabled(String)
    case upToDate
    case available(version: String, downloadURL: URL)
    case checking
    case downloading(progress: Double)
    case error(String)
}

// MARK: - UpdateChecker

/// Distribution policy (3.3.1, audit 2026-10-28 F11): AOM is published as a
/// self-signed (AOM Dev), non-notarized DMG on GitHub Releases and installed
/// by hand (or by the owner's signature-pinned scripts/auto-update-mac.sh).
/// The app itself never contacts the network to look for updates, so with
/// the real URL session `checkForUpdate()` reports `.disabled` — it used to
/// report `.upToDate` without checking anything.
@MainActor
class UpdateChecker: ObservableObject {
    @Published var status: UpdateStatus = .notChecked

    private let session: NetworkSession
    private let currentVersion: String
    private let currentBuild: String?
    private var checkTimer: Timer?

    static let releaseURL = URL(string: "https://api.github.com/repos/kyw1-2/All-of-MacOS/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/kyw1-2/All-of-MacOS/releases")!
    static let disabledReason = "This build does not check for updates. New versions are published on GitHub Releases."

    init(session: NetworkSession = URLSession.shared,
         currentVersion: String? = nil, currentBuild: String? = nil) {
        self.session = session
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        self.currentBuild = currentBuild ?? (currentVersion == nil ? Bundle.main.infoDictionary?["CFBundleVersion"] as? String : nil)
    }

    /// Newer by version, or by build number for the same version.
    nonisolated static func isNewer(_ remote: AOMReleaseTag, thanVersion local: String, build localBuild: String?) -> Bool {
        if isNewer(remote.version, than: local) { return true }
        guard !isNewer(local, than: remote.version), let remoteBuild = remote.build.flatMap(Int.init),
              let ownBuild = localBuild.flatMap(Int.init) else { return false }
        return remoteBuild > ownBuild
    }

    // MARK: - Version comparison

    /// Returns true if `remote` is a newer semver than `local`.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        // Must have at least one valid numeric component
        guard !remoteParts.isEmpty, !localParts.isEmpty else { return false }

        // Pad to 3 components
        let r = remoteParts + Array(repeating: 0, count: max(0, 3 - remoteParts.count))
        let l = localParts + Array(repeating: 0, count: max(0, 3 - localParts.count))

        for i in 0..<3 {
            if r[i] > l[i] { return true }
            if r[i] < l[i] { return false }
        }
        return false
    }

    // MARK: - Check for updates

    func checkForUpdate() async {
        // Policy: no network update checks from the app. Say so instead of
        // claiming to be up to date.
        if session is URLSession {
            status = .disabled(Self.disabledReason)
            return
        }
        status = .checking
        do {
            let (data, response) = try await session.fetchData(from: Self.releaseURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status = .error("GitHub answered \(http.statusCode).")
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let tag = AOMReleaseTag(release.tagName) else {
                // Not knowing is not "up to date".
                status = .error("Unrecognised release tag “\(release.tagName)”.")
                return
            }
            guard Self.isNewer(tag, thanVersion: currentVersion, build: currentBuild) else {
                status = .upToDate
                return
            }

            guard let dmgURL = release.dmgURL else {
                status = .error("No DMG found in release")
                return
            }

            status = .available(version: release.version, downloadURL: dmgURL)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Periodic checks (Disabled for local custom build)

    func startPeriodicChecks(interval: TimeInterval = 3600) {
        // Disabled: do not poll GitHub in background
    }

    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
}
