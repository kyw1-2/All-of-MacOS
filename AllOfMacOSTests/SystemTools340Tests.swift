import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import AllOfMacOS

/// 3.4.0 System Tools: Homebrew parsing and commands, VPN and Tailscale
/// parsing, page ranges, the PDF tools on generated PDFs, the Metal HUD
/// variable, Open-Meteo parsing, the uninstaller's review and the catalog.
/// Nothing here runs brew, scutil, Tailscale or the network; files live in a
/// temporary folder.
final class SystemTools340Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SystemTools340Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Homebrew

    /// `brew outdated --json=v2` as Homebrew 7.0.9 prints it (trimmed).
    static let outdatedJSON = """
    {"formulae":[{"name":"brotli","installed_versions":["1.2.0"],"current_version":"1.2.1","pinned":false,"pinned_version":null},
    {"name":"ada-url","installed_versions":["3.9.0","4.0.0"],"current_version":"4.0.0_1","pinned":false,"pinned_version":null},
    {"name":"node","installed_versions":["24.10.0"],"current_version":"24.11.1","pinned":true,"pinned_version":"24.10.0"}],
    "casks":[{"name":"swish","installed_versions":["1.12"],"current_version":"1.13.3","pinned":false,"pinned_version":null}]}
    """

    func testOutdatedJSONParsesFormulaeThenCasks() throws {
        let list = try Homebrew.parseOutdated(Data(Self.outdatedJSON.utf8))
        XCTAssertEqual(list.map(\.name), ["ada-url", "brotli", "node", "swish"], "Formulae by name, then casks")
        XCTAssertEqual(list.map(\.kind), [.formula, .formula, .formula, .cask])
        XCTAssertEqual(list[0].change, "4.0.0 → 4.0.0_1", "The newest installed version")
        XCTAssertTrue(list[2].pinned)
        XCTAssertEqual(list[3].id, "cask:swish")
        XCTAssertEqual(try Homebrew.parseOutdated(Data(#"{"formulae":[],"casks":[]}"#.utf8)), [])
        XCTAssertThrowsError(try Homebrew.parseOutdated(Data("Error: no".utf8)))
        // A warning line before the JSON doesn't break it.
        XCTAssertEqual(try Homebrew.parseOutdated(Data(("Warning: something\n" + Self.outdatedJSON).utf8)).count, 4)
    }

    static let installedJSON = """
    {"formulae":[{"name":"actionlint","full_name":"actionlint","tap":"homebrew/core","desc":"Static checker for GitHub Actions workflow files",
    "homepage":"https://rhysd.github.io/actionlint/","versions":{"stable":"1.7.12","head":"HEAD","bottle":true},
    "installed":[{"version":"1.7.12","installed_as_dependency":null,"installed_on_request":true,"time":1791836918}],"pinned":false,"outdated":false},
    {"name":"brotli","full_name":"brotli","desc":"Generic-purpose lossless compression algorithm by Google","homepage":"https://github.com/google/brotli",
    "versions":{"stable":"1.2.1"},"installed":[{"version":"1.2.0","installed_as_dependency":true,"installed_on_request":false}],"pinned":false,"outdated":true}],
    "casks":[{"token":"appcleaner","full_token":"appcleaner","tap":"homebrew/cask","name":["FreeMacSoft AppCleaner"],"desc":"Application uninstaller",
    "homepage":"https://freemacsoft.net/appcleaner/","version":"3.7","installed":"3.6.8","installed_time":1748737859,"outdated":false,"auto_updates":true},
    {"token":"no-desc","name":["No Description App"],"desc":null,"version":"2.0","installed":null,"outdated":false}]}
    """

    func testInstalledJSONParsesVersionsDependenciesAndCasks() throws {
        let list = try Homebrew.parseInstalled(Data(Self.installedJSON.utf8))
        XCTAssertEqual(list.map(\.name), ["actionlint", "brotli", "appcleaner", "no-desc"])
        XCTAssertEqual(list[0].version, "1.7.12")
        XCTAssertTrue(list[0].onRequest)
        XCTAssertFalse(list[1].onRequest, "Installed as a dependency")
        XCTAssertTrue(list[1].outdated)
        XCTAssertEqual(list[2].kind, .cask)
        XCTAssertEqual(list[2].version, "3.6.8", "A cask's installed version, not the newest")
        XCTAssertEqual(list[2].summary, "Application uninstaller")
        XCTAssertEqual(list[3].summary, "No Description App", "The cask's name when it has no description")
        XCTAssertEqual(list[3].version, "2.0")
    }

    static let servicesJSON = """
    [{"name":"atuin","status":"none","user":null,"file":"/opt/homebrew/opt/atuin/sh.brew.atuin.plist","exit_code":null},
     {"name":"postgresql@17","status":"started","user":"kim","file":"/Users/kim/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist","exit_code":0},
     {"name":"redis","status":"error","user":"kim","file":"/Users/kim/Library/LaunchAgents/homebrew.mxcl.redis.plist","exit_code":78},
     {"name":"cron-job","status":"scheduled","user":"kim","file":null,"exit_code":null}]
    """

    func testServicesJSONParsesStatus() throws {
        let list = try Homebrew.parseServices(Data(Self.servicesJSON.utf8))
        XCTAssertEqual(list.map(\.name), ["atuin", "cron-job", "postgresql@17", "redis"])
        XCTAssertEqual(list.map(\.status), [.none, .scheduled, .started, .error])
        XCTAssertEqual(list[2].exitCode, 0)
        XCTAssertEqual(list[3].exitCode, 78)
        XCTAssertTrue(list[1].status.isRunning && list[2].status.isRunning)
        XCTAssertFalse(list[0].status.isRunning || list[3].status.isRunning)
        XCTAssertEqual(Homebrew.Service.Status("weird").title, "Weird")
    }

    func testSearchCleanupVersionAndNameChecks() {
        XCTAssertEqual(Homebrew.parseSearch("tailscale\ntailcat\n\nNo formulae or casks found for \"x\".\nwget ✔\n"),
                       ["tailscale", "tailcat", "wget"])
        let dry = """
        Would remove: /opt/homebrew/Cellar/pcre2/10.48 (245 files, 7.3MB)
        Would remove (broken link): /opt/homebrew/bin/iina
        ==> This operation would free approximately 41.9MB of disk space.
        """
        XCTAssertEqual(Homebrew.cleanupItemCount(dry), 2)
        XCTAssertEqual(Homebrew.parseFreedSize(dry), Homebrew.FreedSize(text: "41.9MB", bytes: Int64((41.9 * 1_048_576).rounded())))
        XCTAssertEqual(Homebrew.parseFreedSize("==> This operation has freed approximately 2GB of disk space.")?.bytes, 2 * 1_073_741_824)
        XCTAssertEqual(Homebrew.parseFreedSize("==> This operation has freed approximately 1,024KB of disk space.")?.bytes, 1_048_576)
        XCTAssertEqual(Homebrew.parseFreedSize("...approximately 64B of disk space")?.bytes, nil, "Only brew's own sentence counts")
        XCTAssertEqual(Homebrew.parseFreedSize("==> This operation would free approximately 64B of disk space.")?.bytes, 64)
        XCTAssertNil(Homebrew.parseFreedSize("Nothing to clean up"))
        XCTAssertEqual(Homebrew.versionLine("Homebrew 7.0.9-70-g1397358-dirty\nHomebrew/homebrew-core (git revision 1)"), "Homebrew 7.0.9")
        XCTAssertNil(Homebrew.versionLine("zsh: command not found"))
        for good in ["wget", "node@22", "homebrew/cask/iterm2", "c++-utils", "python@3.13"] {
            XCTAssertTrue(Homebrew.isValidPackageName(good), good)
        }
        for bad in ["", "-f", "--force", "../evil", "a b", "name;rm", "tap/", String(repeating: "a", count: 201)] {
            XCTAssertFalse(Homebrew.isValidPackageName(bad), bad)
        }
        XCTAssertTrue(Homebrew.isValidSearchText("visual studio"))
        XCTAssertFalse(Homebrew.isValidSearchText("--desc"))
        XCTAssertFalse(Homebrew.isValidSearchText("a;b"))
        XCTAssertTrue(Homebrew.neededTerminalPassword("sudo: a terminal is required to read the password"))
        XCTAssertFalse(Homebrew.neededTerminalPassword("==> Pouring wget"))
    }

    func testCommandsUseArgumentArraysAndNoAutoUpdate() {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let environment = Homebrew.environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "HOMEBREW_COLOR": "1"], brew: brew)
        XCTAssertEqual(environment["PATH"]?.split(separator: ":").first, "/opt/homebrew/bin")
        XCTAssertTrue(environment["PATH"]?.contains("/opt/homebrew/sbin") == true)
        XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertNil(environment["HOMEBREW_COLOR"])
        XCTAssertEqual(environment["HOME"], "/Users/test", "The user's own environment is kept")
        XCTAssertNil(Homebrew.environment(base: ["HOMEBREW_NO_AUTO_UPDATE": "1"], brew: brew, autoUpdate: true)["HOMEBREW_NO_AUTO_UPDATE"])
        XCTAssertEqual(Homebrew.locate(candidates: ["/nope/brew", "/opt/x/brew"], isExecutable: { $0 == "/opt/x/brew" })?.path, "/opt/x/brew")
        XCTAssertNil(Homebrew.locate(candidates: ["/nope/brew"], isExecutable: { _ in false }))

        let wget = Homebrew.Package(kind: .formula, name: "wget"), iterm = Homebrew.Package(kind: .cask, name: "iterm2")
        XCTAssertEqual(Homebrew.Command.outdated.arguments, ["outdated", "--json=v2"])
        XCTAssertEqual(Homebrew.Command.installed.arguments, ["info", "--json=v2", "--installed"])
        XCTAssertEqual(Homebrew.Command.services.arguments, ["services", "list", "--json"])
        XCTAssertEqual(Homebrew.Command.upgrade(iterm).arguments, ["upgrade", "--cask", "iterm2"])
        XCTAssertEqual(Homebrew.Command.install(wget).arguments, ["install", "--formula", "wget"])
        XCTAssertEqual(Homebrew.Command.uninstall(iterm).arguments, ["uninstall", "--cask", "iterm2"])
        XCTAssertEqual(Homebrew.Command.cleanupDryRun.arguments, ["cleanup", "-n", "-s"])
        XCTAssertEqual(Homebrew.Command.service(.restart, "redis").arguments, ["services", "restart", "redis"])
        XCTAssertEqual(Homebrew.Command.search("wget", .cask).arguments, ["search", "--cask", "wget"])
        XCTAssertTrue(Homebrew.Command.update.autoUpdate)
        XCTAssertFalse(Homebrew.Command.upgradeAll.autoUpdate)
        XCTAssertTrue(Homebrew.Command.upgradeAll.changesPackages)
        XCTAssertFalse(Homebrew.Command.outdated.changesPackages)
        XCTAssertGreaterThan(Homebrew.Command.upgradeAll.timeout, Homebrew.Command.outdated.timeout)
        XCTAssertEqual(Homebrew.Command.service(.stop, "redis").title, "Stopping redis")
    }

    // MARK: - Streaming command

    func testLineSplittingKeepsTheUnfinishedTail() {
        var buffer = Data("one\ntwo\r\nthree\rfour".utf8)
        XCTAssertEqual(StreamingCommand.takeLines(from: &buffer), ["one", "two", "three"])
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "four")
    }

    func testStreamingCommandStreamsLinesAndReportsTheExitStatus() async throws {
        let lines = LockedLines()
        let command = StreamingCommand(URL(fileURLWithPath: "/usr/bin/printf"), ["alpha\\nbeta\\n"], timeout: 10)
        let result = try await command.run { _, line in lines.append(line) }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "alpha\nbeta\n")
        XCTAssertEqual(lines.all, ["alpha", "beta"])
        let failing = try await StreamingCommand(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 10).run()
        XCTAssertEqual(failing.status, 1)
        XCTAssertFalse(failing.succeeded)
        do {
            _ = try await StreamingCommand(URL(fileURLWithPath: "/no/such/tool"), [], timeout: 1).run()
            XCTFail("A missing executable throws")
        } catch {
            XCTAssertEqual(error as? StreamingCommand.Failure, .notExecutable("/no/such/tool"))
        }
    }

    func testCancelAndTimeoutStopTheProcess() async throws {
        let sleeper = StreamingCommand(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 60)
        let started = Date()
        Task { try? await Task.sleep(for: .milliseconds(300)); sleeper.cancel() }
        let cancelled = try await sleeper.run()
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertFalse(cancelled.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let slow = try await StreamingCommand(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.4).run()
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.succeeded)
    }

    // MARK: - VPN

    static let scutilList = """
    Available network connection services in the current set (*=enabled):
    * (Connected)      FB2D4BFB-7674-4BF8-8B57-98D4E7E5C8FA VPN (io.tailscale.ipn.macsys) "Tailscale"                      [VPN:io.tailscale.ipn.macsys]
    * (Disconnected)   2A1B3C4D-1111-2222-3333-444455556666 PPP --> L2TP       "Campus VPN"                     [PPP/L2TP]
      (Disconnected)   9F8E7D6C-AAAA-BBBB-CCCC-DDDDEEEEFFFF IPSec              "Office "HQ" VPN"                [IPSec]
    * (Connecting)     0a0b0c0d-0e0f-1011-1213-141516171819 VPN (com.wireguard.macos) "WireGuard Home"     [VPN/com.wireguard.macos]
    """

    func testSCUtilListParsesStateTypeAndNames() {
        let list = VPNTools.parseServiceList(Self.scutilList)
        XCTAssertEqual(list.map(\.name), ["Tailscale", "Campus VPN", "Office \"HQ\" VPN", "WireGuard Home"])
        XCTAssertEqual(list.map(\.state), [.connected, .disconnected, .disconnected, .connecting])
        XCTAssertEqual(list.map(\.enabled), [true, true, false, true])
        XCTAssertEqual(list.map(\.kindTitle), ["Tailscale", "L2TP", "IPSec", "WireGuard"])
        XCTAssertEqual(list[0].providerBundleID, "io.tailscale.ipn.macsys")
        XCTAssertEqual(list[3].id, "0A0B0C0D-0E0F-1011-1213-141516171819", "IDs are compared upper-case")
        XCTAssertEqual(VPNTools.toggleArguments(for: list[0]), ["--nc", "stop", "FB2D4BFB-7674-4BF8-8B57-98D4E7E5C8FA"])
        XCTAssertEqual(VPNTools.toggleArguments(for: list[1]), ["--nc", "start", "2A1B3C4D-1111-2222-3333-444455556666"])
        XCTAssertEqual(VPNTools.toggleArguments(for: list[3]).dropFirst().first, "stop", "Connecting can be stopped")
        XCTAssertEqual(VPNTools.parseServiceList("Available network connection services in the current set (*=enabled):\n"), [])
        XCTAssertEqual(SystemToolsModel.vpnState(list), .on("Tailscale"))
        XCTAssertEqual(SystemToolsModel.vpnState([]), .value("None"))
        XCTAssertEqual(SystemToolsModel.vpnState([list[1]]), .off())
    }

    static let tailscaleRunning = """
    {"Version":"1.98.10-t0ee734d30-g6b4108809","TUN":true,"BackendState":"Running","AuthURL":"",
     "TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"],
     "Self":{"ID":"n1","HostName":"MacBook-Air","DNSName":"macbook-air.tail1234.ts.net.","OS":"macOS",
             "TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"],"Online":true,"ExitNode":false,"ExitNodeOption":false},
     "Health":[],"MagicDNSSuffix":"tail1234.ts.net",
     "CurrentTailnet":{"Name":"example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
     "Peer":{"nodekey:aa":{"ID":"n2","HostName":"home-server","DNSName":"home-server.tail1234.ts.net.","Online":true,
                           "ExitNode":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]},
             "nodekey:bb":{"ID":"n3","HostName":"iphone","DNSName":"iphone.tail1234.ts.net.","Online":false,
                           "ExitNode":false,"ExitNodeOption":false,"TailscaleIPs":["100.64.0.3"]}},
     "ExitNodeStatus":{"ID":"n2","Online":true,"TailscaleIPs":["100.64.0.2/32"]}}
    """

    /// The shape this Mac's Tailscale 1.98 prints before logging in.
    static let tailscaleNeedsLogin = """
    {"Version":"1.98.10-t0ee734d30-g6b4108809","TUN":true,"BackendState":"NeedsLogin","AuthURL":"","TailscaleIPs":null,
     "Self":{"ID":"","PublicKey":"nodekey:0000","HostName":"MacBook-Air","DNSName":"","OS":"","UserID":0,"TailscaleIPs":null,
             "Online":false,"ExitNode":false,"ExitNodeOption":false},
     "Health":["Tailscale is stopped."],"MagicDNSSuffix":"","CurrentTailnet":null,"Peer":null,"User":null,"ClientVersion":null}
    """

    func testTailscaleStatusParsesAddressExitNodeAndLoginState() throws {
        let running = try VPNTools.parseTailscaleStatus(Data(Self.tailscaleRunning.utf8))
        XCTAssertEqual(running.backend, .running)
        XCTAssertEqual(running.version, "1.98.10")
        XCTAssertEqual(running.addresses.first, "100.101.102.103", "IPv4 first")
        XCTAssertEqual(running.ipv4, "100.101.102.103")
        XCTAssertEqual(running.dnsName, "macbook-air.tail1234.ts.net")
        XCTAssertEqual(running.tailnet, "example.com")
        XCTAssertEqual(running.exitNode, "home-server")
        XCTAssertEqual(running.exitNodeOptions, 1)
        XCTAssertEqual(running.onlinePeers, 1)
        XCTAssertEqual(SystemToolsModel.tailscaleState(running), .on("100.101.102.103"))

        let login = try VPNTools.parseTailscaleStatus(Data(Self.tailscaleNeedsLogin.utf8))
        XCTAssertEqual(login.backend, .needsLogin)
        XCTAssertEqual(login.backend.title, "Not logged in")
        XCTAssertTrue(login.addresses.isEmpty)
        XCTAssertNil(login.ipv4)
        XCTAssertNil(login.tailnet)
        XCTAssertNil(login.exitNode)
        XCTAssertNil(login.dnsName)
        XCTAssertEqual(login.health, ["Tailscale is stopped."])
        XCTAssertEqual(SystemToolsModel.tailscaleState(login), .value("Log In"))

        XCTAssertThrowsError(try VPNTools.parseTailscaleStatus(Data("failed to connect".utf8)))
        XCTAssertTrue(VPNTools.tailscaleNotRunning("failed to connect to local Tailscale service; is Tailscale running?"))
        XCTAssertFalse(VPNTools.tailscaleNotRunning("Success."))
    }

    // MARK: - Page ranges

    func testPageRangesParseListsOpenEndsAndBackwards() throws {
        XCTAssertEqual(try PageRanges.pages("1-3, 5, 8-", pageCount: 10), [1, 2, 3, 5, 8, 9, 10])
        XCTAssertEqual(try PageRanges.pages("-2", pageCount: 10), [1, 2])
        XCTAssertEqual(try PageRanges.pages("5–3", pageCount: 10), [5, 4, 3], "An en dash and a backwards range")
        XCTAssertEqual(try PageRanges.pages("end; 1", pageCount: 4), [4, 1])
        XCTAssertEqual(try PageRanges.pages(" 2 - 4 ", pageCount: 4), [2, 3, 4])
        XCTAssertEqual(try PageRanges.groups("1-2, 3, 4-", pageCount: 6), [[1, 2], [3], [4, 5, 6]])
        XCTAssertEqual(try PageRanges.set("3, 1-2, 3", pageCount: 5), [1, 2, 3])
        XCTAssertThrowsError(try PageRanges.pages("", pageCount: 3)) { XCTAssertEqual($0 as? PageRanges.ParseError, .empty) }
        XCTAssertThrowsError(try PageRanges.pages("0", pageCount: 3)) { XCTAssertEqual($0 as? PageRanges.ParseError, .notAPage("0")) }
        XCTAssertThrowsError(try PageRanges.pages("4", pageCount: 3)) { XCTAssertEqual($0 as? PageRanges.ParseError, .outOfRange(4, count: 3)) }
        XCTAssertThrowsError(try PageRanges.pages("1-2-3", pageCount: 5))
        XCTAssertThrowsError(try PageRanges.pages("a", pageCount: 5))
        XCTAssertThrowsError(try PageRanges.pages("-", pageCount: 5))
        XCTAssertEqual(try PageRanges.reorder("3, 1", pageCount: 4), [3, 1, 2, 4], "Pages left out follow in order")
        XCTAssertThrowsError(try PageRanges.reorder("2, 1-3", pageCount: 4), "A page written twice")
        XCTAssertEqual(PageRanges.describe([1, 2, 3, 5, 7, 8]), "1-3, 5, 7-8")
    }

    // MARK: - PDF tools

    /// A PDF whose pages say "Page 1" … "Page n" (300 × 400 pt).
    private func makePDF(pages: Int, name: String = "Source.pdf") throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 1...pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 24)])
            context.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func labels(_ url: URL) throws -> [String] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).map { index in
            let text = document.page(at: index)?.string ?? ""
            return text.range(of: #"Page \d+"#, options: .regularExpression).map { String(text[$0]) } ?? "?"
        }
    }

    func testSplitExtractRemoveRotateAndReorderWriteNewFiles() throws {
        let source = try makePDF(pages: 5)
        let original = try Data(contentsOf: source)

        let singles = try PDFTools.splitIntoPages(source, into: folder)
        XCTAssertEqual(singles.map(\.lastPathComponent), (1...5).map { "Source - Page \($0).pdf" })
        XCTAssertEqual(try labels(singles[3]), ["Page 4"])

        let parts = try PDFTools.split(source, ranges: "1-2, 3-", into: folder)
        XCTAssertEqual(parts.map(\.lastPathComponent), ["Source (pages 1-2).pdf", "Source (pages 3-5).pdf"])
        XCTAssertEqual(try labels(parts[1]), ["Page 3", "Page 4", "Page 5"])

        let extracted = folder.appendingPathComponent("Extract.pdf")
        XCTAssertEqual(try PDFTools.extract(source, pages: "4, 2", to: extracted), 2)
        XCTAssertEqual(try labels(extracted), ["Page 4", "Page 2"])

        let removed = folder.appendingPathComponent("Removed.pdf")
        XCTAssertEqual(try PDFTools.remove(source, pages: "2-3", to: removed), 3)
        XCTAssertEqual(try labels(removed), ["Page 1", "Page 4", "Page 5"])
        XCTAssertThrowsError(try PDFTools.remove(source, pages: "1-5", to: folder.appendingPathComponent("None.pdf"))) {
            XCTAssertEqual($0 as? PDFTools.Failure, .empty)
        }

        let rotated = folder.appendingPathComponent("Rotated.pdf")
        XCTAssertEqual(try PDFTools.rotate(source, pages: "1, 3", degrees: 90, to: rotated), 2)
        let turned = try XCTUnwrap(PDFDocument(url: rotated))
        XCTAssertEqual((0..<turned.pageCount).map { turned.page(at: $0)?.rotation }, [90, 0, 90, 0, 0])
        let left = folder.appendingPathComponent("Left.pdf")
        XCTAssertEqual(try PDFTools.rotate(rotated, pages: "", degrees: -90, to: left), 5, "Empty means every page")
        let back = try XCTUnwrap(PDFDocument(url: left))
        XCTAssertEqual((0..<back.pageCount).map { back.page(at: $0)?.rotation }, [0, 270, 0, 270, 270])

        let reordered = folder.appendingPathComponent("Reordered.pdf")
        XCTAssertEqual(try PDFTools.reorder(source, order: "5, 1", to: reordered), [5, 1, 2, 3, 4])
        XCTAssertEqual(try labels(reordered), ["Page 5", "Page 1", "Page 2", "Page 3", "Page 4"])

        XCTAssertEqual(try Data(contentsOf: source), original, "The original is never changed")
        XCTAssertEqual(PDFTools.freeURL(in: folder, base: "Extract").lastPathComponent, "Extract 2.pdf", "Names never collide")
    }

    func testPDFToImagesRendersAtTheChosenDPIUpright() throws {
        let source = try makePDF(pages: 2)
        let rotated = folder.appendingPathComponent("Turned.pdf")
        _ = try PDFTools.rotate(source, pages: "2", degrees: 90, to: rotated)
        let out = folder.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pngs = try PDFTools.pdfToImages(rotated, format: .png, dpi: 150, into: out)
        XCTAssertEqual(pngs.map(\.lastPathComponent), ["Turned - Page 1.png", "Turned - Page 2.png"])
        func size(_ url: URL) throws -> CGSize {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return CGSize(width: image.width, height: image.height)
        }
        XCTAssertEqual(try size(pngs[0]), CGSize(width: 625, height: 833), "300 × 400 pt at 150 dpi")
        XCTAssertEqual(try size(pngs[1]), CGSize(width: 833, height: 625), "A rotated page renders upright")
        let jpegs = try PDFTools.pdfToImages(source, format: .jpeg, dpi: 72, into: out)
        XCTAssertEqual(jpegs.first?.pathExtension, "jpg")
        XCTAssertEqual(try size(jpegs[0]), CGSize(width: 300, height: 400))
        let type = CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(jpegs[0] as CFURL, nil))) as String?
        XCTAssertEqual(type, UTType.jpeg.identifier)
    }

    /// A 40 × 20 px JPEG stored landscape with EXIF orientation 6 (shown
    /// portrait, the way phones save portrait photos).
    private func makeRotatedJPEG() throws -> URL {
        let url = folder.appendingPathComponent("Phone.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImagesToPDFMakesOnePageEachAndHonoursOrientation() throws {
        let jpeg = try makeRotatedJPEG()
        let png = folder.appendingPathComponent("Wide.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let text = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: text)

        let natural = folder.appendingPathComponent("Natural.pdf")
        XCTAssertEqual(try PDFTools.imagesToPDF([jpeg, text, png], pageSize: .image, to: natural), 2, "The text file is skipped")
        let document = try XCTUnwrap(PDFDocument(url: natural))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 20, height: 40), "Orientation 6 is shown portrait")
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 80, height: 40))

        let a4 = folder.appendingPathComponent("A4.pdf")
        XCTAssertEqual(try PDFTools.imagesToPDF([png], pageSize: .a4, to: a4), 1)
        let page = try XCTUnwrap(PDFDocument(url: a4)?.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(page.width, 841.89, accuracy: 0.01, "A wide image gets a landscape A4 page")
        XCTAssertEqual(page.height, 595.28, accuracy: 0.01)

        XCTAssertThrowsError(try PDFTools.imagesToPDF([text], pageSize: .letter, to: folder.appendingPathComponent("No.pdf"))) {
            XCTAssertEqual($0 as? PDFTools.Failure, .noImages)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("No.pdf").path), "No empty file is left")
    }

    func testPasswordsAreAddedAndRemoved() throws {
        let source = try makePDF(pages: 3)
        let locked = folder.appendingPathComponent("Locked.pdf")
        try PDFTools.protect(source, password: "s3cret", to: locked)
        let check = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(check.isEncrypted)
        XCTAssertTrue(check.isLocked)
        XCTAssertFalse(check.unlock(withPassword: "wrong"))
        XCTAssertTrue(check.unlock(withPassword: "s3cret"))
        XCTAssertThrowsError(try PDFTools.open(locked)) { XCTAssertEqual($0 as? PDFTools.Failure, .locked("Locked.pdf")) }

        let open = folder.appendingPathComponent("Open.pdf")
        XCTAssertThrowsError(try PDFTools.unprotect(locked, password: "nope", to: open)) {
            XCTAssertEqual($0 as? PDFTools.Failure, .wrongPassword)
        }
        try PDFTools.unprotect(locked, password: "s3cret", to: open)
        let plain = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertEqual(try labels(open), ["Page 1", "Page 2", "Page 3"])
        XCTAssertThrowsError(try PDFTools.unprotect(source, password: "x", to: folder.appendingPathComponent("X.pdf"))) {
            XCTAssertEqual($0 as? PDFTools.Failure, .notEncrypted("Source.pdf"))
        }
    }

    func testPageNumbersAreAddedToEveryPage() throws {
        let source = try makePDF(pages: 3)
        let numbered = folder.appendingPathComponent("Numbered.pdf")
        XCTAssertEqual(try PDFTools.addPageNumbers(source, position: .bottomCenter, style: .ofTotal, to: numbered), 3)
        let document = try XCTUnwrap(PDFDocument(url: numbered))
        for index in 0..<3 {
            let page = try XCTUnwrap(document.page(at: index))
            let number = try XCTUnwrap(page.annotations.first { $0.contents == "Page \(index + 1) of 3" })
            let box = page.bounds(for: .cropBox)
            XCTAssertTrue(box.contains(number.bounds), "Inside the page")
            XCTAssertEqual(number.bounds.midX, box.midX, accuracy: 1, "Centred")
            XCTAssertLessThan(number.bounds.minY, 60, "At the bottom")
        }
        XCTAssertEqual(PDFTools.NumberStyle.plain.text(page: 4, total: 9), "4")
        // Top right on an unrotated page.
        let page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        let corner = PDFTools.numberRect(page: page, size: CGSize(width: 30, height: 14), position: .topRight)
        XCTAssertEqual(corner.maxX, 300 - 24, accuracy: 0.01)
        XCTAssertEqual(corner.maxY, 400 - 24, accuracy: 0.01)
    }

    // MARK: - Metal HUD

    func testMetalHUDReadsLaunchctlGetenv() {
        XCTAssertTrue(MetalHUD.isOn(getenvOutput: "1\n"))
        XCTAssertTrue(MetalHUD.isOn(getenvOutput: "2"))
        XCTAssertFalse(MetalHUD.isOn(getenvOutput: ""))
        XCTAssertFalse(MetalHUD.isOn(getenvOutput: "\n"))
        XCTAssertFalse(MetalHUD.isOn(getenvOutput: "0\n"))
        XCTAssertFalse(MetalHUD.isOn(getenvOutput: "yes"))
        XCTAssertFalse(MetalHUD.isOn(value: nil))
        XCTAssertEqual(MetalHUD.writeArguments(on: true), ["setenv", "MTL_HUD_ENABLED", "1"])
        XCTAssertEqual(MetalHUD.writeArguments(on: false), ["unsetenv", "MTL_HUD_ENABLED"])
        XCTAssertEqual(MetalHUD.readArguments, ["getenv", "MTL_HUD_ENABLED"])
    }

    // MARK: - Weather

    /// Open-Meteo's forecast for Seoul, as fetched on 31 Oct 2026.
    static let forecastJSON = """
    {"latitude":37.55,"longitude":127.0,"generationtime_ms":0.236,"utc_offset_seconds":32400,"timezone":"Asia/Seoul",
     "timezone_abbreviation":"GMT+9","elevation":27.0,
     "current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","apparent_temperature":"°C","relative_humidity_2m":"%","weather_code":"wmo code","wind_speed_10m":"km/h","is_day":""},
     "current":{"time":"2026-10-31T22:15","interval":900,"temperature_2m":8.1,"apparent_temperature":5.4,"relative_humidity_2m":49,"weather_code":2,"wind_speed_10m":1.8,"is_day":0},
     "daily_units":{"time":"iso8601","weather_code":"wmo code","temperature_2m_max":"°C","temperature_2m_min":"°C","precipitation_probability_max":"%"},
     "daily":{"time":["2026-10-31","2026-11-01","2026-11-02"],"weather_code":[3,53,3],"temperature_2m_max":[14.1,9.8,13.6],
              "temperature_2m_min":[7.4,6.4,7.0],"precipitation_probability_max":[47,91,41]}}
    """

    static let placesJSON = """
    {"results":[{"id":1838524,"name":"Busan","latitude":35.10168,"longitude":129.03004,"elevation":15.0,"feature_code":"PPLA",
      "country_code":"KR","admin1_id":1838519,"timezone":"Asia/Seoul","population":3285147,"country_id":1835841,"country":"South Korea","admin1":"Busan"},
     {"id":1838525,"name":"Busan","latitude":37.04463,"longitude":128.06786,"elevation":781.0,"feature_code":"MT","country_code":"KR",
      "timezone":"Asia/Seoul","country":"South Korea","admin1":"North Chungcheong","admin2":"Chungju-si"}],"generationtime_ms":0.14}
    """

    func testOpenMeteoForecastAndPlacesParse() throws {
        let forecast = try OpenMeteo.parseForecast(Data(Self.forecastJSON.utf8))
        XCTAssertEqual(forecast.temperature, 8.1)
        XCTAssertEqual(forecast.feelsLike, 5.4)
        XCTAssertEqual(forecast.humidity, 49)
        XCTAssertEqual(forecast.code, 2)
        XCTAssertFalse(forecast.isDay)
        XCTAssertEqual(forecast.timezone?.identifier, "Asia/Seoul")
        XCTAssertEqual(forecast.days.count, 3)
        XCTAssertEqual(forecast.days[1].code, 53)
        XCTAssertEqual(forecast.days[1].high, 9.8)
        XCTAssertEqual(forecast.days[1].low, 6.4)
        XCTAssertEqual(forecast.days[1].precipitationChance, 91)
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        XCTAssertEqual(forecast.observed, seoul.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22, minute: 15)))
        XCTAssertEqual(forecast.days[0].date, seoul.date(from: DateComponents(year: 2026, month: 10, day: 31)))

        let places = try OpenMeteo.parsePlaces(Data(Self.placesJSON.utf8))
        XCTAssertEqual(places.map(\.id), [1838524, 1838525])
        XCTAssertEqual(places[0].title, "Busan, South Korea", "A region named like the city isn't repeated")
        XCTAssertEqual(places[1].title, "Busan, North Chungcheong, South Korea")
        XCTAssertEqual(places[0].timezone, "Asia/Seoul")
        XCTAssertEqual(try OpenMeteo.parsePlaces(Data(#"{"generationtime_ms":0.1}"#.utf8)), [], "No results key: nothing matched")
        XCTAssertThrowsError(try OpenMeteo.parsePlaces(Data(#"{"error":true,"reason":"Parameter 'name' is required"}"#.utf8))) {
            XCTAssertEqual($0 as? OpenMeteo.Failure, .service("Parameter 'name' is required"))
        }
        XCTAssertThrowsError(try OpenMeteo.parseForecast(Data(#"{"latitude":1}"#.utf8)))

        XCTAssertEqual(OpenMeteo.condition(2), "Partly cloudy")
        XCTAssertEqual(OpenMeteo.condition(95), "Thunderstorm")
        XCTAssertEqual(OpenMeteo.symbol(0, isDay: false), "moon.stars.fill")
        XCTAssertEqual(OpenMeteo.symbol(73), "cloud.snow.fill")
        XCTAssertEqual(OpenMeteo.condition(1234), "Unknown")

        let url = try XCTUnwrap(OpenMeteo.forecastURL(places[0]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value, "35.1017")
        XCTAssertEqual(items.first { $0.name == "timezone" }?.value, "auto")
        XCTAssertNil(items.first { $0.name.lowercased().contains("key") }, "No API key")
        XCTAssertEqual(OpenMeteo.searchURL("New York")?.host, "geocoding-api.open-meteo.com")
    }

    func testWeatherRefreshesEveryThirtyMinutesAndStartsOff() {
        let now = Date()
        XCTAssertTrue(WeatherCardModel.isStale(updated: nil, now: now))
        XCTAssertFalse(WeatherCardModel.isStale(updated: now.addingTimeInterval(-29 * 60), now: now))
        XCTAssertTrue(WeatherCardModel.isStale(updated: now.addingTimeInterval(-30 * 60), now: now))
        XCTAssertTrue(WeatherCardModel.enabledKey.hasPrefix("AOMSystemTools"))
        let suite = "SystemTools340Tests.weather.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MainActor.assumeIsolated { WeatherCardModel(defaults: defaults) }
        XCTAssertFalse(MainActor.assumeIsolated { model.isOn }, "Off until turned on")
        XCTAssertNil(MainActor.assumeIsolated { model.place })
    }

    // MARK: - Uninstaller review (design-3.4.0 b.16)

    func testUninstallReviewChecksBundleIDMatchesOnly() throws {
        let app = folder.appendingPathComponent("Apps/Notes Pro.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Notes", "CFBundleName": "Notes Pro"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let library = folder.appendingPathComponent("Library")
        func write(_ path: String) throws -> URL {
            let url = library.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url)
            return url
        }
        let prefs = try write("Preferences/com.example.Notes.plist")
        let cache = try write("Caches/com.example.Notes/cache.db").deletingLastPathComponent()
        let named = try write("Application Support/Notes Pro/data").deletingLastPathComponent()
        _ = try write("Preferences/com.example.Other.plist")
        let review = try CleanupTools.uninstallReview(for: app, library: library, isRunning: { _ in false })
        XCTAssertEqual(review.items.first?.url, app, "The app first")
        XCTAssertEqual(review.items.dropFirst().map(\.note), ["Application Support", "Caches", "Preferences"], "By folder")
        XCTAssertEqual(review.nameOnly, [named.path])
        XCTAssertEqual(review.preselected, Set([app.path, cache.path, prefs.path]))
        XCTAssertFalse(review.preselected.contains(named.path), "A name-only match isn't checked")
        let matcher = CleanupTools.LeftoverMatcher(bundleID: "com.example.Notes", appName: "Notes Pro")
        XCTAssertEqual(matcher.matchKind("com.example.Notes.plist", allowNameMatch: true), .bundleID)
        XCTAssertEqual(matcher.matchKind("Notes Pro", allowNameMatch: true), .name)
        XCTAssertNil(matcher.matchKind("Notes Pro", allowNameMatch: false))
    }

    // MARK: - Catalog

    func testNewToolsAreInTheCatalogWithTheirRequirements() {
        // At least: the integrator adds tiles other branches made (such as
        // Install Disk Image…), so the total is not fixed here.
        let older = SystemToolCatalog.all.filter { !SystemToolsModel.tools340.contains($0.id) }
        XCTAssertGreaterThanOrEqual(older.count, 104, "Every 3.3.x tool kept")
        for id in SystemToolsModel.tools340 {
            XCTAssertNotNil(SystemToolCatalog.all.first { $0.id == id }, id.rawValue)
        }
        XCTAssertEqual(SystemToolsModel.tools340.count, 22)
        XCTAssertEqual(SystemToolCatalog.tools(in: .homebrew).count, 8)
        XCTAssertTrue(SystemToolCatalog.tools(in: .homebrew).allSatisfy { $0.requirement == .homebrew })
        XCTAssertEqual(SystemToolCatalog.tools(in: .pdf).count, 12, "Merge, Compress and the 10 page tools")
        XCTAssertEqual(SystemToolCatalog.info(.tailscale).requirement, .tailscale)
        XCTAssertEqual(SystemToolCatalog.info(.openVPN).requirement, .openVPNConnect)
        XCTAssertNil(SystemToolCatalog.info(.vpn).requirement, "scutil is always there")
        XCTAssertEqual(SystemToolCatalog.info(.uninstall).group, .apps, "design-3.4.0 b.16: System Tools › Apps")
        XCTAssertTrue(SystemToolCatalog.info(.metalHUD).isToggle)
        XCTAssertTrue(SystemToolCatalog.info(.metalHUD).help.contains("opened after"), "Says it only affects apps opened later")
        XCTAssertEqual(SystemToolsInventory.count, SystemToolCatalog.available.count)
        XCTAssertLessThanOrEqual(SystemToolsInventory.subtitle.count, 24)
        XCTAssertTrue(SystemToolsInventory.groups.allSatisfy { !$0.toolIDs.isEmpty })
        func hits(_ query: String) -> Set<SystemToolID> { Set(SystemToolCatalog.all.filter { $0.matches(query) }.map(\.id)) }
        XCTAssertTrue(hits("pdfgear").isSuperset(of: [.pdfSplit, .pdfToImages, .pdfPageNumbers]))
        XCTAssertTrue(hits("brew").isSuperset(of: [.brewOutdated, .brewCleanup]))
        XCTAssertTrue(hits("vpn").isSuperset(of: [.vpn, .tailscale, .openVPN]))
        XCTAssertTrue(hits("fps").contains(.metalHUD))
        XCTAssertLessThanOrEqual(SystemToolsModel.failureSeconds(String(repeating: "x", count: 1000)), 12)
    }
}

/// Lines collected from a background queue.
private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
