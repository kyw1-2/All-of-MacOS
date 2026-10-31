import Foundation

/// Homebrew for the System Tools page (Raycast's Brew extension, design-3.4.0
/// b.16): locating `brew`, the argument arrays and environment AOM runs it
/// with, and parsers for its JSON and text answers. Nothing here runs a
/// process; `HomebrewModel` does that on a click, one job at a time.
enum Homebrew {
    /// Apple silicon first, then Intel.
    static let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func locate(candidates: [String] = candidatePaths,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// The environment for a brew run: the user's own, with a PATH that
    /// starts with brew's prefix (GUI apps get a bare PATH), no automatic
    /// `brew update` (Update is its own button; outdated must not take a
    /// minute), no colours and no hints in the log. The user's analytics
    /// and other HOMEBREW_ settings are left as they are.
    static func environment(base: [String: String], brew: URL, autoUpdate: Bool = false) -> [String: String] {
        var environment = base
        let bin = brew.deletingLastPathComponent().path
        let prefix = brew.deletingLastPathComponent().deletingLastPathComponent().path
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = [bin, prefix + "/sbin"]
        for entry in (base["PATH"] ?? "").split(separator: ":").map(String.init) + system where !path.contains(entry) && !entry.isEmpty {
            path.append(entry)
        }
        environment["PATH"] = path.joined(separator: ":")
        if autoUpdate { environment.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE") }
        else { environment["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        environment.removeValue(forKey: "HOMEBREW_COLOR")
        return environment
    }

    // MARK: - Packages

    enum Kind: String, Codable, CaseIterable, Sendable {
        case formula, cask
        var title: String { self == .formula ? "Formula" : "Cask" }
        /// The flag that tells brew which kind a name is.
        var flag: String { self == .formula ? "--formula" : "--cask" }
    }

    struct Package: Identifiable, Hashable, Sendable {
        let kind: Kind
        let name: String
        var id: String { "\(kind.rawValue):\(name)" }
    }

    struct OutdatedPackage: Identifiable, Hashable, Sendable {
        let package: Package
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool
        var id: String { package.id }
        var name: String { package.name }
        var kind: Kind { package.kind }
        /// "1.2 → 1.3" (the newest installed version).
        var change: String { "\(installedVersions.last ?? "?") → \(currentVersion)" }
    }

    struct InstalledPackage: Identifiable, Hashable, Sendable {
        let package: Package
        let version: String
        let summary: String
        let homepage: String?
        /// Formulae: installed by name rather than as a dependency.
        let onRequest: Bool
        let outdated: Bool
        let pinned: Bool
        var id: String { package.id }
        var name: String { package.name }
        var kind: Kind { package.kind }
    }

    struct Service: Identifiable, Hashable, Sendable {
        enum Status: Hashable, Sendable {
            case started, stopped, none, error, scheduled, other(String)
            init(_ raw: String) {
                switch raw.lowercased() {
                case "started": self = .started
                case "stopped": self = .stopped
                case "none": self = .none
                case "error": self = .error
                case "scheduled": self = .scheduled
                default: self = .other(raw)
                }
            }
            var title: String {
                switch self {
                case .started: return "Running"
                case .stopped: return "Stopped"
                case .none: return "Not started"
                case .error: return "Error"
                case .scheduled: return "Scheduled"
                case .other(let raw): return raw.capitalized
                }
            }
            var isRunning: Bool { self == .started || self == .scheduled }
        }
        let name: String
        let status: Status
        let user: String?
        let file: String?
        let exitCode: Int?
        var id: String { name }
    }

    enum ParseError: LocalizedError, Equatable {
        case notJSON(String)
        var errorDescription: String? {
            switch self {
            case .notJSON(let what): return "Homebrew's \(what) list wasn't readable JSON."
            }
        }
    }

    private static func object(_ data: Data, _ what: String) throws -> Any {
        // brew may print a warning line before the JSON when stderr and
        // stdout are merged; AOM keeps them apart, but be lenient anyway.
        if let value = try? JSONSerialization.jsonObject(with: data) { return value }
        if let text = String(data: data, encoding: .utf8),
           let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let value = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) { return value }
        throw ParseError.notJSON(what)
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `brew outdated --json=v2`: {"formulae": [{name, installed_versions,
    /// current_version, pinned, pinned_version}], "casks": [...]}.
    static func parseOutdated(_ data: Data) throws -> [OutdatedPackage] {
        guard let root = try object(data, "outdated") as? [String: Any] else { throw ParseError.notJSON("outdated") }
        var result: [OutdatedPackage] = []
        for (key, kind) in [("formulae", Kind.formula), ("casks", Kind.cask)] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                guard let name = string(entry["name"]), !name.isEmpty else { continue }
                let installed = (entry["installed_versions"] as? [Any] ?? []).compactMap(string)
                result.append(OutdatedPackage(package: Package(kind: kind, name: name), installedVersions: installed,
                                              currentVersion: string(entry["current_version"]) ?? "?",
                                              pinned: entry["pinned"] as? Bool ?? false))
            }
        }
        return result.sorted { ($0.kind == .formula ? 0 : 1, $0.name) < ($1.kind == .formula ? 0 : 1, $1.name) }
    }

    /// `brew info --json=v2 --installed`: formulae carry `installed` (one
    /// entry per installed version, newest last) and casks `installed` (the
    /// version string).
    static func parseInstalled(_ data: Data) throws -> [InstalledPackage] {
        guard let root = try object(data, "installed") as? [String: Any] else { throw ParseError.notJSON("installed") }
        var result: [InstalledPackage] = []
        for entry in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = string(entry["name"]), !name.isEmpty else { continue }
            let installs = entry["installed"] as? [[String: Any]] ?? []
            let newest = installs.last
            let version = newest.flatMap { string($0["version"]) }
                ?? ((entry["versions"] as? [String: Any]).flatMap { string($0["stable"]) } ?? "?")
            result.append(InstalledPackage(package: Package(kind: .formula, name: name), version: version,
                                           summary: string(entry["desc"]) ?? "", homepage: string(entry["homepage"]),
                                           onRequest: newest?["installed_on_request"] as? Bool ?? true,
                                           outdated: entry["outdated"] as? Bool ?? false,
                                           pinned: entry["pinned"] as? Bool ?? false))
        }
        for entry in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = string(entry["token"]), !token.isEmpty else { continue }
            let names = (entry["name"] as? [Any] ?? []).compactMap(string)
            let summary = string(entry["desc"]) ?? names.first ?? ""
            result.append(InstalledPackage(package: Package(kind: .cask, name: token),
                                           version: string(entry["installed"]) ?? string(entry["version"]) ?? "?",
                                           summary: summary, homepage: string(entry["homepage"]), onRequest: true,
                                           outdated: entry["outdated"] as? Bool ?? false, pinned: false))
        }
        return result.sorted { ($0.kind == .formula ? 0 : 1, $0.name) < ($1.kind == .formula ? 0 : 1, $1.name) }
    }

    /// `brew services list --json`: [{name, status, user, file, exit_code}].
    static func parseServices(_ data: Data) throws -> [Service] {
        guard let list = try object(data, "services") as? [[String: Any]] else { throw ParseError.notJSON("services") }
        return list.compactMap { entry in
            guard let name = string(entry["name"]), !name.isEmpty else { return nil }
            return Service(name: name, status: Service.Status(string(entry["status"]) ?? "none"),
                           user: string(entry["user"]), file: string(entry["file"]),
                           exitCode: (entry["exit_code"] as? NSNumber)?.intValue)
        }.sorted { $0.name < $1.name }
    }

    /// `brew search --formula|--cask <text>` without a terminal: one name
    /// per line, no headings. Lines that aren't names (a "No formulae or
    /// casks found" message, a warning) are dropped.
    static func parseSearch(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ✔", with: "") }
            .filter { isValidPackageName($0) && seen.insert($0).inserted }
    }

    /// The size `brew cleanup` reports: "This operation would free
    /// approximately 41.9MB of disk space." (dry run) or "... has freed
    /// approximately 1.2GB ...". Homebrew's units are 1024-based.
    struct FreedSize: Equatable, Sendable {
        let text: String
        let bytes: Int64
    }

    static func parseFreedSize(_ output: String) -> FreedSize? {
        let pattern = #"(?:would free|has freed) approximately ([0-9][0-9.,]*)\s*([KMGT]?B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let numberRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output) else { return nil }
        let number = String(output[numberRange]).replacingOccurrences(of: ",", with: "")
        let unit = String(output[unitRange])
        guard let value = Double(number) else { return nil }
        let multiplier: Double
        switch unit {
        case "KB": multiplier = 1024
        case "MB": multiplier = 1024 * 1024
        case "GB": multiplier = 1024 * 1024 * 1024
        case "TB": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return FreedSize(text: number + unit, bytes: Int64((value * multiplier).rounded()))
    }

    /// The items a dry-run cleanup lists ("Would remove: …").
    static func cleanupItemCount(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("Would remove") }.count
    }

    /// "Homebrew 7.0.9-70-g1397358-dirty" → "Homebrew 7.0.9".
    static func versionLine(_ output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isNewline).first.map(String.init),
              first.hasPrefix("Homebrew ") else { return nil }
        let version = first.dropFirst("Homebrew ".count)
        let core = version.split(separator: "-").first.map(String.init) ?? String(version)
        return "Homebrew " + core
    }

    /// A formula or cask name as brew writes it, optionally tap-qualified
    /// ("node@22", "homebrew/cask/iterm2"). Never starts with "-", so a typed
    /// name can't become an option.
    static func isValidPackageName(_ name: String) -> Bool {
        guard (1...200).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._/-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) } && !name.contains("..") && !name.hasSuffix("/")
    }

