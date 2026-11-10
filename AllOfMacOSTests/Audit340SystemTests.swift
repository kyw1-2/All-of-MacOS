import XCTest
@testable import AllOfMacOS

/// 3.4.0 audit: Apple Events failures (-1743, -1744, -600, -1712) explained
/// and the one safe retry; AppleScript's `run trigger` reporting a missing
/// trigger; an app given by name found without the deprecated lookup first;
/// the HomePod no longer asked for its IO size again and again. The script
/// runner, the delay and the report are replaced; nothing runs osascript,
/// sends an Apple event or touches an audio device.
final class Audit340SystemTests: XCTestCase {
    private var restore: (() -> Void)?

    override func setUp() {
        super.setUp()
        let runner = AppleEventScripts.runner, after = AppleEventScripts.after, report = AppleEventScripts.report
        restore = {
            AppleEventScripts.runner = runner
            AppleEventScripts.after = after
            AppleEventScripts.report = report
        }
        AppleEventScripts.after = { _, work in work() }
    }

    override func tearDown() {
        restore?()
        restore = nil
        super.tearDown()
    }

    // MARK: Reading osascript's output

    func testAppleEventsFailuresAreReadFromTheScriptOutput() {
        XCTAssertEqual(AppleEventFailure.classify(output: "/var/folders/x/T/1A2B:0:31: execution error: Not authorized to send Apple events to Finder. (-1743)\n"),
                       .notPermitted(app: "Finder"))
        XCTAssertEqual(AppleEventFailure.classify(output: "Error: Error: Not authorized to send Apple events to System Events. (-1743)"),
                       .notPermitted(app: "System Events"), "JavaScript for Automation")
        XCTAssertEqual(AppleEventFailure.classify(output: "execution error: System Events got an error: Application isn’t running. (-600)"),
                       .appNotRunning(app: "System Events"))
        XCTAssertEqual(AppleEventFailure.classify(output: "execution error: Not authorized to send Apple events to Music. (-1744)"),
                       .consentRequired(app: "Music"))
        XCTAssertEqual(AppleEventFailure.classify(output: "execution error: Finder got an error: AppleEvent timed out. (-1712)"),
                       .timedOut(app: "Finder"))
        XCTAssertNil(AppleEventFailure.classify(output: "execution error: The variable x is not defined. (-2753)"),
                     "an ordinary script error is not an Apple Events problem")
        XCTAssertNil(AppleEventFailure.classify(output: ""))
        XCTAssertEqual(AppleEventFailure.errorCode(in: "first (-600) then (-1743)"), -1743, "the status that ended the script")
    }

    func testTheAdviceSaysWhereToAllowAccess() {
        let denied = AppleEventFailure.notPermitted(app: "Finder")
        XCTAssertEqual(denied.title, "Automation Permission Needed")
        XCTAssertTrue(denied.detail.contains("System Settings › Privacy & Security › Automation"))
        XCTAssertTrue(denied.detail.contains("“Finder”"))
        XCTAssertTrue(AppleEventFailure.appNotRunning(app: nil).title.hasSuffix("Is Not Running"))
        XCTAssertTrue(AppleEventFailure.consentRequired(app: "Music").detail.contains("Allow"))
    }

    // MARK: AOM's own commands

    func testAnAppThatWasNotRunningIsAskedOnceMore() {
        var calls = 0
        var reports: [AppleEventFailure?] = []
        AppleEventScripts.report = { failure, _, _ in reports.append(failure) }
        AppleEventScripts.runner = { _, _, _, done in
            calls += 1
            calls == 1 ? done(1, "execution error: System Events got an error: Application isn’t running. (-600)", false)
                : done(0, "", false)
        }
        var result: Bool?
        AppleEventScripts.run("tell application \"System Events\" to …", action: "Dark Mode", timeout: 5) { result = $0 }
        XCTAssertEqual(calls, 2, "the event never reached it, so it is sent again once")
        XCTAssertEqual(result, true)
        XCTAssertTrue(reports.isEmpty)

        calls = 0
        AppleEventScripts.runner = { _, _, _, done in
            calls += 1
            done(1, "execution error: System Events got an error: Application isn’t running. (-600)", false)
        }
        AppleEventScripts.run("…", action: "Dark Mode", timeout: 5) { result = $0 }
        XCTAssertEqual(calls, 2, "once, not again and again")
        XCTAssertEqual(result, false)
        XCTAssertEqual(reports, [.appNotRunning(app: "System Events")])
    }

    func testARefusalIsExplainedAndNeverSentAgain() {
        var calls = 0
        var reports: [AppleEventFailure?] = []
        AppleEventScripts.report = { failure, _, _ in reports.append(failure) }
        AppleEventScripts.runner = { _, _, _, done in
            calls += 1
            done(1, "execution error: Not authorized to send Apple events to System Events. (-1743)", false)
        }
        var result: Bool?
        AppleEventScripts.run("…", action: "Dock hiding", timeout: 10) { result = $0 }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result, false, "reported as failed, as before")
        XCTAssertEqual(reports, [.notPermitted(app: "System Events")])

        reports = []
        AppleEventScripts.runner = { _, _, _, done in done(-1, "", true) }
        AppleEventScripts.run("…", action: "Empty Trash", timeout: 60) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(reports, [.timedOut(app: nil)], "a run that outlasted its limit")

