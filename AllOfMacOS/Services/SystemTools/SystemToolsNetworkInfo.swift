import Foundation
import CoreWLAN

/// Wi-Fi details (CoreWLAN), ping, DNS servers in use, listening ports and
/// the public IP. Formatting and parsing are pure and unit tested; nothing
/// here talks to the network until the user clicks.
extension NetworkTools {
    // MARK: Wi-Fi signal

    /// The usual RSSI bands (Apple's Wireless Diagnostics and iStat Menus
    /// use the same cut-offs).
    static func signalQuality(rssi: Int) -> String {
        switch rssi {
        case (-50)...: return "Excellent"
        case (-60)...: return "Good"
        case (-70)...: return "Fair"
        default: return "Weak"
        }
    }

    /// "−52 dBm · Good · SNR 41 dB". The noise floor is optional (some
    /// drivers report 0).
    static func rssiText(rssi: Int, noise: Int?) -> String {
        var text = "\(rssi) dBm · \(signalQuality(rssi: rssi))"
        if let noise, noise < 0, rssi > noise { text += " · SNR \(rssi - noise) dB" }
        return text
    }

    /// "36 (5 GHz, 80 MHz)".
    static func channelText(number: Int, bandGHz: Double?, widthMHz: Int?) -> String {
        var parts: [String] = []
        if let bandGHz { parts.append(bandGHz == bandGHz.rounded() ? "\(Int(bandGHz)) GHz" : String(format: "%.1f GHz", bandGHz)) }
        if let widthMHz { parts.append("\(widthMHz) MHz") }
        return parts.isEmpty ? "\(number)" : "\(number) (\(parts.joined(separator: ", ")))"
    }

    static func bandGHz(_ band: CWChannelBand) -> Double? {
        switch band {
        case .band2GHz: return 2.4
        case .band5GHz: return 5
        case .band6GHz: return 6
        default: return nil
        }
    }

