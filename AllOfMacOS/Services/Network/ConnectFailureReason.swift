import Foundation

/// 7.23 (DeepSeek design reference 2026-11-25 §2.9, Mimestream's per-cause
/// alerts): why a connection failed, said three ways — a title, what it
/// means, and the next thing to do. Every network surface (AI providers,
/// weather, link previews) classifies its URLError or HTTP status here, so
/// a wrong address reads as "can't find the server", not "check your key".
enum ConnectFailureReason: Equatable {
    case offline
    case timeout
    /// The Mac's clock is off, so the server's certificate looks expired or not yet valid.
    case clockSkew
    case cannotFindServer(String?)
    case refused(String?)
    case auth
    case rateLimited
    case serverError(Int)
    case insecure
    case other(String)

    static func classify(_ error: URLError, host: String? = nil) -> ConnectFailureReason {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .timedOut: return .timeout
        case .serverCertificateNotYetValid, .serverCertificateHasBadDate: return .clockSkew
        case .cannotFindHost, .dnsLookupFailed: return .cannotFindServer(host)
        case .cannotConnectToHost: return .refused(host)
        case .userAuthenticationRequired, .userCancelledAuthentication: return .auth
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection: return .insecure
        default: return .other(error.localizedDescription)
        }
    }

    /// Nil for a success.
    static func classify(status: Int) -> ConnectFailureReason? {
        switch status {
        case 200..<400: return nil
        case 401, 403: return .auth
        case 429: return .rateLimited
        case 500...: return .serverError(status)
        default: return .other("The server answered \(status).")
        }
    }

    var title: String {
        switch self {
        case .offline: "You're offline"
        case .timeout: "The server took too long"
        case .clockSkew: "Can't connect because the clock is off"
        case .cannotFindServer(let host): "Can't find \(host ?? "the server")"
        case .refused(let host): "\(host ?? "The server") isn't answering"
        case .auth: "The sign-in or key was refused"
        case .rateLimited: "Too many requests"
        case .serverError(let code): "The server had a problem (\(code))"
        case .insecure: "The secure connection failed"
        case .other: "Couldn't connect"
        }
    }

    var informative: String {
        switch self {
        case .offline: "This Mac has no internet connection right now."
        case .timeout: "The server didn't answer in time. It may be busy or the network slow."
        case .clockSkew: "This Mac's date and time don't match the server's, so its certificate can't be checked."
        case .cannotFindServer: "The address may be mistyped, or the server is gone."
        case .refused: "Nothing at that address takes connections — it may be stopped, or the port is wrong."
        case .auth: "The server rejected the API key, token or account it was given."
        case .rateLimited: "The server asked AOM to slow down."
        case .serverError: "The server answered, but it failed on its side. It isn't this Mac."
        case .insecure: "The server's certificate isn't trusted, or something on the network is in the way."
        case .other(let text): text
        }
    }

    /// The one next step, as a button title.
    var action: String {
        switch self {
        case .offline: "Open Network Settings"
        case .timeout, .serverError, .rateLimited, .other: "Try Again"
        case .clockSkew: "Set Date & Time Automatically"
        case .cannotFindServer, .refused: "Check the Address"
        case .auth: "Check the Key"
        case .insecure: "Open Network Settings"
        }
    }

    /// The System Settings pane for actions that open one.
    var settingsURL: URL? {
        switch self {
        case .offline, .insecure: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
        case .clockSkew: URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")
        default: nil
        }
    }

    /// Title and meaning in one line, for places with room for one.
    var sentence: String { "\(title). \(informative)" }
}