        reports = []
        AppleEventScripts.runner = { _, _, _, done in done(1, "execution error: The variable x is not defined. (-2753)", false) }
        AppleEventScripts.run("…", action: "Log Out", timeout: 15) { result = $0 }
        XCTAssertEqual(reports, [nil], "any other failure is still reported, with what osascript said")
    }

    func testAPersonsOwnScriptIsExplainedButNeverRunAgain() {
        var reports: [AppleEventFailure?] = []
        AppleEventScripts.report = { failure, _, _ in reports.append(failure) }
        let denied = "execution error: Not authorized to send Apple events to Finder. (-1743)"
        XCTAssertEqual(AppleEventScripts.explain(kind: "applescript", output: denied), .notPermitted(app: "Finder"))
        XCTAssertEqual(AppleEventScripts.explain(kind: "javascript", output: denied), .notPermitted(app: "Finder"))
        XCTAssertNil(AppleEventScripts.explain(kind: "shell", output: denied), "a shell script is not AOM's Apple event")
        XCTAssertNil(AppleEventScripts.explain(kind: "applescript", output: "execution error: oops (-2700)"))
        XCTAssertEqual(reports.count, 2)
    }

    func testTheSameAdviceIsShownAtMostOnceAMinute() {
        let failure = AppleEventFailure.notPermitted(app: "Audit340 \(UUID().uuidString)")
        XCTAssertTrue(AppleEventScripts.shouldShow(failure, now: 1_000))
        XCTAssertFalse(AppleEventScripts.shouldShow(failure, now: 1_030))
        XCTAssertTrue(AppleEventScripts.shouldShow(failure, now: 1_061))
        XCTAssertTrue(AppleEventScripts.shouldShow(.notPermitted(app: "Audit340 other \(UUID().uuidString)"), now: 1_062))
    }

    // MARK: AppleScript's run trigger

    func testRunTriggerFailsInTheScriptWhenNoSingleNamedTriggerApplies() {
        XCTAssertNil(AOMScriptingRoute.namedTriggerProblem("Deploy", matches: { _ in 1 }))
        XCTAssertEqual(AOMScriptingRoute.namedTriggerProblem("Typo", matches: { _ in 0 }),
                       "No named trigger called “Typo” applies in the front app.")
        XCTAssertNotNil(AOMScriptingRoute.namedTriggerProblem("Twice", matches: { _ in 2 }))
        XCTAssertNotNil(AOMScriptingRoute.namedTriggerProblem("   ", matches: { _ in 1 }))

        var named = Trigger(name: "deploy", input: .namedTrigger("Audit340 Deploy"))
        named.actions = [TriggerAction(actionType: .playPause)]
        ActionExecutor.registerTriggers([named])
        defer { ActionExecutor.registerTriggers([]) }
        XCTAssertEqual(ActionExecutor.namedTriggerCandidates(" Audit340 Deploy ").count, 1)
        XCTAssertEqual(ActionExecutor.namedTriggerCandidates("Audit340 Typo").count, 0)
    }

    // MARK: An app given by name

    func testAnAppGivenByNameIsFoundInTheApplicationsFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Audit340Apps-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Audit340 Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Plain.app"))
        defer { try? FileManager.default.removeItem(at: folder) }
        var askedElsewhere: [String] = []
        let elsewhere: (String) -> URL? = { askedElsewhere.append($0); return nil }

        XCTAssertEqual(ActionExecutor.applicationURL(named: "Audit340 Fixture", in: [folder], elsewhere: elsewhere)?.lastPathComponent,
                       "Audit340 Fixture.app")
        XCTAssertEqual(ActionExecutor.applicationURL(named: " Audit340 Fixture.app ", in: [folder], elsewhere: elsewhere)?.lastPathComponent,
                       "Audit340 Fixture.app")
        XCTAssertEqual(askedElsewhere, [], "found in the folder: Launch Services is not asked")
        XCTAssertNil(ActionExecutor.applicationURL(named: "Plain", in: [folder], elsewhere: elsewhere), "a file is not an app")
        XCTAssertNil(ActionExecutor.applicationURL(named: "../Audit340 Fixture", in: [folder], elsewhere: elsewhere))
        XCTAssertNil(ActionExecutor.applicationURL(named: "", in: [folder], elsewhere: elsewhere))
        XCTAssertEqual(askedElsewhere, ["Plain"], "only a name not found in the folders goes further")
    }

// MARK: The HomePod's IO size

    /// A HomePod answers 0 and keeps 128-frame IO; each set on its running
    /// IO may restart it. It was asked 6 times an hour for the whole session.
    func testAHomePodThatKeepsItsIOSizeIsAskedTwiceThenLeftAlone() {
        typealias R = AirPlayOutputRenderer
        XCTAssertEqual(R.maximumUnheededIORequests, 2)
        XCTAssertTrue(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                                secondsSinceLastRequest: 30, unheededRequests: 0))
        XCTAssertTrue(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: true,
                                                secondsSinceLastRequest: 60, unheededRequests: 1))
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: true,
                                                 secondsSinceLastRequest: 86_400, unheededRequests: 2),
                       "a day later, gaps or not, it is not asked again")
        // Eight hours of health checks every 250 ms.
        var asked = 0, unheeded = 0, since = 0.0
        for _ in 0..<(8 * 3_600 * 4) {
            since += 0.25
            if R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                         secondsSinceLastRequest: since, unheededRequests: unheeded) {
                asked += 1; unheeded += 1; since = 0
            }
        }
        XCTAssertEqual(asked, 2)
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 1024, preferred: 1024, cycleGapsGrew: true,
                                                 secondsSinceLastRequest: 3_600, unheededRequests: 0),
                       "a device that took the size is never asked")
    }
}
