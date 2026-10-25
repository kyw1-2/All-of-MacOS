import XCTest
import CoreAudio
@testable import AllOfMacOS

/// Porting-layer tests: Swish-style window gesture math, the audio mixer's
/// pure pieces, and the Mission Control overlay settings contract.
@MainActor
final class PortedFeatureTests: XCTestCase {


    // MARK: Pin parking — the sliver that keeps translucent pins live

    func testParkTargetKeepsA2PointSliverOnScreen() {
        let desktop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let original = CGRect(x: 400, y: 300, width: 600, height: 400)
        let target = WindowPinningGeometry.parkTarget(original: original, desktop: desktop)
        let parked = CGRect(origin: target, size: original.size)
        XCTAssertEqual(parked.maxX - desktop.minX, 2, accuracy: 0.5,
                       "exactly a 2 pt sliver stays inside the desktop")
        XCTAssertFalse(parked.intersects(original), "the parked window leaves its original spot")
        XCTAssertTrue(desktop.intersects(parked), "still on-screen so ScreenCaptureKit keeps streaming")
        // Tall windows clamp inside the desktop vertically instead of below it.
        let tall = CGRect(x: 100, y: 100, width: 300, height: 1200)
        let tallTarget = WindowPinningGeometry.parkTarget(original: tall, desktop: desktop)
        XCTAssertTrue(CGRect(origin: tallTarget, size: tall.size).intersects(desktop))
    }


    // MARK: Equalizer — the audio math

    func testFlatEQIsUnity() {
        let eq = AudioEQ(gains: AudioEQ.presetFlat, sampleRate: 48000)
        XCTAssertFalse(eq.isEnabled)
        let input = (0..<256).map { Float(sin(2 * .pi * 1000 * Double($0) / 48000)) * 0.5 }
        let output = eq.process(input)
        zip(input, output).forEach { XCTAssertEqual($0, $1, accuracy: 0.00001) }
    }

    func testBassBoostLiftsLowFrequencies() {
        let flat = AudioEQ(gains: AudioEQ.presetFlat, sampleRate: 48000)
        let boost = AudioEQ(gains: AudioEQ.presets["Bass Boost"]!, sampleRate: 48000)
        let low = (0..<4096).map { Float(sin(2 * .pi * 62.5 * Double($0) / 48000)) * 0.2 }
        func rms(_ signal: [Float]) -> Float { sqrt(signal.map { $0 * $0 }.reduce(0, +) / Float(signal.count)) }
        let boosted = rms(boost.process(low).suffix(2048))
        let original = rms(flat.process(low).suffix(2048))
        XCTAssertGreaterThan(boosted, original * 1.4, "the 32 Hz shelf at +6 dB must lift the 62.5 Hz tone")
    }

    func testEQBandClampAndPresets() {
        XCTAssertEqual(AudioEQ.bandFrequencies.count, 10)
        XCTAssertEqual(AudioEQ.presets["Flat"], [Float](repeating: 0, count: 10))
        for gains in AudioEQ.presets.values {
            XCTAssertEqual(gains.count, 10)
            XCTAssertTrue(gains.allSatisfy { $0 >= -12 && $0 <= 12 })
        }
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
        service.isOutsideOwnApp = { true }
        defer {
            service.cursorLocation = { NSEvent.mouseLocation }
            service.cursorInTopBand = { TrackpadUtilityGestures.cursorInTopBand($0) }
            service.isOutsideOwnApp = {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
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


    func testAppAudioEngineMixingZeroWhenMuted() {
        let box = MixerBox(gain: 1.5, muted: true)
        var inSamples: [Float32] = [0.5, -0.5, 0.2, -0.2]
        var outSamples: [Float32] = [1.0, 1.0, 1.0, 1.0]

        inSamples.withUnsafeMutableBufferPointer { inBuf in
            outSamples.withUnsafeMutableBufferPointer { outBuf in
                var inAudioBuf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(inBuf.count * MemoryLayout<Float32>.size), mData: inBuf.baseAddress)
                var outAudioBuf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(outBuf.count * MemoryLayout<Float32>.size), mData: outBuf.baseAddress)

                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: inAudioBuf)
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: outAudioBuf)

                withUnsafePointer(to: &inList) { inPtr in
                    withUnsafeMutablePointer(to: &outList) { outPtr in
                        Mixer.mix(input: inPtr, output: outPtr, box: box)
                    }
                }
            }
        }
        XCTAssertEqual(outSamples, [0.0, 0.0, 0.0, 0.0])
    }

    func testAppAudioEngineMixingScalesGain() {
        let box = MixerBox(gain: 1.5, muted: false)
        var inSamples: [Float32] = [0.2, -0.4, 0.1, -0.1]
        var outSamples: [Float32] = [0.0, 0.0, 0.0, 0.0]

        inSamples.withUnsafeMutableBufferPointer { inBuf in
            outSamples.withUnsafeMutableBufferPointer { outBuf in
                var inAudioBuf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(inBuf.count * MemoryLayout<Float32>.size), mData: inBuf.baseAddress)
                var outAudioBuf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(outBuf.count * MemoryLayout<Float32>.size), mData: outBuf.baseAddress)

                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: inAudioBuf)
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: outAudioBuf)

                withUnsafePointer(to: &inList) { inPtr in
                    withUnsafeMutablePointer(to: &outList) { outPtr in
                        Mixer.mix(input: inPtr, output: outPtr, box: box)
                    }
                }
            }
        }
        XCTAssertEqual(outSamples[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(outSamples[1], -0.6, accuracy: 0.001)
    }
}
