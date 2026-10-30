import AppKit

/// "What is using port N" (lsof) and the Apple `networkQuality` speed test.
/// Both run the system tools with argument arrays; their output parsers are
/// pure and unit tested.
enum NetworkTools {
    // MARK: Ports

    struct PortUser: Identifiable, Equatable, Hashable {
        var id: String { "\(pid)|\(proto)|\(name)" }
        let pid: pid_t
        let command: String
        /// TCP or UDP.
        let proto: String
        /// lsof's NAME column: "*:8080", "127.0.0.1:5000->127.0.0.1:61234".
        let name: String
        /// TCP state ("LISTEN", "ESTABLISHED"); empty for UDP.
        let state: String
    }

    /// A port typed by the user: digits only, 1–65535.
    static func port(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    static func lsofArguments(port: Int) -> [String] {
        ["-nP", "-i", ":\(port)", "-F", "pcPnT"]
    }

    /// Parses `lsof -F pcPnT` field output: a `p` line starts a process, `c`
    /// names it, then each open file has `P` (protocol), `n` (name) and `T`
    /// lines (only `TST=` matters). Listeners sort first.
    static func parsePortUsers(_ output: String) -> [PortUser] {
        var users: [PortUser] = []
        var seen = Set<String>()
        var pid: pid_t?
        var command = ""
        var proto = ""
        var name: String?
        var state = ""

        func flush() {
            guard let pid, let current = name else { return }
            let user = PortUser(pid: pid, command: command, proto: proto, name: current, state: state)
            if seen.insert(user.id).inserted { users.append(user) }
            name = nil
            state = ""
        }

        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = pid_t(value); command = ""; proto = ""
            case "c": command = value
            case "f": flush(); proto = ""
            case "P": proto = value
            case "n": flush(); name = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return users.sorted { lhs, rhs in
            let l = lhs.state == "LISTEN", r = rhs.state == "LISTEN"
            if l != r { return l }
            return lhs.pid < rhs.pid
        }
    }

    /// Blocking: lsof exits 1 when nothing matches, which is an empty answer,
    /// not a failure.
    static func users(ofPort port: Int) throws -> [PortUser] {
        let output = try SystemToolsCommand.run("/usr/sbin/lsof", lsofArguments(port: port))
        if output.status != 0 && output.stdout.isEmpty {
            if output.stderr.isEmpty { return [] }
            throw SystemToolError.commandFailed(command: "lsof", status: output.status, message: output.stderr)
        }
        return parsePortUsers(output.stdout)
    }

    /// Asks a process to quit (SIGTERM, so it can clean up). Apps get the
    /// normal terminate request. Another user's process is refused by macOS
    /// and reported.
    static func quit(pid: pid_t) throws {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited {
            guard app.terminate() else { throw SystemToolError.invalidInput("\(app.localizedName ?? "The app") didn't accept the quit request.") }
            return
        }
        guard kill(pid, SIGTERM) == 0 else {
            throw SystemToolError.invalidInput("Process \(pid) could not be stopped: \(String(cString: strerror(errno))).")
        }
    }

    // MARK: Speed test

    struct SpeedResult: Equatable {
        /// Bits per second.
        let download: Double?
        let upload: Double?
        /// Round trips per minute under load (Apple's responsiveness score).
        let responsiveness: Double?
        /// Idle latency in milliseconds.
        let idleLatency: Double?
        let interface: String?

        var summary: String {
            var parts: [String] = []
            if let download { parts.append("↓ \(Self.megabits(download))") }
            if let upload { parts.append("↑ \(Self.megabits(upload))") }
            if let responsiveness { parts.append("\(Int(responsiveness.rounded())) RPM") }
            if let idleLatency { parts.append("\(Int(idleLatency.rounded())) ms idle") }
            return parts.isEmpty ? "No result" : parts.joined(separator: " · ")
        }

        static func megabits(_ bitsPerSecond: Double) -> String {
            let value = bitsPerSecond / 1_000_000
            return value >= 100 ? "\(Int(value.rounded())) Mbps" : String(format: "%.1f Mbps", value)
        }
    }

    /// `networkQuality -c` JSON. A full run has `responsiveness`; a run
    /// without the upload phase only `dl_responsiveness`.
    static func parseSpeedTest(_ json: String) -> SpeedResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        let result = SpeedResult(download: number("dl_throughput"), upload: number("ul_throughput"),
                                 responsiveness: number("responsiveness") ?? number("dl_responsiveness"),
                                 idleLatency: number("base_rtt"), interface: object["interface_name"] as? String)
        return result.download == nil && result.upload == nil ? nil : result
    }

    /// About 20 seconds of real traffic to Apple's test servers.
    static func runSpeedTest(maxSeconds: Int = 20) throws -> SpeedResult {
        let output = try SystemToolsCommand.run("/usr/bin/networkQuality", ["-c", "-M", String(maxSeconds)])
        guard output.succeeded, let result = parseSpeedTest(output.stdout) else {
            let message = output.stderr.isEmpty ? "networkQuality returned no measurement (is the Mac online?)" : output.stderr
            throw SystemToolError.commandFailed(command: "networkQuality", status: output.status, message: message)
        }
        return result
    }
}
