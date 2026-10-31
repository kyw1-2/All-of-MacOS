import XCTest
@testable import AllOfMacOS

/// Text Actions: when the bar goes away (the state machine, fed with events
/// and an injected clock).
final class TextActionsDismissalTests: XCTestCase {
    private func shownBar(at time: TimeInterval = 100, hideDelay: TimeInterval = 4) -> TextActionBarLifecycle {
        var bar = TextActionBarLifecycle(hideDelay: hideDelay)
        XCTAssertEqual(bar.handle(.shown(at: time)), .wake(at: time + hideDelay))
        return bar
    }

    func testShowingArmsTheTimeout() {
        let bar = shownBar()
        XCTAssertEqual(bar.phase, .shown)
        XCTAssertEqual(bar.deadline, 104)
        XCTAssertFalse(bar.pointerInside)
    }

    func testTheTimeoutHidesTheBarWhileThePointerIsAway() {
        var bar = shownBar()
        XCTAssertEqual(bar.handle(.tick(at: 102)), .wake(at: 104), "too early: wait again")
        XCTAssertEqual(bar.handle(.tick(at: 104)), .hide(.timeout))
        XCTAssertEqual(bar.phase, .hidden)
        XCTAssertNil(bar.handle(.tick(at: 200)), "a hidden bar ignores later ticks")
    }

    func testThePointerOverTheBarKeepsIt() {
        var bar = shownBar()
        XCTAssertNil(bar.handle(.pointerEntered))
        XCTAssertNil(bar.deadline)
        XCTAssertNil(bar.handle(.tick(at: 500)), "no timeout while the pointer is over it")
        XCTAssertEqual(bar.handle(.pointerExited(at: 500)), .wake(at: 504), "leaving starts the timeout again")
        XCTAssertEqual(bar.handle(.tick(at: 503.9)), .wake(at: 504))
        XCTAssertEqual(bar.handle(.tick(at: 504.5)), .hide(.timeout))
    }

    func testEscTypingClicksScrollingAndAppSwitchesHideAtOnce() {
        let cases: [(TextActionBarLifecycle.Event, TextActionDismissReason)] = [
            (.keyDown(escape: true), .escape),
            (.keyDown(escape: false), .typing),
            (.mouseDown(insideBar: false), .clickElsewhere),
            (.scrolled, .scroll),
            (.appSwitched, .appSwitch),
            (.actionFinished(keepsBar: false), .action),
            (.newSelection, .newSelection),
            (.paused, .paused),
            (.secureInput, .secureInput)
        ]
        for (event, reason) in cases {
            var bar = shownBar()
            XCTAssertEqual(bar.handle(event), .hide(reason), "\(event)")
            XCTAssertEqual(bar.phase, .hidden)
            XCTAssertNil(bar.deadline)
        }
    }

    func testClicksOnTheBarPagingAndSubmenusKeepIt() {
        var bar = shownBar()
        XCTAssertNil(bar.handle(.mouseDown(insideBar: true)))
        XCTAssertNil(bar.handle(.actionFinished(keepsBar: true)))
        XCTAssertEqual(bar.phase, .shown)
    }

    func testAHiddenBarIgnoresEverythingButShowing() {
        var bar = TextActionBarLifecycle(hideDelay: 4)
        for event: TextActionBarLifecycle.Event in [.keyDown(escape: true), .scrolled, .appSwitched, .pointerEntered,
                                                    .pointerExited(at: 1), .tick(at: 1), .mouseDown(insideBar: false)] {
            XCTAssertNil(bar.handle(event), "\(event)")
        }
        XCTAssertEqual(bar.handle(.shown(at: 10)), .wake(at: 14))
    }

    func testShowingAgainRestartsTheTimeout() {
        var bar = shownBar(at: 100)
        _ = bar.handle(.pointerEntered)
        XCTAssertEqual(bar.handle(.shown(at: 300)), .wake(at: 304))
        XCTAssertFalse(bar.pointerInside, "a new bar starts with the pointer away")
    }

    func testTheHideDelayComesFromTheSettings() {
        var bar = shownBar(at: 0, hideDelay: 10)
        XCTAssertEqual(bar.handle(.tick(at: 9)), .wake(at: 10))
        XCTAssertEqual(bar.handle(.tick(at: 10)), .hide(.timeout))
    }
}
