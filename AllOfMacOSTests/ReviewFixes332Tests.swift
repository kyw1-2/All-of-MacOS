import XCTest
import CoreAudio
@testable import AllOfMacOS

/// The 3.3.2 release review (semantic review 2026-10-29): the fixes that can
/// be checked without a trackpad, an Accessibility client or audio hardware.
final class ReviewFixes332Tests: XCTestCase {
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        // Pad coordinates with y toward the bottom, flipped like TitleBarSnapTests.
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: 1, pressure: 0)]
    }

    // MARK: 1–2. Accessibility timeouts stay per element, and bounded

    /// AXUIElement.h: the timeout of the system-wide element is the timeout
    /// of every Accessibility call in the process. The Dock hit-test set it
    /// to 0.25 s; nothing may set it again.
    func testNoCodeSetsTheProcessWideAccessibilityTimeout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let bound = try NSRegularExpression(pattern: #"let\s+(\w+)\s*=\s*AXUIElementCreateSystemWide\(\)"#)
        let timeout = try NSRegularExpression(pattern: #"AXUIElementSetMessagingTimeout\(\s*([^,]+),"#)
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            let names = Set(bound.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
            for match in timeout.matches(in: text, range: range) {
                guard let argument = Range(match.range(at: 1), in: text).map({ text[$0].trimmingCharacters(in: .whitespaces) }) else { continue }
                checked += 1
                XCTAssertFalse(argument.contains("AXUIElementCreateSystemWide") || names.contains(argument),
                               "\(file.lastPathComponent) sets the process-wide timeout through \(argument)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "the scan found the per-element timeouts")
    }

    /// The title-bar snap and the Dock lookup hit-test the owner app's
    /// element, never the system-wide one (whose requests carry no limit of
    /// their own and run on main while trackpad frames queue behind them).
    func testTheTitleBarAndDockHitTestsGoToTheOwnerApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS/Services")
        for name in ["TitleBarWindowSnap.swift", "SwishDockMenuBarGestures.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("AXUIElementCreateSystemWide"), name)
        }
        let manager = try String(contentsOf: root.appendingPathComponent("WindowManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(manager.range(of: "func titleBarTarget(atMousePoint point: CGPoint, pid owner: pid_t"))
        let end = try XCTUnwrap(manager.range(of: "func setFrame(", range: start.upperBound..<manager.endIndex))
        let body = manager[start.upperBound..<end.lowerBound]
        XCTAssertFalse(body.contains("AXUIElementCreateSystemWide"))
        XCTAssertTrue(body.contains("AXUIElementCreateApplication(owner)"))
        XCTAssertTrue(body.contains("AXDeadline"))
    }

    func testTheAccessibilityBudgetBoundsEveryRequestAndTheWholeWalk() throws {
        let limit = AXDeadline(perRequest: 0.25, budget: 0.3, now: 100)
        XCTAssertEqual(limit.timeout(now: 100), 0.25, "a fresh walk: the per-request limit")
        XCTAssertEqual(try XCTUnwrap(limit.timeout(now: 100.2)), 0.1, accuracy: 1e-6, "late in the walk: what is left")
        XCTAssertNil(limit.timeout(now: 100.296), "under 5 ms left: spent")
        XCTAssertNil(limit.timeout(now: 101))
        XCTAssertNil(AXDeadline(perRequest: 0.25, budget: -1, now: 0).timeout(now: 0), "a negative budget is spent")
        XCTAssertEqual(AXDeadline(perRequest: 0.5, budget: 1, now: 0).timeout(now: 0), 0.5)
    }

    // MARK: 3. Engaged flicks commit

    /// At every sensitivity a quick flick past the engage distance commits;
    /// only a lift that barely moved after engaging (under 0.6 × engage) is
    /// a tap.
    func testAQuickFlickCommitsAtEverySensitivity() {
        for sensitivity in [0.8, 1.0, 1.25, 1.6, 2.0] {
            let recognizer = TitleBarSnapRecognizer()
            recognizer.settleTime = 0
            recognizer.engage = TitleBarWindowSnap.distances(sensitivity: sensitivity).engage
            var commits = 0, taps = 0
            recognizer.onCommit = { commits += 1 }
            recognizer.onTap = { _ in taps += 1 }
            let travel = recognizer.engage * 1.1
            recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
            recognizer.feed(contacts: pair(0.50 - travel, 0.50), timestamp: 0.04)
            recognizer.feed(contacts: [], timestamp: 0.07)
            XCTAssertEqual(commits, 1, "sensitivity \(sensitivity): a flick of \(travel) in 70 ms snaps")
            XCTAssertEqual(taps, 0)
        }
    }

    // MARK: 6. Swipes chained during a commit

    func testASwipeDuringACommitIsKeptAndAppliedWhenItLands() {
        var queue = SwishChainQueue()
        XCTAssertNil(queue.landed(succeeded: true), "nothing waits")
        queue.began(.init(.down))
        queue.updated(.init(.down, cross: .left))
        XCTAssertEqual(queue.pending, .init(stroke: .init(.down, cross: .left), lifted: false), "the latest stroke")
        queue.liftedFingers()
        queue.updated(.init(.right))
        XCTAssertEqual(queue.landed(succeeded: true), .init(stroke: .init(.down, cross: .left), lifted: true),
                       "lifted before the commit landed: applied at once, with its last stroke")
        XCTAssertNil(queue.pending)
        // Still on the pad when it lands: applied, and the fingers carry on.
        queue.began(.init(.up))
        XCTAssertEqual(queue.landed(succeeded: true), .init(stroke: .init(.up), lifted: false))
        // Cancelled while the fingers are down (held still, a third finger).
        queue.began(.init(.left))
        queue.cancelTouch()
        XCTAssertNil(queue.landed(succeeded: true))
        // A later touch's cancel does not drop a swipe that already lifted.
        queue.began(.init(.left))
        queue.liftedFingers()
        queue.cancelTouch()
        XCTAssertEqual(queue.landed(succeeded: true)?.stroke, .init(.left))
        // A failed commit drops it: the window did not move.
        queue.began(.init(.left))
        XCTAssertNil(queue.landed(succeeded: false))
        XCTAssertNil(queue.pending)
        // What it then does: the step from the place the commit landed in.
        let leftHalf = SwishSnap.Place(.leftHalf)
        XCTAssertEqual(SwishSnap.step(from: leftHalf, stroke: .init(.down), grid: .twoByTwo), .cell(.bottomLeft))
    }

    // MARK: Swish gaps: a maximized window reaches the bottom

    func testALongerSwipeDownFromMaximizeGoesToTheBottomHalf() {
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down), thirds: false), .restore, "short: Swish's unmaximize")
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down, tier: 2), thirds: false), .cell(.bottomHalf))
        XCTAssertEqual(SwishSnap.step(from: .almostMaximize, stroke: .init(.down), grid: .twoByTwo, almost: true), .restore)
        XCTAssertEqual(SwishSnap.step(from: .almostMaximize, stroke: .init(.down, tier: 2), grid: .twoByTwo, almost: true),
                       .cell(.bottomHalf))
        let options = SwishSnap.GestureOptions()
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down, tier: 2), modifiers: [], options: options),
                       .cell(.bottomHalf), "Swish's mapping: a maximized window is no free one")
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down, cross: .left), modifiers: [], options: options),
                       .cell(.bottomLeft), "a diagonal or L picks the quarter outright")
        XCTAssertEqual(SwishSnap.move(from: .topHalf, stroke: .init(.down), modifiers: [], options: options), .cell(.bottomHalf))
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: .init(.down), modifiers: [], options: options), .cell(.bottomLeft))
    }

    func testTheDefaultGridHasNoThirds() {
        let defaults = UserDefaults(suiteName: "AOMReview332.\(UUID().uuidString)")!
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .twoByTwo)
        XCTAssertFalse(TitleBarWindowSnap.gestureOptions(defaults).thirds)
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: .init(.left, tier: 2), modifiers: [],
                                      options: TitleBarWindowSnap.gestureOptions(defaults)), .cell(.leftHalf))
        defaults.set(SwishSnap.Grid.threeByTwo.rawValue, forKey: TitleBarWindowSnap.gridKey)
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: .init(.left, tier: 2), modifiers: [],
                                      options: TitleBarWindowSnap.gestureOptions(defaults)), .cell(.leftThird))
    }

    // MARK: 13. Hold still: a resting hand may drift 0.018

    func testAHandDriftingUnder18ThousandthsStillCancelsAfterTwoSeconds() {
        XCTAssertEqual(TitleBarSnapRecognizer().stillRadius, 0.018)
        XCTAssertEqual(UtilityGestureRecognizer.Tuning().stillRadius, 0.018)
        let recognizer = TitleBarSnapRecognizer()
        recognizer.settleTime = 0
        var holdCancels = 0
        recognizer.onHoldCancel = { holdCancels += 1 }
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        // 0.015 of drift over the first 1.5 s, then resting: 0.012 restarted the clock at 1.2 s.
        for frame in 1...138 {
            let x = 0.50 + 0.015 * Float(min(1, Double(frame) / 90))
            recognizer.feed(contacts: pair(x, 0.50), timestamp: 0.02 + Double(frame) / 60)
        }
        XCTAssertEqual(holdCancels, 1, "the title-bar snap's 2 s cancel")
        var utility = UtilityGestureRecognizer()
        var events: [UtilityGestureRecognizer.Event] = []
        for frame in 0...138 {
            let x = 0.50 + 0.015 * Float(min(1, Double(frame) / 90))
            let points = [TouchPoint(id: 0, x: x - 0.05, y: 0.5, size: 0.1), TouchPoint(id: 1, x: x + 0.05, y: 0.5, size: 0.1)]
            if let event = utility.feed(points, at: Double(frame) / 60) { events.append(event) }
        }
        XCTAssertEqual(events, [.holdBegan, .holdCancelled], "the menu-bar and Dock gestures' cancel")
    }

    // MARK: 14. The pickers show every value the Settings Hub writes

    @MainActor
    func testEveryHubHoldCancelValueHasAPickerEntry() {
        typealias View = ModernWindowSnappingView
        for value in stride(from: 0.0, through: 3.0, by: 0.5) {
            XCTAssertNotNil(View.preset(value, in: View.holdCancelPresets), "\(value) s")
        }
        XCTAssertEqual(View.preset(1.2500000000000002, in: View.sensitivityPresets)?.title, "Quick", "a slider's rounding")
        XCTAssertNil(View.preset(1.4, in: View.sensitivityPresets), "between presets: shown as Custom")
        XCTAssertEqual(View.sensitivityPresets.map(\.value), [0.8, 1.0, 1.25, 1.6])
    }

    // MARK: 15. The bus never allocates under the mix thread's lock

    /// Sources added while another thread renders (waiting for the lock, as
    /// the AirPlay mix thread does) are all kept: `add` builds the longer
    /// list outside the lock and swaps it in.
    func testSourcesAddedWhileTheMixThreadRendersAreAllKept() {
        let bus = AppAudioRenderBus()
        let stop = AudioAtomicCounter()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            var block = [Float](repeating: 0, count: 960)
            while stop.load() == 0 {
                block.withUnsafeMutableBufferPointer { pointer in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                    withUnsafeMutablePointer(to: &list) { bus.render(frames: 480, output: $0, allowWaiting: true) }
                }
                // A mix clock renders a block and sleeps (10 ms in the app);
                // an unfair lock taken in a tight loop would starve `add`.
                usleep(100)
            }
            done.signal()
        }
        thread.start()
        for _ in 0..<40 {
            bus.add(id: UUID()) { frames, output in
                let data = UnsafeMutableAudioBufferListPointer(output)[0].mData!.assumingMemoryBound(to: Float.self)
                for index in 0..<(frames * 2) { data[index] = 0.001 }
            }
            usleep(300)
        }
        stop.store(1)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        var block = [Float](repeating: 0, count: 960)
        for _ in 0..<4 {
            block.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                withUnsafeMutablePointer(to: &list) { bus.render(frames: 480, output: $0) }
            }
        }
        XCTAssertEqual(block[958], 0.04, accuracy: 1e-4, "all 40 sources are heard")
        XCTAssertFalse(bus.isEmpty)
    }

    // MARK: 16. Overdrive keeps one limiter across a move to or from AirPlay

    /// An app overdriven to 300 % moves to AirPlay and back: its limiter's
    /// release switches in place. Until the review MixerBox switched to a
    /// second Overdrive whose delay line and engagement were stale: the
    /// output jumped from the limited signal to the dry one.
    func testAnOverdrivenAppMovingToAndFromAirPlayDoesNotJump() {
        let mixer = MixerBox(gain: 1, muted: false)
        mixer.overdrive = 3
        var input = [Float](repeating: 0, count: 960), output = [Float](repeating: 0, count: 960)
        var rendered: [Float] = []
        var n = 0
        for block in 0..<300 {
            for i in 0..<480 {
                let v = Float(0.4 * sin(2 * .pi * 220 * Double(n + i) / 48000))
                input[i * 2] = v; input[i * 2 + 1] = v
            }
            n += 480
            if block == 120 { mixer.usesNetworkDynamics = true }
            if block == 200 { mixer.usesNetworkDynamics = false }
            input.withUnsafeMutableBufferPointer { inPointer in
                output.withUnsafeMutableBufferPointer { outPointer in
                    var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: 3840, mData: inPointer.baseAddress))
                    var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: 3840, mData: outPointer.baseAddress))
                    withUnsafePointer(to: &inList) { i in
                        withUnsafeMutablePointer(to: &outList) { o in Mixer.mix(input: i, output: o, box: mixer) }
                    }
                }
            }
            rendered += stride(from: 0, to: 960, by: 2).map { output[$0] }
        }
        let steady = Array(rendered[48000...])
        let step = zip(steady.dropFirst(), steady).map { abs($0 - $1) }.max() ?? 1
        let peak = steady.map(abs).max() ?? 0
        print("Overdrive across the route switches: largest step \(step), peak \(peak)")
        XCTAssertGreaterThan(peak, 0.8, "overdriven and limited throughout")
        XCTAssertLessThan(step, 0.05, "no jump at either switch (a limited 220 Hz sine moves under 0.035)")
    }

    // MARK: 17. An output is never stopped inside a fade

    func testAFadingSourceKeepsItsOutput() {
        let bus = AppAudioRenderBus()
        let id = UUID()
        bus.add(id: id) { frames, output in
            let data = UnsafeMutableAudioBufferListPointer(output)[0].mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<(frames * 2) { data[index] = 0.3 }
        }
        XCTAssertFalse(bus.isEmpty)
        bus.remove(id: id)
        XCTAssertFalse(bus.isEmpty, "still fading: releasing the output now would cut the fade")
        XCTAssertTrue(bus.hasNoLiveSources)
        var block = [Float](repeating: 0, count: 960)
        block.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafeMutablePointer(to: &list) { bus.render(frames: 480, output: $0) }
        }
        XCTAssertTrue(bus.isEmpty, "faded out")
    }

    // MARK: Crackle audit follow-up: format notices, a missing HomePod, a full queue

    func testAFormatNoticeThatChangesNothingRestartsNothing() {
        typealias R = AirPlayOutputRenderer
        XCTAssertEqual(R.formatResponse(nominalRate: 44100, deviceRate: 44100, channels: 2, configuredRate: 44100,
                                        confirmed: false), .refreshBaseline)
        XCTAssertEqual(R.formatResponse(nominalRate: 44100, deviceRate: 48000, channels: 2, configuredRate: 44100,
                                        confirmed: false), .refreshBaseline,
                       "the nominal rate is what `reconfigure` would apply: the same format again")
        XCTAssertEqual(R.formatResponse(nominalRate: nil, deviceRate: 44100, channels: 8, configuredRate: 44100,
                                        confirmed: false), .refreshBaseline, "a wider channel layout")
        XCTAssertEqual(R.formatResponse(nominalRate: 48000, deviceRate: 48000, channels: 2, configuredRate: 44100,
                                        confirmed: false), .confirmLater, "a new rate is read again first")
        XCTAssertEqual(R.formatResponse(nominalRate: 48000, deviceRate: 48000, channels: 2, configuredRate: 44100,
                                        confirmed: true), .reconfigure, "and applied once it holds")
        XCTAssertEqual(R.formatResponse(nominalRate: 44100, deviceRate: 44100, channels: 1, configuredRate: 44100,
                                        confirmed: true), .reconfigure, "mono: the stream must change")
        XCTAssertEqual(R.formatConfirmDelay, 0.25)
    }

    func testOneDeviceListWithoutTheHomePodDoesNotStopItsOutput() {
        typealias S = SharedOutputRenderer
        XCTAssertFalse(S.releasesMissingAirPlay(missingFor: 0, deviceAlive: true), "one list read without it")
        XCTAssertFalse(S.releasesMissingAirPlay(missingFor: 1.4, deviceAlive: true))
        XCTAssertTrue(S.releasesMissingAirPlay(missingFor: S.airPlayMissingGrace, deviceAlive: true), "gone for good")
        XCTAssertTrue(S.releasesMissingAirPlay(missingFor: 0, deviceAlive: false), "the device says it is dead")
        XCTAssertTrue(S.releasesMissingAirPlay(missingFor: 0, deviceAlive: nil), "its object is gone")
    }

    /// A consumer stall longer than the queue: what did not fit is lost, and
    /// the next writes used to follow the old audio as a hard splice. The
    /// overflow now clears the queue: the old stream fades out, the fresh one
    /// fades in.
    func testAFullQueueRestartsOnFreshAudioInsteadOfSplicing() {
        let queue = StereoPCMQueue(capacity: 8192)
        var index = 0
        func produce(_ count: Int) {
            let base = index
            // 5 Hz: almost no step of its own, a large one across any splice.
            queue.write(frames: count) { let v = Float(0.5 * sin(2 * .pi * 5 * Double(base + $0) / 48000)); return (v, v) }
            index += count
        }
        var output: [Float] = []
        var block = [Float](repeating: 0, count: 960)
        for blockIndex in 0..<400 {
            produce(480)
            // The consumer stalls for 30 blocks: 14 400 frames for an 8192-frame queue.
            guard !(100..<130).contains(blockIndex) else { continue }
            block.withUnsafeMutableBufferPointer { pointer in
                _ = queue.render(into: pointer.baseAddress!, frames: 480, ratio: 1, targetFrames: 1920,
                                 driftLimit: 0, fadeFrames: 240)
            }
            output += stride(from: 0, to: 960, by: 2).map { block[$0] }
        }
        let stats = queue.statistics
        XCTAssertGreaterThan(stats["droppedFrames"] ?? 0, 0, "the stall overflowed the queue")
        XCTAssertGreaterThanOrEqual(stats["clears"] ?? 0, 1, "and the overflow cleared it")
        let step = zip(output.dropFirst(), output).map { abs($0 - $1) }.max() ?? 1
        print("Full queue: largest step \(step); stats \(stats)")
        XCTAssertLessThan(step, 0.02, "faded out and in: no splice")
        XCTAssertGreaterThan(output.suffix(9600).map(abs).max() ?? 0, 0.3, "the fresh audio plays")
    }

    // MARK: Swish gaps: BTT-style triggers and the snap share no touch

    func testTheSnapOwnsTheTwoFingerGesturesOfATitleBarTouch() {
        typealias S = TitleBarWindowSnap
        XCTAssertFalse(S.claims(.twoFingerPinchIn, ownsTouch: false, pinches: true, doubleTap: true, hold: true),
                       "a touch elsewhere is the trigger engine's")
        XCTAssertTrue(S.claims(.twoFingerPinchIn, ownsTouch: true, pinches: true, doubleTap: true, hold: true))
        XCTAssertFalse(S.claims(.twoFingerPinchOut, ownsTouch: true, pinches: false, doubleTap: true, hold: true),
                       "pinches off: a pinch on a title bar runs the user's trigger")
        XCTAssertTrue(S.claims(.twoFingerDoubleTap, ownsTouch: true, pinches: true, doubleTap: true, hold: false))
        XCTAssertFalse(S.claims(.twoFingerTap, ownsTouch: true, pinches: true, doubleTap: false, hold: true))
        XCTAssertTrue(S.claims(.twoFingerLongTouch, ownsTouch: true, pinches: false, doubleTap: false, hold: true))
        XCTAssertTrue(S.claims(.twoFingerSwipeDown, ownsTouch: true, pinches: false, doubleTap: false, hold: false))
        XCTAssertFalse(S.claims(.threeFingerSwipeUp, ownsTouch: true, pinches: true, doubleTap: true, hold: true),
                       "three fingers are never the snap's")
    }

    @MainActor
    func testATriggerOnAPinchDoesNotFireForATitleBarTouch() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "Pinch", input: .trackpadGesture(.twoFingerPinchIn))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([trigger])
        var count = 0
        ActionExecutor.onActionExecuted = { _ in count += 1 }
        UserDefaults.standard.removeObject(forKey: TitleBarWindowSnap.pinchKey)
        defer {
            TitleBarWindowSnap.ownsTouch = false
            monitor.unregisterAll()
            ActionExecutor.onActionExecuted = nil
        }
        TitleBarWindowSnap.ownsTouch = true
        monitor.fireGestureForTest(.twoFingerPinchIn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(count, 0, "the snap's pinch closes the window; the trigger stays quiet")
        TitleBarWindowSnap.ownsTouch = false
        monitor.fireGestureForTest(.twoFingerPinchIn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(count, 1, "anywhere else the trigger fires as before")
    }
}
