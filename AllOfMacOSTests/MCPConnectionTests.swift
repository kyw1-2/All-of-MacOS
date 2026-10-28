import XCTest
import Darwin
@testable import AllOfMacOS

/// Counts SIGPIPE deliveries while a test runs. A C signal handler cannot
/// capture context, hence the global.
nonisolated(unsafe) private var sigpipeDeliveries: Int32 = 0

/// Audit 2026-10-28 F02/F03: the MCP connection must survive a vanished peer
/// and deliver every reply whole on the non-blocking sockets `accept()` hands
/// back. These drive the production `ClipboardMCPServer.Connection` over a
/// local socket pair; no MCP client, clipboard item or network is involved.
@MainActor
final class MCPConnectionTests: XCTestCase {
    private var descriptors: [Int32] = []
    private var connections: [ClipboardMCPServer.Connection] = []

    override func tearDown() {
        for connection in connections { connection.close() }
        connections.removeAll()
        // The connection closes its own end; close the test's peer ends.
        for fd in descriptors { Darwin.close(fd) }
        descriptors.removeAll()
        super.tearDown()
    }

    /// A connected pair: the production connection owns `server`, the test
    /// reads and writes `peer`.
    private func makePair(sendBuffer: Int32? = nil,
                          stallTimeout: TimeInterval = ClipboardMCPServer.Connection.defaultStallTimeout) throws -> (connection: ClipboardMCPServer.Connection, peer: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        if var size = sendBuffer {
            setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let connection = ClipboardMCPServer.Connection(fd: fds[0], queue: DispatchQueue(label: "test.mcp.\(UUID().uuidString)"),
                                                       stallTimeout: stallTimeout)
        connection.start()
        connections.append(connection)
        descriptors.append(fds[1])
        return (connection, fds[1])
    }

    /// Reads from a blocking peer until `lines` newlines arrived or the
    /// receive timeout expires; optionally pauses between reads to act like a
    /// slow MCP client.
    private nonisolated static func readLines(_ fd: Int32, lines: Int, chunk: Int = 65_536,
                                              pause: useconds_t = 0) -> Data {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        while received.reduce(0, { $0 + ($1 == 0x0A ? 1 : 0) }) < lines {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
            if pause > 0 { usleep(pause) }
        }
        return received
    }

    // MARK: F03 — replies are never truncated

    func testALargeReplyOnASmallNonBlockingSocketArrivesWholeWithItsNewline() throws {
        // The audit's NonblockingSocketProbe: a 4 KB send buffer and a 1 MB
        // reply. The old loop stopped at the first EAGAIN after 4,096 bytes.
        let (connection, peer) = try makePair(sendBuffer: 4_096)
        let text = String(repeating: "x", count: 1_000_000)
        let read = expectation(description: "peer read the reply")
        var received = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            received = Self.readLines(peer, lines: 1)
            read.fulfill()
        }
        connection.send(["message": text])
        wait(for: [read], timeout: 15)
        XCTAssertEqual(received.count, 1_000_015, "{\"message\":\"…\"} plus its newline")
        XCTAssertEqual(received.last, 0x0A, "the line is terminated")
        let decoded = try JSONSerialization.jsonObject(with: received.dropLast()) as? [String: String]
        XCTAssertEqual(decoded?["message"], text)
    }

