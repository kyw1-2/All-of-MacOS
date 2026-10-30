import XCTest
@testable import AllOfMacOS

/// N333-06 (3.3.3 re-audit): once a title-bar snap's window had moved
/// (Native Tiling's 0.35 s read-back, `applySnap`'s completion), the commit
/// ran the haptic, the preview settle, the activation (`bringForward`) and
/// the optional pointer move without asking again whether AOM or the
/// window's app had been paused, or the snap had stopped, meanwhile; and
/// `bringForward` itself asked about no pause. `SwishCommitLanding` and its
/// gates run here with closures that record what they were asked: no
/// windows, pointer, haptics or apps are touched.
@MainActor
final class N333SnapCompletionTests: XCTestCase {
    /// What a landing asks about, as `TitleBarWindowSnap.landingAllowed` reads it.
    private struct World {
        /// The snap's generation now (`landingGeneration`).
        var generation = 7
        var windowAnswers = true
        /// The gate of the commit's input: AOM on and not paused.
        var allowed = true
        var appPaused = false
        var screenLocked = false
        var appRunning = true

        func followUps(startedIn started: Int) -> Bool {
            SwishCommitLanding.followUpsAllowed(sameGeneration: started == generation, windowAnswers: windowAnswers,
                                                allowed: allowed, appPaused: appPaused, screenLocked: screenLocked,
                                                appRunning: appRunning)
        }
    }

    /// Everything a landing may do, in order (Move cursor on), and what is
    /// left when the follow-ups are not allowed.
    private let everything = ["record", "haptic", "settle", "activate", "warp", "reset", "resume"]
    private let bookkeeping = ["record", "hide", "reset"]

    @MainActor
    private final class Recorder {
        var ran: [String] = []
    }

    /// Lands a commit with recording steps and returns what ran, in order.
    private func land(followUps: Bool, options: SwishCommitLanding.Options = .init(movePointer: true)) -> [String] {
        let steps = Recorder()
        let landing = SwishCommitLanding(
            record: { steps.ran.append("record") },
            hidePreview: { steps.ran.append("hide") },
            settlePreview: { steps.ran.append("settle") },
            haptic: { steps.ran.append("haptic") },
            activate: { steps.ran.append("activate") },
            warpPointer: { steps.ran.append("warp") },
            reset: { steps.ran.append("reset") },
            resumeQueued: { steps.ran.append("resume") })
        landing.land(followUps: followUps, options: options)
        return steps.ran
    }

    // MARK: The normal path

    func testANormalLandingRunsEveryFollowUpInOrder() {
        let world = World()
        XCTAssertTrue(world.followUps(startedIn: 7))
        XCTAssertEqual(land(followUps: world.followUps(startedIn: 7)), everything)
    }

    func testTheSettingsStillChooseTheFollowUps() {
        XCTAssertEqual(land(followUps: true, options: .init()),
                       ["record", "haptic", "settle", "activate", "reset", "resume"],
                       "Move cursor off, or a hotkey's commit: the pointer stays")
        XCTAssertEqual(land(followUps: true, options: .init(haptics: false, activate: false, movePointer: false)),
                       ["record", "settle", "reset", "resume"])
    }

    // MARK: Paused or changed before the landing

    func testAGlobalPauseBeforeTheLandingKeepsOnlyTheBookkeeping() {
        var world = World()
        let started = world.generation
        world.allowed = false            // AOM paused (or its master switch off) while the window moved
        XCTAssertFalse(world.followUps(startedIn: started))
        XCTAssertEqual(land(followUps: world.followUps(startedIn: started)), bookkeeping,
                       "the history is kept and the preview goes; no haptic, activation, pointer move or queued motion")
    }

    func testTheTargetAppPausedBeforeTheLandingKeepsOnlyTheBookkeeping() {
        var world = World()
        let started = world.generation
        world.appPaused = true           // AOM paused for the window's app, with another app in front
        XCTAssertFalse(world.followUps(startedIn: started))
        XCTAssertEqual(land(followUps: world.followUps(startedIn: started)), bookkeeping)
    }

    func testAChangedTargetBeforeTheLandingKeepsOnlyTheBookkeeping() {
        // A chain handed the gestures to another window (the Dock, a detached
        // tab), the snap stopped or the Mac slept: the generation moved on.
        var world = World()
        let started = world.generation
        world.generation &+= 1
        XCTAssertFalse(world.followUps(startedIn: started))
        XCTAssertEqual(land(followUps: world.followUps(startedIn: started)), bookkeeping)
        XCTAssertTrue(world.followUps(startedIn: world.generation), "a commit started after the change lands as usual")

        // The tiled window no longer answers (closed during macOS's animation).
        var gone = World()
        gone.windowAnswers = false
        XCTAssertFalse(gone.followUps(startedIn: gone.generation))
        XCTAssertEqual(land(followUps: gone.followUps(startedIn: gone.generation)), bookkeeping)
    }

    func testTheScreenLockOrAQuitAppBeforeTheLandingKeepsOnlyTheBookkeeping() {
        var locked = World()
        locked.screenLocked = true
        XCTAssertFalse(locked.followUps(startedIn: locked.generation))
        var quit = World()
        quit.appRunning = false
        XCTAssertFalse(quit.followUps(startedIn: quit.generation))
        XCTAssertEqual(land(followUps: false), bookkeeping)
    }

    /// `finishCommit` hands the same answer to the queue of motions made
    /// while the commit landed: a refused landing applies none of them, now
    /// or later.
    func testMotionsQueuedBehindARefusedLandingAreDropped() {
        var queue = SwishChainQueue()
        queue.began(.init(.left))
        queue.liftedFingers()
        queue.began(.init(.down))
        XCTAssertNil(queue.landed(succeeded: false))
        XCTAssertTrue(queue.queue.isEmpty)

        queue.began(.init(.left))
        queue.liftedFingers()
        XCTAssertEqual(queue.landed(succeeded: true), .init(stroke: .init(.left), lifted: true), "allowed: it carries on")
    }

    // MARK: bringForward's own guard

    func testBringForwardAsksAboutThePauseWhoeverCallsIt() {
        XCTAssertTrue(SwishCommitLanding.mayBringForward(active: true, gateAllows: true, appPaused: false))
        XCTAssertFalse(SwishCommitLanding.mayBringForward(active: true, gateAllows: false, appPaused: false),
                       "AOM paused or switched off")
        XCTAssertFalse(SwishCommitLanding.mayBringForward(active: true, gateAllows: true, appPaused: true),
                       "the window's app paused")
        XCTAssertFalse(SwishCommitLanding.mayBringForward(active: false, gateAllows: true, appPaused: false),
                       "the snap switched off")
    }
}
