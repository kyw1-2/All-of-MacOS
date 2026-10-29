import AppKit
import Foundation
import ImageIO

/// What a link card shows when the user lets AOM look the page up (parity
/// gap P03): the page title, the site's name and a preview image.
struct ClipboardLinkCard: Equatable {
    var title: String?
    var siteName: String?
    var imageURL: URL?

    var isEmpty: Bool { title == nil && siteName == nil && imageURL == nil }
}

/// Which links a card may look up. Only http(s) without a user name or
/// password, never a local-network host, and never a link that looks like it
/// carries a secret, a signature or a one-time token, which a GET could leak
/// or use up.
enum ClipboardLinkPolicy {
    static func fetchableURL(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .link, let text = entry.text else { return nil }
        return fetchableURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fetchableURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= 2_048, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty, !isLocal(host),
              !ClipboardSecretScanner.containsSecret(inText: text) else { return nil }
        return url
    }

    /// Hosts on this Mac or its network, including bare intranet names and
    /// every IP literal in a private, loopback, link-local or shared range.
    /// IPv6 literals are treated as local.
    static func isLocal(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.contains(":") { return true }
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"]
        if host == "localhost" || localSuffixes.contains(where: host.hasSuffix) || !host.contains(".") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 4, numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (numbers[0], numbers[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31), (100, 64...127): return true
        default: return numbers[0] >= 224
        }
    }
}

/// Reads a card from the head of an HTML page: Open Graph and Twitter tags,
/// then `<title>` and touch icons.
enum ClipboardLinkMetadataParser {
    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^>]{0,2000}>", options: [.caseInsensitive])
    private static let linkTag = try! NSRegularExpression(pattern: "<link\\b[^>]{0,2000}>", options: [.caseInsensitive])
    private static let titleTag = try! NSRegularExpression(pattern: "<title\\b[^>]{0,500}>([\\s\\S]{0,2000}?)</title>", options: [.caseInsensitive])
    private static let attribute = try! NSRegularExpression(
        pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

    static func parse(html: String, baseURL: URL) -> ClipboardLinkCard {
        let prefix = String(html.prefix(400_000))
        let head = prefix.range(of: "</head>", options: .caseInsensitive).map { String(prefix[..<$0.lowerBound]) } ?? prefix
        var meta: [String: String] = [:]
        for tag in tags(metaTag, in: head) {
            let attributes = attributes(of: tag)
            guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  let content = attributes["content"], meta[key] == nil else { continue }
            meta[key] = content
        }
        let title = clean(meta["og:title"] ?? meta["twitter:title"] ?? firstTitle(in: head))
        let site = clean(meta["og:site_name"] ?? meta["application-name"] ?? meta["apple-mobile-web-app-title"])
        let image = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"]
            ?? meta["twitter:image"] ?? meta["twitter:image:src"] ?? touchIcon(in: head)
        let imageURL = image.flatMap { raw -> URL? in
            let value = (ClipboardSecretScanner.referenceDecoded(raw) ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        return ClipboardLinkCard(title: title, siteName: site, imageURL: imageURL)
    }

    private static func tags(_ expression: NSRegularExpression, in text: String) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(400)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func attributes(of tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            let name = tag[nameRange].lowercased()
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    private static func firstTitle(in head: String) -> String? {
        guard let match = titleTag.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let range = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[range])
    }

    private static func touchIcon(in head: String) -> String? {
        let links = tags(linkTag, in: head).map(attributes(of:))
        let ranked = links.filter { $0["href"] != nil }.sorted { rank($0["rel"]) < rank($1["rel"]) }
        guard let best = ranked.first, rank(best["rel"]) < 3 else { return nil }
        return best["href"]
    }

    private static func rank(_ rel: String?) -> Int {
        let rel = rel?.lowercased() ?? ""
        if rel.contains("apple-touch-icon") { return 0 }
        if rel.contains("icon") && !rel.contains("mask") { return 1 }
        return 3
    }

    /// Character references decoded, whitespace collapsed, at most 300 characters.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let decoded = ClipboardSecretScanner.referenceDecoded(raw) ?? raw
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(300))
    }
}

/// Fetches and remembers link cards for the session. Nothing is written to
/// disk: results live in memory (200 pages), failures are remembered so a
/// page is asked at most once, and the network is touched only while both
/// switches are on.
@MainActor
final class ClipboardLinkMetadataStore {
    static let shared = ClipboardLinkMetadataStore()