    func testRepliesKeepTheirOrderForASlowReader() throws {
        let (connection, peer) = try makePair(sendBuffer: 8_192)
        let bodies = (0..<3).map { String(repeating: Character(UnicodeScalar(UInt8(97 + $0))), count: 300_000) } + ["done"]
        let read = expectation(description: "peer read every reply")
        var received = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            // 16 KB at a time with a pause: the socket fills up repeatedly.
            received = Self.readLines(peer, lines: bodies.count, chunk: 16_384, pause: 500)
            read.fulfill()
        }
        for (index, body) in bodies.enumerated() { connection.send(["id": index, "text": body]) }
        wait(for: [read], timeout: 30)
        let lines = received.split(separator: 0x0A)
        XCTAssertEqual(lines.count, bodies.count)
        for (index, line) in lines.enumerated() {
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            XCTAssertEqual(object?["id"] as? Int, index, "replies stay in order")
            XCTAssertEqual(object?["text"] as? String, bodies[index], "reply \(index) is complete")
        }
    }

    /// The audit's acceptance case: a client that stops reading, then
    /// resumes, receives two large replies whole, with their newlines, in order.
    func testTwoLargeRepliesSurviveAReaderThatStopsAndResumes() throws {
        let (connection, peer) = try makePair(sendBuffer: 8_192)
        var closed = false
        connection.onClose = { closed = true }
        let bodies = ["first", "second"].map { ($0, String(repeating: $0 == "first" ? "1" : "2", count: 700_000)) }
        let read = expectation(description: "peer read both replies")
        var received = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 1.5)              // not reading at all…
            received = Self.readLines(peer, lines: 2)       // …then reading everything
            read.fulfill()
        }
        for (name, body) in bodies { connection.send(["name": name, "body": body]) }
        wait(for: [read], timeout: 20)
        let lines = received.split(separator: 0x0A, omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "two lines, each terminated")
        XCTAssertEqual(lines.last?.isEmpty, true)
        for (index, (name, body)) in bodies.enumerated() {
            let object = try JSONSerialization.jsonObject(with: Data(lines[index])) as? [String: String]
            XCTAssertEqual(object?["name"], name, "in order")
            XCTAssertEqual(object?["body"], body, "complete")
        }
        XCTAssertFalse(closed, "a pause shorter than the deadline keeps the connection")
    }

    /// The deadline closes only the connection whose reader stopped.
    func testOnlyTheConnectionWhoseReaderStoppedIsClosedAtTheDeadline() throws {
        let (stuck, _) = try makePair(sendBuffer: 4_096, stallTimeout: 0.4)
        let (healthy, healthyPeer) = try makePair()
        let stuckClosed = expectation(description: "stalled connection closed")
        stuck.onClose = { stuckClosed.fulfill() }
        var healthyClosed = false
        healthy.onClose = { healthyClosed = true }
        stuck.send(["body": String(repeating: "s", count: 1_000_000)])     // never read
        wait(for: [stuckClosed], timeout: 10)
        let read = expectation(description: "healthy peer read its reply")
        var received = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            received = Self.readLines(healthyPeer, lines: 1)
            read.fulfill()
        }
        healthy.send(["ok": true])
        wait(for: [read], timeout: 5)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: received.dropLast()) as? [String: Bool], ["ok": true])
        XCTAssertFalse(healthyClosed, "the other connection is untouched")
    }

    func testEveryRequestWithAnIDGetsAnAnswer() async {
        let store = ClipboardStore()
        await store.ready()
        // A request with an id but no method used to be dropped silently.
        let invalid = ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 7], store: store)
        XCTAssertEqual(invalid?["id"] as? Int, 7)
        XCTAssertEqual((invalid?["error"] as? [String: Any])?["code"] as? Int, -32600)
        // Notifications and client responses are still never answered.
        XCTAssertNil(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], store: store))
        XCTAssertNil(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 3, "result": [:] as [String: Any]], store: store))
        // An unparseable line is answered with a null-id parse error.
        XCTAssertTrue(ClipboardMCPHandler.parseError["id"] is NSNull)
        XCTAssertEqual((ClipboardMCPHandler.parseError["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    // MARK: F02 — a vanished peer never raises SIGPIPE

    func testWritingAfterThePeerClosedNeitherRaisesSIGPIPENorKeepsTheConnection() throws {
        sigpipeDeliveries = 0
        // Count instead of dying: with the default action, the old code
        // terminated the whole test process here (exit 141).
        let previous = signal(SIGPIPE) { _ in sigpipeDeliveries += 1 }
        defer { signal(SIGPIPE, previous) }
        let (connection, peer) = try makePair()
        let closed = expectation(description: "connection reported closed")
        connection.onClose = { closed.fulfill() }
        Darwin.close(peer)
        descriptors.removeAll { $0 == peer }
        for index in 0..<20 { connection.send(["message": "after close \(index)", "padding": String(repeating: "p", count: 50_000)]) }
        wait(for: [closed], timeout: 5)
        let drained = expectation(description: "queued writes were attempted")
        connection.afterPendingWrites { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(sigpipeDeliveries, 0, "EPIPE must close the connection, not signal the process")
    }

    /// The audit's acceptance case, repeated: the client goes away right
    /// after authenticating, right before a reply, and in the middle of a
    /// large reply. The process must never see SIGPIPE, and every
    /// connection must report that it closed.
    func testClosingThePeerAtAnyMomentNeverRaisesSIGPIPE() throws {
        sigpipeDeliveries = 0
        let previous = signal(SIGPIPE) { _ in sigpipeDeliveries += 1 }
        defer { signal(SIGPIPE, previous) }
        for round in 0..<8 {
            // 1. Right after the authentication reply.
            do {
                let (connection, peer) = try makePair()
                let closed = expectation(description: "closed after auth \(round)")
                connection.onClose = { closed.fulfill() }
                connection.onLine = { [weak connection] _ in
                    connection?.send(["aom_mcp_auth": "ok"])
                    for index in 0..<5 { connection?.send(["id": index, "padding": String(repeating: "a", count: 40_000)]) }
                }
                _ = "{\"aom_mcp_auth\":\"token\"}\n".withCString { Darwin.write(peer, $0, strlen($0)) }
                // The reply is sent from main, so the client reads elsewhere
                // and hangs up as soon as the "ok" line has arrived.
                descriptors.removeAll { $0 == peer }
                let answered = expectation(description: "auth answered \(round)")
                DispatchQueue.global(qos: .userInitiated).async {
                    let reply = Self.readLines(peer, lines: 1, chunk: 64)
                    Darwin.close(peer)
                    if String(decoding: reply, as: UTF8.self).contains("\"ok\"") { answered.fulfill() }
                }
                wait(for: [answered, closed], timeout: 10)
            }
            // 2. Right before the reply: the request arrives, the client is gone.
            do {
                let (connection, peer) = try makePair()
                let closed = expectation(description: "closed before reply \(round)")
                connection.onClose = { closed.fulfill() }
                connection.onLine = { [weak connection] _ in connection?.send(["id": 1, "result": String(repeating: "r", count: 200_000)]) }
                _ = "{\"id\":1,\"method\":\"tools/list\"}\n".withCString { Darwin.write(peer, $0, strlen($0)) }
                Darwin.close(peer); descriptors.removeAll { $0 == peer }
                wait(for: [closed], timeout: 5)
            }
            // 3. In the middle of a large reply on a small buffer.
            do {
                let (connection, peer) = try makePair(sendBuffer: 4_096)
                let closed = expectation(description: "closed mid-reply \(round)")
                connection.onClose = { closed.fulfill() }
                connection.send(["body": String(repeating: "m", count: 1_000_000)])
                var buffer = [UInt8](repeating: 0, count: 8_192)
                _ = Darwin.read(peer, &buffer, buffer.count)
                Darwin.close(peer); descriptors.removeAll { $0 == peer }
                wait(for: [closed], timeout: 5)
            }
        }
        for connection in connections {
            let drained = expectation(description: "queued writes attempted")
            connection.afterPendingWrites { drained.fulfill() }
            wait(for: [drained], timeout: 5)
        }
        XCTAssertEqual(sigpipeDeliveries, 0, "a vanished client closes its connection, never the process")
    }

    func testServerConnectionSocketsAreNonBlockingAndRefuseSIGPIPE() throws {
        let (connection, _) = try makePair()
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(connection.fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
        XCTAssertNotEqual(value, 0, "SO_NOSIGPIPE is set on the server's connection socket")
        XCTAssertNotEqual(fcntl(connection.fd, F_GETFL) & O_NONBLOCK, 0, "and it is explicitly non-blocking")
    }

    func testTheStdioBridgeSocketAlsoRefusesSIGPIPE() throws {
        // A throwaway listener in the test's temporary folder stands in for
        // the app; the bridge's own connect path must set SO_NOSIGPIPE.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aom-mcp-\(UUID().uuidString.prefix(8)).sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        let fd = ClipboardMCPBridge.connect(path: path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
        XCTAssertNotEqual(value, 0)
    }

    /// The bridge answers, with an error, every request the app never
    /// answered when the app closes the connection (earlier review issue 8:
    /// it exited on EOF and requests in flight got no reply). This checks the
    /// bookkeeping it uses; the bridge process itself is not started here,
    /// since it would connect to the installed app's socket.
    func testTheBridgeKnowsWhichForwardedRequestsWereNeverAnswered() {
        let unanswered = ClipboardMCPBridge.Unanswered()
        unanswered.add(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        unanswered.add(#"{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{}}"#)
        unanswered.add(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{}}"#)
        unanswered.add(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)   // no id: never answered
        unanswered.resolve(reply: #"{"jsonrpc":"2.0","id":2,"result":{}}"#)
        unanswered.resolve(reply: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)        // a request from the app, not a reply
        let left = unanswered.drain().sorted()
        XCTAssertEqual(left.count, 2, "\(left)")
        XCTAssertTrue(left.contains { $0.contains(#""id":1,"#) }, "id 1 and id \"1\" are different requests")
        XCTAssertTrue(left.contains { $0.contains(#""id":"1""#) })
        XCTAssertEqual(unanswered.drain(), [], "each is handed out once")
    }
}