    /// Text typed into the search field: letters, digits and the name
    /// characters, at most 100.
    static func isValidSearchText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...100).contains(trimmed.count), !trimmed.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._/- ")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A run that needed `sudo` (some casks' installers) can't ask for a
    /// password without a terminal.
    static func neededTerminalPassword(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("sudo: a terminal is required") || text.contains("sudo: a password is required")
            || text.contains("no tty present")
    }

    // MARK: - Commands

    enum ServiceAction: String, CaseIterable, Sendable {
        case start, stop, restart
        var title: String { rawValue.capitalized }
        var progressive: String {
            switch self {
            case .start: return "Starting"
            case .stop: return "Stopping"
            case .restart: return "Restarting"
            }
        }
    }

    enum Command: Equatable, Sendable {
        case version
        case outdated
        case installed
        case services
        case search(String, Kind)
        case update
        case upgradeAll
        case upgrade(Package)
        case cleanupDryRun
        case cleanup
        case doctor
        case service(ServiceAction, String)
        case uninstall(Package)
        case install(Package)

        var arguments: [String] {
            switch self {
            case .version: return ["--version"]
            case .outdated: return ["outdated", "--json=v2"]
            case .installed: return ["info", "--json=v2", "--installed"]
            case .services: return ["services", "list", "--json"]
            case .search(let text, let kind): return ["search", kind.flag, text]
            case .update: return ["update"]
            case .upgradeAll: return ["upgrade"]
            case .upgrade(let package): return ["upgrade", package.kind.flag, package.name]
            case .cleanupDryRun: return ["cleanup", "-n", "-s"]
            case .cleanup: return ["cleanup", "-s"]
            case .doctor: return ["doctor"]
            case .service(let action, let name): return ["services", action.rawValue, name]
            case .uninstall(let package): return ["uninstall", package.kind.flag, package.name]
            case .install(let package): return ["install", package.kind.flag, package.name]
            }
        }

        /// Upgrades and installs download and build; reading lists is quick.
        var timeout: TimeInterval {
            switch self {
            case .version: return 30
            case .outdated, .installed, .search: return 180
            case .services, .service: return 120
            case .doctor: return 300
            case .update, .uninstall, .cleanupDryRun: return 600
            case .cleanup: return 1800
            case .upgradeAll, .upgrade, .install: return 3 * 3600
            }
        }

        /// Only `brew update` updates Homebrew itself.
        var autoUpdate: Bool { self == .update }

        /// Changes the Mac (the log is kept and the lists refresh after it).
        var changesPackages: Bool {
            switch self {
            case .update, .upgradeAll, .upgrade, .cleanup, .uninstall, .install, .service: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .version: return "Checking Homebrew"
            case .outdated: return "Checking for updates"
            case .installed: return "Reading installed packages"
            case .services: return "Reading services"
            case .search(let text, _): return "Searching for “\(text)”"
            case .update: return "Updating Homebrew"
            case .upgradeAll: return "Upgrading all packages"
            case .upgrade(let package): return "Upgrading \(package.name)"
            case .cleanupDryRun: return "Measuring what Clean Up frees"
            case .cleanup: return "Cleaning up"
            case .doctor: return "Running brew doctor"
            case .service(let action, let name): return "\(action.progressive) \(name)"
            case .uninstall(let package): return "Uninstalling \(package.name)"
            case .install(let package): return "Installing \(package.name)"
            }
        }
    }
}