    static func widthMHz(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return nil
        }
    }

    struct WiFiDetails: Equatable {
        let interface: String
        let powerOn: Bool
        /// nil when macOS withholds it (no Location Services permission).
        let ssid: String?
        let rssi: Int?
        let noise: Int?
        let channel: String?
        let transmitRate: Double?

        var lines: [String] {
            guard powerOn else { return ["Interface: \(interface)", "Wi-Fi is off"] }
            var lines = ["Interface: \(interface)"]
            lines.append("Network: " + (ssid ?? "hidden by macOS (allow Location for All of MacOS to see the name)"))
            if let rssi { lines.append("Signal: " + NetworkTools.rssiText(rssi: rssi, noise: noise)) }
            if let channel { lines.append("Channel: \(channel)") }
            if let transmitRate, transmitRate > 0 { lines.append("Transmit rate: \(Int(transmitRate.rounded())) Mbps") }
            if rssi == nil || rssi == 0 { lines.append("Not connected to a network") }
            return lines
        }
    }

    static func wifiDetails() -> WiFiDetails? {
        guard let wifi = CWWiFiClient.shared().interface() else { return nil }
        let rssi = wifi.rssiValue()
        let channel = wifi.wlanChannel().map {
            channelText(number: $0.channelNumber, bandGHz: bandGHz($0.channelBand), widthMHz: widthMHz($0.channelWidth))
        }
        return WiFiDetails(interface: wifi.interfaceName ?? "en0", powerOn: wifi.powerOn(), ssid: wifi.ssid(),
                           rssi: rssi == 0 ? nil : rssi, noise: wifi.noiseMeasurement(), channel: channel,
                           transmitRate: wifi.transmitRate())
    }

    // MARK: Ping

    struct PingResult: Equatable {
        let sent: Int
        let received: Int
        let minimum: Double?
        let average: Double?
        let maximum: Double?

        var lossPercent: Int { sent > 0 ? Int((Double(sent - received) / Double(sent) * 100).rounded()) : 100 }

        var summary: String {
            guard received > 0, let average else { return "No reply (\(lossPercent)% loss)" }
            var text = String(format: "%.1f ms average", average)
            if let minimum, let maximum { text += String(format: " (%.1f–%.1f)", minimum, maximum) }
            return text + " · \(lossPercent)% loss"
        }
    }

    /// A host the user typed: letters, digits, dots, hyphens and colons
    /// (IPv6) only, so it can't be read as a ping option.
    static func isValidHost(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253, !trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) }
    }

    /// Five pings, at most 8 seconds in total.
    static func pingArguments(host: String) -> [String] { ["-c", "5", "-t", "8", "-q", host] }

    /// The two summary lines of `ping -q`:
    /// "5 packets transmitted, 5 packets received, 0.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 5.096/5.444/5.770/0.276 ms".
    static func parsePing(_ text: String) -> PingResult? {
        var sent: Int?, received: Int?
        var minimum: Double?, average: Double?, maximum: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("packets transmitted") {
                let numbers = line.split(separator: ",").compactMap { part in
                    part.trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap { Int($0) }
                }
                if numbers.count >= 2 { sent = numbers[0]; received = numbers[1] }
            } else if line.contains("min/avg/max"), let equals = line.firstIndex(of: "=") {
                let values = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first?.split(separator: "/").compactMap { Double($0) } ?? []
                if values.count >= 3 { minimum = values[0]; average = values[1]; maximum = values[2] }
            }
        }
        guard let sent, let received else { return nil }
        return PingResult(sent: sent, received: received, minimum: minimum, average: average, maximum: maximum)
    }

    static func ping(host: String) throws -> PingResult {
        let output = try SystemToolsCommand.run("/sbin/ping", pingArguments(host: host))
        // ping exits 2 when nothing answered; that is a result, not a failure.
        guard let result = parsePing(output.stdout) else {
            throw SystemToolError.commandFailed(command: "ping", status: output.status,
                                                message: output.stderr.isEmpty ? "No reply from \(host)" : output.stderr)
        }
        return result
    }

    // MARK: DNS

    /// The resolvers in use from `scutil --dns` ("nameserver[0] : 1.1.1.1"),
    /// in order, without duplicates.
    static func parseDNSServers(_ text: String) -> [String] {
        var seen = Set<String>()
        var servers: [String] = []
        for line in text.split(whereSeparator: \.isNewline) where line.contains("nameserver[") {
            guard let colon = line.range(of: " : ") else { continue }
            let server = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            if !server.isEmpty, seen.insert(server).inserted { servers.append(server) }
        }
        return servers
    }

    // MARK: Listening ports

    static let listeningArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPnT"]

    /// One row per process and port; listeners on both IPv4 and IPv6 for the
    /// same port collapse into one.
    static func listeningPorts(_ users: [PortUser]) -> [PortUser] {
        var seen = Set<String>()
        return users.filter { user in
            let port = user.name.split(separator: ":").last.map(String.init) ?? user.name
            return seen.insert("\(user.pid)|\(port)").inserted
        }.sorted { lhs, rhs in
            let l = Int(lhs.name.split(separator: ":").last ?? "") ?? 0, r = Int(rhs.name.split(separator: ":").last ?? "") ?? 0
            return l != r ? l < r : lhs.pid < rhs.pid
        }
    }

    static func listeningUsers() throws -> [PortUser] {
        let output = try SystemToolsCommand.run("/usr/sbin/lsof", listeningArguments)
        if output.status != 0 && output.stdout.isEmpty {
            if output.stderr.isEmpty { return [] }
            throw SystemToolError.commandFailed(command: "lsof", status: output.status, message: output.stderr)
        }
        return listeningPorts(parsePortUsers(output.stdout))
    }

    // MARK: Public IP

    /// ipify answers with the bare address over HTTPS; one request per click.
    static let publicIPURL = URL(string: "https://api64.ipify.org")!

    /// Accepts only a literal IPv4 or IPv6 address, so an error page or a
    /// captive portal's HTML is never copied as "your IP".
    static func isIPAddress(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        return !value.isEmpty && (inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1)
    }

    static func publicIP() async throws -> String {
        var request = URLRequest(url: publicIPURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (response as? HTTPURLResponse)?.statusCode == 200, isIPAddress(text) else {
            throw SystemToolError.invalidInput("The address service didn't return an IP address.")
        }
        return text
    }
}
