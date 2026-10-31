import AppKit

/// VPN for the System Tools page: the VPN services macOS knows
/// (`scutil --nc list`, connected and disconnected with `scutil --nc
/// start|stop`), Tailscale's own CLI inside its app, and OpenVPN Connect,
/// which keeps its profiles to itself (AOM can only open it).
enum VPNTools {
    // MARK: - Network connection services (scutil)

    struct Service: Identifiable, Hashable, Sendable {
        enum State: Hashable, Sendable {
            case connected, connecting, disconnecting, disconnected, other(String)
            init(_ raw: String) {
                switch raw.lowercased() {
                case "connected": self = .connected
                case "connecting": self = .connecting
                case "disconnecting": self = .disconnecting
                case "disconnected": self = .disconnected
                default: self = .other(raw)
                }
            }
            var title: String {
                switch self {
                case .connected: return "Connected"
                case .connecting: return "Connecting…"
                case .disconnecting: return "Disconnecting…"
                case .disconnected: return "Disconnected"
                case .other(let raw): return raw
                }
            }
            /// Connect means stop; anything else means start.
            var isUp: Bool { self == .connected || self == .connecting }
        }
        /// The service ID (a UUID), unique where names may repeat.
        let id: String
        let name: String
        /// "IPSec", "PPP --> L2TP", "VPN (com.wireguard.macos)".
        let type: String
        let state: State
        let enabled: Bool

        /// The provider's bundle id for app-based VPNs ("io.tailscale.ipn.macsys").
        var providerBundleID: String? {
            guard let open = type.firstIndex(of: "("), let close = type.lastIndex(of: ")"), open < close else { return nil }
            let inside = type[type.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return inside.isEmpty ? nil : inside
        }

        /// A friendlier type: "IPSec", "L2TP", "WireGuard", "Tailscale".
        var kindTitle: String {
            if type.contains("L2TP") { return "L2TP" }
            if type.contains("IPSec") { return "IPSec" }
            if type.contains("IKEv2") { return "IKEv2" }
            if let provider = providerBundleID?.lowercased() {
                if provider.contains("tailscale") { return "Tailscale" }
                if provider.contains("wireguard") { return "WireGuard" }
                if provider.contains("openvpn") { return "OpenVPN" }
                return "App VPN"
            }
            return type
        }
    }

    /// One `scutil --nc list` line:
    /// `* (Connected)      FB2D…C8FA VPN (io.tailscale.ipn.macsys) "Tailscale"   [VPN:io.tailscale.ipn.macsys]`.
    /// The leading `*` marks an enabled service. Lines that don't look like
    /// that (the header) are skipped.
    static func parseServiceList(_ output: String) -> [Service] {
        let pattern = #"^\s*(\*?)\s*\(([^)]*)\)\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+([^"]*?)\s*"(.*)"\s*(?:\[[^\]]*\])?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { raw -> Service? in
            let line = String(raw)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            return Service(id: group(3).uppercased(), name: group(5), type: group(4).trimmingCharacters(in: .whitespaces),
                           state: Service.State(group(2).trimmingCharacters(in: .whitespaces)), enabled: group(1) == "*")
        }
    }

    static func listArguments() -> [String] { ["--nc", "list"] }

    /// Start or stop by service ID (scutil takes a name or an ID; the ID
    /// can't be ambiguous).
    static func toggleArguments(for service: Service) -> [String] {
        ["--nc", service.state.isUp ? "stop" : "start", service.id]
    }

    static let scutil = URL(fileURLWithPath: "/usr/sbin/scutil")

    // MARK: - Tailscale

    static let tailscaleCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let tailscaleBundleID = "io.tailscale.ipn.macsys"
    static let tailscaleAppStoreBundleID = "io.tailscale.ipn.macos"

    static func tailscaleExecutable(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        isExecutable(tailscaleCLI) ? URL(fileURLWithPath: tailscaleCLI) : nil
    }

