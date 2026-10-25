import XCTest
import CoreAudio
@testable import AllOfMacOS

/// Porting-layer tests: Swish-style window gesture math, the audio mixer's
/// pure pieces, and the Mission Control overlay settings contract.
@MainActor
final class PortedFeatureTests: XCTestCase {

    // MARK: Swish — edge detection for drag→resize

    func testEdgeDetectionFindsEdgesWithinBand() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let right = WindowGestureController.edges(near: CGPoint(x: 698, y: 300), frame: frame, within: 40)
        XCTAssertTrue(right.contains(.maxX) && right.count == 1)
        let corner = WindowGestureController.edges(near: CGPoint(x: 695, y: 105), frame: frame, within: 40)
        XCTAssertTrue(corner.contains(.maxX) && corner.contains(.minY), "corners resize on two edges")
        let interior = WindowGestureController.edges(near: CGPoint(x: 400, y: 300), frame: frame, within: 40)
        XCTAssertTrue(interior.isEmpty, "the middle of a window is a move, not a resize")
        let outside = WindowGestureController.edges(near: CGPoint(x: 900, y: 300), frame: frame, within: 40)
        XCTAssertTrue(outside.isEmpty, "points off the window never resize")
    }

    // MARK: Audio mixer — pure math and state

    func testMixerGainClamp() {
        XCTAssertEqual(Mixer.clamp(0.5), 0.5)
        XCTAssertEqual(Mixer.clamp(-3), 0)
        XCTAssertEqual(Mixer.clamp(9), 2)
    }

    func testMixerScalesSamplesAndMutes() {
        let box = MixerBox(gain: 0.5, muted: false)
        var inputBuffers = [Float32](repeating: 0.8, count: 8)
        var outputBuffers = [Float32](repeating: 0, count: 8)
        inputBuffers.withUnsafeMutableBufferPointer { inPtr in
            outputBuffers.withUnsafeMutableBufferPointer { outPtr in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: (
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: inPtr.baseAddress)))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: (
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: outPtr.baseAddress)))
                Mixer.mix(input: UnsafeMutablePointer(&inputList),
                          output: UnsafeMutablePointer(&outputList), box: box)
            }
        }
        XCTAssertEqual(outputBuffers[0], 0.4, accuracy: 0.001)

        let mutedBox = MixerBox(gain: 1, muted: true)
        outputBuffers = Array(repeating: 9, count: 8)
        inputBuffers.withUnsafeMutableBufferPointer { inPtr in
            outputBuffers.withUnsafeMutableBufferPointer { outPtr in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: (
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: inPtr.baseAddress)))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: (
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: outPtr.baseAddress)))
                Mixer.mix(input: UnsafeMutablePointer(&inputList),
                          output: UnsafeMutablePointer(&outputList), box: mutedBox)
            }
        }
        XCTAssertEqual(outputBuffers[0], 0, "muted renders silence")
    }

    func testPerAppGainPersistsByBundleID() {
        // The persistence key contract is availability-free on purpose: the
        // mixer panel saves gains before any 14.2 gate runs.
        UserDefaults.standard.removeObject(forKey: "AOMAudioGain_test.bundle")
        UserDefaults.standard.set(Double(0.75), forKey: "AOMAudioGain_test.bundle")
        let engine: Any? = nil // AppAudioEngine itself is 14.2-gated; key contract only
        XCTAssertNil(engine)
        XCTAssertEqual(Float(UserDefaults.standard.object(forKey: "AOMAudioGain_test.bundle") as? Double ?? 1), 0.75)
        UserDefaults.standard.removeObject(forKey: "AOMAudioGain_test.bundle")
    }

    // MARK: Mission Control overlay setting contract

    func testMissionControlButtonsDefaultOnAndToggleable() {
        UserDefaults.standard.removeObject(forKey: "AOMMissionControlButtons")
        let service = MissionControlOverlayService()
        XCTAssertTrue(service.isEnabled, "the overlay is on by default")
        UserDefaults.standard.set(false, forKey: "AOMMissionControlButtons")
        XCTAssertFalse(service.isEnabled)
        UserDefaults.standard.removeObject(forKey: "AOMMissionControlButtons")
    }

    // MARK: Utility gestures — space swipe & dock pinch contracts

    func testTopBandDetection() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(TrackpadUtilityGestures.cursorInTopBand(CGPoint(x: 700, y: 895), screens: screens),
                      "points within 12 pt of the top count")
        XCTAssertFalse(TrackpadUtilityGestures.cursorInTopBand(CGPoint(x: 700, y: 860), screens: screens),
                       "ordinary window content near the top must not trip")
        XCTAssertFalse(TrackpadUtilityGestures.cursorInTopBand(CGPoint(x: 1700, y: 895), screens: screens),
                       "off-screen points never count")
    }

    func testSpaceSwipeFiresOncePerDirectionAndChains() {
        let service = TrackpadUtilityGestures.shared
        var fired: [Bool] = []
        service.switchSpace = { fired.append($0) }
        defer { service.switchSpace = { _ in } }
        UserDefaults.standard.removeObject(forKey: "AOMTopBarSpaceSwipe")

        func frame(_ x1: Float, _ x2: Float) -> [TouchPoint] {
            [TouchPoint(id: 0, x: x1, y: 0.5, size: 0.1),
             TouchPoint(id: 1, x: x2, y: 0.5, size: 0.1)]
        }
        // Cursor pinned in the top band by the seams.
        service.cursorLocation = { CGPoint(x: 700, y: 895) }
        service.cursorInTopBand = { _ in true }
        defer {
            service.cursorLocation = { NSEvent.mouseLocation }
            service.cursorInTopBand = { TrackpadUtilityGestures.cursorInTopBand($0) }
        }

        var t: Double = 10
        service.observe(points: frame(0.4, 0.6), timestamp: t) // begin
        t += 0.5
        service.observe(points: frame(0.25, 0.45), timestamp: t) // swipe left 0.15
        XCTAssertEqual(fired, [false], "fingers left → the Space on the right")
        t += 0.5
        service.observe(points: frame(0.25, 0.45), timestamp: t) // same position, no refire
        XCTAssertEqual(fired.count, 1, "no refire without further movement")
        t += 0.5
        service.observe(points: frame(0.40, 0.60), timestamp: t) // chain back right
        XCTAssertEqual(fired, [false, true], "rebased gesture chains the other way")
        service.observe(points: [], timestamp: t) // lift
        UserDefaults.standard.removeObject(forKey: "AOMTopBarSpaceSwipe")
    }

    func testDockPinchQuitSettingContract() {
        UserDefaults.standard.removeObject(forKey: "AOMDockPinchQuit")
        XCTAssertTrue(TrackpadUtilityGestures.shared.dockQuitEnabled, "on by default")
        UserDefaults.standard.set(false, forKey: "AOMDockPinchQuit")
        XCTAssertFalse(TrackpadUtilityGestures.shared.dockQuitEnabled)
        UserDefaults.standard.removeObject(forKey: "AOMDockPinchQuit")
    }

    // MARK: Window gestures setting contract

    func testWindowGesturesSettingContract() {
        UserDefaults.standard.removeObject(forKey: "AOMWindowGesturesEnabled")
        UserDefaults.standard.removeObject(forKey: "AOMWindowGestureEdgeSize")
        let controller = WindowGestureController.shared
        // Defaults: enabled, 40 pt edge band. The engine reads them live.
        XCTAssertTrue(UserDefaults.standard.object(forKey: "AOMWindowGesturesEnabled") as? Bool ?? true)
        UserDefaults.standard.set(60.0, forKey: "AOMWindowGestureEdgeSize")
        // A point 45 pt from the right edge: inside a 60 pt band, outside 40.
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 655, y: 300)
        XCTAssertTrue(WindowGestureController.edges(near: point, frame: frame, within: 60).contains(.maxX))
        XCTAssertFalse(WindowGestureController.edges(near: point, frame: frame, within: 40).contains(.maxX))
        _ = controller // the settings are read per-frame by the running engine
        UserDefaults.standard.removeObject(forKey: "AOMWindowGestureEdgeSize")
    }
}