    /// Fetches up to `limit` bytes. Injectable so tests never touch the network.
    typealias Loader = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)
    var loader: Loader = { request, limit in try await ClipboardLinkMetadataStore.fetch(request, limit: limit) }

    nonisolated static let pageByteLimit = 512 * 1_024
    nonisolated static let imageByteLimit = 2 * 1_024 * 1_024
    static let capacity = 200

    /// Both switches: private web previews, and link cards themselves.
    static var isEnabled: Bool {
        ClipboardPreferences.shared.networkPreviews && ClipboardPreferences.shared.linkCards
    }

    private var cards: [URL: ClipboardLinkCard] = [:]
    private var images: [URL: CGImage] = [:]
    private var failures: Set<URL> = []
    private var inFlight: [URL: Task<ClipboardLinkCard?, Never>] = [:]
    private var imageTasks: [URL: Task<CGImage?, Never>] = [:]
    private var recent: [URL] = []
    /// Requests sent, for tests.
    private(set) var requestCount = 0

    func cachedCard(for url: URL) -> ClipboardLinkCard? { cards[url] }

    func card(for url: URL, enabled: Bool) async -> ClipboardLinkCard? {
        guard enabled, ClipboardLinkPolicy.fetchableURL(url.absoluteString) != nil else { return nil }
        if let card = cards[url] { return card }
        if failures.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }
        let loader = loader
        requestCount += 1
        let task = Task { await Self.loadCard(url, loader: loader) }
        inFlight[url] = task
        let card = await task.value
        inFlight[url] = nil
        if let card { remember(url) { cards[url] = card } } else { failures.insert(url) }
        return card
    }

    func image(for card: ClipboardLinkCard, enabled: Bool) async -> CGImage? {
        guard enabled, let url = card.imageURL, ClipboardLinkPolicy.fetchableURL(url.absoluteString) != nil else { return nil }
        if let image = images[url] { return image }
        if failures.contains(url) { return nil }
        if let task = imageTasks[url] { return await task.value }
        let loader = loader
        requestCount += 1
        let task = Task { await Self.loadImage(url, loader: loader) }
        imageTasks[url] = task
        let image = await task.value
        imageTasks[url] = nil
        if let image { remember(url) { images[url] = image } } else { failures.insert(url) }
        return image
    }

    /// Turning link cards off forgets everything fetched.
    func removeAll() {
        for task in inFlight.values { task.cancel() }
        for task in imageTasks.values { task.cancel() }
        inFlight.removeAll(); imageTasks.removeAll()
        cards.removeAll(); images.removeAll(); failures.removeAll(); recent.removeAll()
    }

    private func remember(_ url: URL, store: () -> Void) {
        store()
        recent.removeAll { $0 == url }
        recent.append(url)
        while recent.count > Self.capacity {
            let old = recent.removeFirst()
            cards[old] = nil
            images[old] = nil
        }
    }

    nonisolated private static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func loadCard(_ url: URL, loader: Loader) async -> ClipboardLinkCard? {
        guard let (data, response) = try? await loader(request(url, accept: "text/html,application/xhtml+xml;q=0.9"), pageByteLimit),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard type.isEmpty || type.contains("html") else { return nil }
        let card = ClipboardLinkMetadataParser.parse(html: decode(data, contentType: type), baseURL: http.url ?? url)
        return card.isEmpty ? nil : card
    }

    nonisolated static func loadImage(_ url: URL, loader: Loader) async -> CGImage? {
        guard let (data, response) = try? await loader(request(url, accept: "image/*"), imageByteLimit),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < imageByteLimit,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "image/").lowercased().hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 480]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The page's charset when it names one, else UTF-8 (lossy).
    nonisolated static func decode(_ data: Data, contentType: String) -> String {
        if let range = contentType.range(of: "charset=") {
            let name = contentType[range.upperBound...].split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// An ephemeral session: no cookies, cache or stored credentials, short
    /// timeouts, and redirects only to links the policy accepts.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    nonisolated static func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1_024))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        // Stop the transfer at the limit instead of draining the rest.
        bytes.task.cancel()
        return (data, response)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, ClipboardLinkPolicy.fetchableURL(url.absoluteString) != nil else {
                completionHandler(nil)
                return
            }
            var next = request
            next.httpShouldHandleCookies = false
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Server trust is checked as usual; nothing ever answers a login prompt.
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