    struct TailscaleStatus: Equatable, Sendable {
        enum Backend: Equatable, Sendable {
            case running, stopped, starting, needsLogin, needsMachineAuth, noState, other(String)
            init(_ raw: String) {
                switch raw {
                case "Running": self = .running
                case "Stopped": self = .stopped
                case "Starting": self = .starting
                case "NeedsLogin": self = .needsLogin
                case "NeedsMachineAuth": self = .needsMachineAuth
                case "NoState": self = .noState
                default: self = .other(raw)
                }
            }
            var title: String {
                switch self {
                case .running: return "Connected"
                case .stopped: return "Disconnected"
                case .starting: return "Connecting…"
                case .needsLogin: return "Not logged in"
                case .needsMachineAuth: return "Waiting for approval"
                case .noState: return "Starting up"
                case .other(let raw): return raw
                }
            }
        }
        let backend: Backend
        let version: String?
        /// This Mac's Tailscale addresses, IPv4 first.
        let addresses: [String]
        let hostName: String?
        let dnsName: String?
        let tailnet: String?
        /// The peer this Mac sends its traffic through, if any.
        let exitNode: String?
        /// Peers that offer to be an exit node.
        let exitNodeOptions: Int
        let onlinePeers: Int
        let health: [String]

        var ipv4: String? { addresses.first { !$0.contains(":") } }
    }

    /// `Tailscale status --json` (ipnstate.Status): BackendState, Self
    /// (TailscaleIPs, HostName, DNSName), Peer (a map of PeerStatus with
    /// ExitNode / ExitNodeOption / Online), ExitNodeStatus, CurrentTailnet,
    /// Health.
    static func parseTailscaleStatus(_ data: Data) throws -> TailscaleStatus {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["BackendState"] as? String else {
            throw SystemToolError.invalidInput("Tailscale's status wasn't readable.")
        }
        let me = root["Self"] as? [String: Any]
        let peers = (root["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        func addresses(_ object: [String: Any]?) -> [String] {
            let all = (object?["TailscaleIPs"] as? [String]) ?? []
            return all.filter { !$0.contains(":") } + all.filter { $0.contains(":") }
        }
        var selfAddresses = addresses(me)
        if selfAddresses.isEmpty { selfAddresses = (root["TailscaleIPs"] as? [String]) ?? [] }
        func displayName(_ peer: [String: Any]) -> String? {
            if let host = peer["HostName"] as? String, !host.isEmpty { return host }
            if let dns = peer["DNSName"] as? String, !dns.isEmpty { return dns.split(separator: ".").first.map(String.init) }
            return nil
        }
        var exit = peers.first { $0["ExitNode"] as? Bool == true }.flatMap(displayName)
        if exit == nil, let status = root["ExitNodeStatus"] as? [String: Any], let id = status["ID"] as? String {
            exit = peers.first { $0["ID"] as? String == id }.flatMap(displayName)
                ?? (status["TailscaleIPs"] as? [String])?.first
        }
        let tailnet = (root["CurrentTailnet"] as? [String: Any])?["Name"] as? String
        let dns = (me?["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return TailscaleStatus(backend: .init(state), version: (root["Version"] as? String).map { $0.split(separator: "-").first.map(String.init) ?? $0 },
                               addresses: selfAddresses, hostName: me?["HostName"] as? String,
                               dnsName: dns?.isEmpty == true ? nil : dns, tailnet: tailnet, exitNode: exit,
                               exitNodeOptions: peers.filter { $0["ExitNodeOption"] as? Bool == true }.count,
                               onlinePeers: peers.filter { $0["Online"] as? Bool == true }.count,
                               health: (root["Health"] as? [String]) ?? [])
    }

    /// A CLI answer that means the Tailscale app (its network extension)
    /// isn't running, so the CLI has nothing to talk to.
    static func tailscaleNotRunning(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("failed to connect to local tailscale") || text.contains("is tailscale running")
            || text.contains("tailscaled") && text.contains("not running")
    }

    // MARK: - OpenVPN Connect

    static let openVPNBundleIDs = ["org.openvpn.client.app", "net.openvpn.connect.app"]

    static func openVPNConnectURL(lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> URL? {
        for id in openVPNBundleIDs { if let url = lookup(id) { return url } }
        let fallback = "/Applications/OpenVPN Connect/OpenVPN Connect.app"
        return FileManager.default.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }
}
