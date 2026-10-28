import XCTest
import CoreAudio
@testable import AllOfMacOS

/// Re-audit S05: per-app stereo balance (SoundSource's Balance effect). The
/// pure balance law, its persistence and backup, and the realtime mixer on
/// interleaved, planar, mono and wider buffers. No audio device, no capture,
/// and only throwaway UserDefaults suites.
final class AppAudioBalanceTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let name = "AOMBalanceTests.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func withInterleaved<T>(_ samples: inout [Float], channels: Int,
                                    _ body: (UnsafeMutablePointer<AudioBufferList>) -> T) -> T {
        samples.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            return withUnsafeMutablePointer(to: &list, body)
        }
    }

    private func mix(_ box: MixerBox, input: inout [Float], inputChannels: Int = 2,
                     output: inout [Float], outputChannels: Int = 2) {
        withInterleaved(&input, channels: inputChannels) { source in
            withInterleaved(&output, channels: outputChannels) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
    }

    // MARK: Balance law

    func testCentreIsUnityAndOnlyTheOppositeSideIsAttenuated() {
        let cases: [(balance: Float, left: Float, right: Float)] = [
            (0, 1, 1), (-1, 1, 0), (1, 0, 1), (-0.3, 1, 0.7), (0.25, 0.75, 1), (-0.5, 1, 0.5)
        ]
        for item in cases {
            let sides = AudioBalance.sideGains(item.balance)
            XCTAssertEqual(sides.left, item.left, accuracy: 1e-6, "left at \(item.balance)")
            XCTAssertEqual(sides.right, item.right, accuracy: 1e-6, "right at \(item.balance)")
            XCTAssertEqual(max(sides.left, sides.right), 1, "the favoured side stays at unity, never boosted")
        }
    }

    func testOutOfRangeAndNonFiniteBalanceIsClamped() {
        XCTAssertEqual(AudioBalance.clamp(-5), -1)
        XCTAssertEqual(AudioBalance.clamp(5), 1)
        XCTAssertEqual(AudioBalance.clamp(.nan), 0)
        XCTAssertEqual(AudioBalance.clamp(.infinity), 0)
        XCTAssertEqual(AudioBalance.clamp(-.infinity), 0)
        let hardLeft = AudioBalance.sideGains(-3)
        XCTAssertEqual(hardLeft.left, 1); XCTAssertEqual(hardLeft.right, 0)
        let invalid = AudioBalance.sideGains(.nan)
        XCTAssertEqual(invalid.left, 1); XCTAssertEqual(invalid.right, 1)
        XCTAssertEqual(AudioBalance.stepped(-0.004), 0)
        XCTAssertEqual(AudioBalance.stepped(-0.004).sign, .plus, "centre is never stored as -0")
        XCTAssertEqual(AudioBalance.stepped(0.304), 0.3, accuracy: 1e-6)
        XCTAssertEqual(AudioBalance.stepped(-9), -1)
    }

    func testVoiceOverValueAndReadout() {
        XCTAssertEqual(AudioBalance.spokenValue(0), "Center")
        XCTAssertEqual(AudioBalance.spokenValue(-0.3), "30% left")
        XCTAssertEqual(AudioBalance.spokenValue(1), "100% right")
        XCTAssertEqual(AudioBalance.shortLabel(0.004), "C")
        XCTAssertEqual(AudioBalance.shortLabel(-0.3), "30% L")
        XCTAssertEqual(AudioBalance.shortLabel(0.25), "25% R")
    }

    // MARK: Persistence and backup

    func testBalancePersistsOnlyOffCentreAndRoundTrips() throws {
        let d = try defaults()
        let key = "AOMAudioBalance_test.player"
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "test.player", defaults: d), 0, "no setting is centre")
        XCTAssertTrue(AppAudioPreferences.setBalance(-0.3, bundleID: "test.player", defaults: d))
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "test.player", defaults: d), -0.3, accuracy: 1e-6)
        XCTAssertEqual(d.double(forKey: key), -0.3, accuracy: 1e-6)
        XCTAssertTrue(AppAudioPreferences.setBalance(4, bundleID: "test.player", defaults: d))
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "test.player", defaults: d), 1, "stored clamped")
        XCTAssertTrue(AppAudioPreferences.setBalance(0.002, bundleID: "test.player", defaults: d))
        XCTAssertNil(d.object(forKey: key), "centre removes the setting")
        XCTAssertFalse(AppAudioPreferences.setBalance(.nan, bundleID: "test.player", defaults: d))
        XCTAssertFalse(AppAudioPreferences.setBalance(0.5, bundleID: "", defaults: d))
        XCTAssertNil(d.object(forKey: key), "a rejected value changes nothing")
        d.set(7.5, forKey: key)
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "test.player", defaults: d), 1, "a corrupt value is clamped")
        d.set("left", forKey: key)
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "test.player", defaults: d), 0, "a wrong type is centre")
    }

    func testBalanceIsBackedUpAndRestoredAsAFamily() throws {
        XCTAssertTrue(PresetManager.backedUpSettingPrefixes.contains("AOMAudioBalance_"))
        XCTAssertTrue(PresetManager.isBackedUpSetting("AOMAudioBalance_com.example.player"))
        let saved = try defaults()
        XCTAssertTrue(AppAudioPreferences.setBalance(-0.4, bundleID: "com.example.player", defaults: saved))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AOMBalance-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(PresetManager.saveUserDefaultsBackup(from: saved, toFile: file))
        let live = try defaults()
        XCTAssertTrue(AppAudioPreferences.setBalance(0.9, bundleID: "com.example.other", defaults: live))
        XCTAssertNotNil(PresetManager.restoreSettings(fromFile: file, into: live))
        XCTAssertEqual(AppAudioPreferences.balance(bundleID: "com.example.player", defaults: live), -0.4, accuracy: 1e-6)
        XCTAssertNil(live.object(forKey: "AOMAudioBalance_com.example.other"),
                     "the backup holds the balance family completely, so a restore is faithful")
    }

    // MARK: Realtime mixer

    func testBalanceAttenuatesOnlyTheOppositeSideOfInterleavedStereo() {
        let box = MixerBox(gain: 0.5, muted: false)
        box.balance = -0.5
        var input = [Float](repeating: 0, count: 960)
        for frame in 0..<480 { input[frame * 2] = 0.2; input[frame * 2 + 1] = 0.4 }
        var output = [Float](repeating: 0, count: 960)
        mix(box, input: &input, output: &output)
        for frame in 0..<480 {
            XCTAssertEqual(output[frame * 2], 0.1, accuracy: 1e-6, "left: volume only")
            XCTAssertEqual(output[frame * 2 + 1], 0.1, accuracy: 1e-6, "right: volume × 50 %")
        }
        XCTAssertEqual(box.balance, -0.5)
        XCTAssertEqual(box.gain, 0.5, "balance does not change the app volume")
    }

    func testBalanceAppliesToPlanarStereo() {
        let box = MixerBox(gain: 1, muted: false)
        box.balance = 0.75
        let frames = 256
        var inLeft = [Float](repeating: 0.4, count: frames), inRight = [Float](repeating: 0.2, count: frames)
        var outLeft = [Float](repeating: 0, count: frames), outRight = [Float](repeating: 0, count: frames)
        let input = AudioBufferList.allocate(maximumBuffers: 2)
        let output = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer) }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        inLeft.withUnsafeMutableBufferPointer { il in
            inRight.withUnsafeMutableBufferPointer { ir in
                outLeft.withUnsafeMutableBufferPointer { ol in
                    outRight.withUnsafeMutableBufferPointer { orr in
                        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: il.baseAddress)
                        input[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: ir.baseAddress)
                        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: ol.baseAddress)
                        output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: orr.baseAddress)
                        Mixer.mix(input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer, box: box)
                    }
                }
            }
        }
        // 75 % right: left = min(1, 1 - 0.75) = 0.25, right stays at unity.
        XCTAssertTrue(outLeft.allSatisfy { abs($0 - 0.1) < 1e-6 }, "left \(outLeft.prefix(2))")
        XCTAssertTrue(outRight.allSatisfy { abs($0 - 0.2) < 1e-6 }, "right \(outRight.prefix(2))")
    }

    func testMonoInputAndMonoOutputAreLeftUntouched() {
        // A mono source is duplicated to both sides at unity, not panned away.
        let box = MixerBox(gain: 1, muted: false)
        box.balance = -1
        var mono = [Float](repeating: 0.3, count: 256)
        var stereo = [Float](repeating: 0, count: 512)
        mix(box, input: &mono, inputChannels: 1, output: &stereo, outputChannels: 2)
        XCTAssertTrue(stereo.allSatisfy { abs($0 - 0.3) < 1e-6 })
        // A one-channel output only sums the sides; balance would just lose level.
        let summed = MixerBox(gain: 1, muted: false)
        summed.balance = 1
        var input = [Float](repeating: 0, count: 512)
        for frame in 0..<256 { input[frame * 2] = 0.2; input[frame * 2 + 1] = 0.4 }
        var single = [Float](repeating: 0, count: 256)
        mix(summed, input: &input, output: &single, outputChannels: 1)
        XCTAssertTrue(single.allSatisfy { abs($0 - 0.3) < 1e-6 })
    }

    func testAWiderInputIsBalancedOnItsFirstTwoChannels() {
        let box = MixerBox(gain: 1, muted: false)
        box.balance = -0.25
        var quad = [Float](repeating: 0, count: 4 * 128)
        for frame in 0..<128 {
            quad[frame * 4] = 0.2; quad[frame * 4 + 1] = 0.4; quad[frame * 4 + 2] = 0.9; quad[frame * 4 + 3] = 0.9
        }
        var stereo = [Float](repeating: 0, count: 256)
        mix(box, input: &quad, inputChannels: 4, output: &stereo)
        for frame in 0..<128 {
            XCTAssertEqual(stereo[frame * 2], 0.2, accuracy: 1e-6)
            XCTAssertEqual(stereo[frame * 2 + 1], 0.3, accuracy: 1e-6, "0.4 × 75 %")
        }
    }

    /// Like the volume ramp: 5 ms, sample counted, continuous across small
    /// callbacks, so dragging the slider never clicks.
    func testBalanceChangesRampWithoutClicksAcrossSmallCallbacks() {
        let box = MixerBox(gain: 1, muted: false)
        var input = [Float](repeating: 0.5, count: 128), output = input
        mix(box, input: &input, output: &output)
        var previous: (left: Float, right: Float) = (0.5, 0.5)
        for target: (balance: Float, left: Float, right: Float) in [(-1, 0.5, 0), (1, 0, 0.5), (0.4, 0.3, 0.5), (0, 0.5, 0.5)] {
            box.balance = target.balance
            var first = true
            for _ in 0..<5 { // 5 × 64 frames, beyond the 240-sample ramp
                mix(box, input: &input, output: &output)
                for frame in 0..<64 {
                    XCTAssertLessThan(abs(output[frame * 2] - previous.left), 0.003, "no step on the left")
                    XCTAssertLessThan(abs(output[frame * 2 + 1] - previous.right), 0.003, "no step on the right")
                    previous = (output[frame * 2], output[frame * 2 + 1])
                }
                if first {
                    XCTAssertFalse(previous.left == target.left && previous.right == target.right,
                                   "a change ramps instead of jumping")
                    first = false
                }
            }
            XCTAssertEqual(previous.left, target.left, accuracy: 1e-5)
            XCTAssertEqual(previous.right, target.right, accuracy: 1e-5)
        }
    }

    /// The production path without hardware: tap capture → transport queue →
    /// app mixer → summing bus with the output limiter.
    func testBalanceSurvivesTheTransportAndSummingBus() {
        let transport = AppAudioTransport(sampleRate: 48000)
        let mixer = MixerBox(gain: 1, muted: false)
        mixer.balance = 0.5
        let bus = AppAudioRenderBus()
        bus.add(id: UUID()) { transport.render(frames: $0, output: $1, mixer: mixer) }
        var input = [Float](repeating: 0, count: 960), output = input
        var left = 0.0, right = 0.0
        for block in 0..<60 {
            for frame in 0..<480 {
                let value = Float(sin(2 * .pi * 1000 * Double(block * 480 + frame) / 48000)) * 0.1
                input[frame * 2] = value; input[frame * 2 + 1] = value
            }
            withInterleaved(&input, channels: 2) { transport.capture(UnsafePointer($0)) }
            withInterleaved(&output, channels: 2) { bus.render(frames: 480, output: $0) }
            guard block >= 20 else { continue }
            for frame in 0..<480 {
                left += Double(output[frame * 2] * output[frame * 2])
                right += Double(output[frame * 2 + 1] * output[frame * 2 + 1])
            }
        }
        XCTAssertGreaterThan(right, 0, "audio reached the output bus")
        XCTAssertEqual(sqrt(left / right), 0.5, accuracy: 0.01, "50 % right balance leaves the left at half level")
    }
}
