import AVFoundation
import Accelerate
import Speech

// 7.23 (the 7.22 meeting open items): one mixed audio file to share, the
// newer on-device speech model where macOS has it, and "Others" told apart
// by voice when the call clearly has two different voices.

// MARK: - Mixed M4A

enum MeetingMixdown {
    /// Microphone and other apps' sound in one AAC file (meeting.m4a), both
    /// from the start. The CAF originals stay.
    static func mix(microphone: URL?, others: URL?, to output: URL) async -> Bool {
        let composition = AVMutableComposition()
        var any = false
        for url in [microphone, others].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            if (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)) != nil { any = true }
        }
        guard any, let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return false }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        return session.status == .completed
    }
}

// MARK: - SpeechAnalyzer (macOS 26)

@available(macOS 26.0, *)
enum MeetingSpeechAnalyzer {
    /// Nil when the language has no on-device model here; the caller falls
    /// back to SFSpeechRecognizer.
    static func transcribe(_ url: URL, locale: Locale) async throws -> [(time: Double, duration: Double, text: String)]? {
        let supported = await SpeechTranscriber.supportedLocales
        guard let match = supported.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
                ?? supported.first(where: { $0.language.languageCode == locale.language.languageCode }) else { return nil }
        let transcriber = SpeechTranscriber(locale: match, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The model is Apple's, installed on this Mac; audio never leaves it.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [(time: Double, duration: Double, text: String)] in
            var pieces: [(time: Double, duration: Double, text: String)] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                pieces.append((time: result.range.start.seconds, duration: result.range.duration.seconds, text: text))
            }
            return pieces
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

// MARK: - Voices in "Others"

/// A conservative two-voice split: each "Others" line gets the median pitch
/// of its audio, and the lines are split in two only when the two groups'
/// pitches are far apart and both are a real part of the call. Anything less
/// clear stays "Others" — a wrong name is worse than none.
enum MeetingVoices {
    static let defaultsKey = "AOMMeetingSplitVoices"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Hz between the two groups' centres before they count as two voices.
    static let minimumGap = 35.0
    /// Each voice must have at least this share of the lines.
    static let minimumShare = 0.2

    /// Median F0 (Hz) of the voiced 40 ms frames, nil when nothing voiced.
    static func pitch(_ samples: [Float], sampleRate: Double) -> Double? {
        let frame = Int(sampleRate * 0.04)
        guard frame > 0, samples.count >= frame else { return nil }
        let minLag = Int(sampleRate / 400), maxLag = min(frame - 1, Int(sampleRate / 70))
        guard minLag < maxLag else { return nil }
        var pitches: [Double] = []
        var start = 0
        while start + frame <= samples.count {
            let window = Array(samples[start..<(start + frame)])
            var rms: Float = 0
            vDSP_rmsqv(window, 1, &rms, vDSP_Length(frame))
            if rms > 0.01 {
                var best = 0, bestValue: Float = 0, energy: Float = 0
                vDSP_dotpr(window, 1, window, 1, &energy, vDSP_Length(frame))
                for lag in minLag...maxLag {
                    var value: Float = 0
                    window.withUnsafeBufferPointer { buffer in
                        vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1, &value, vDSP_Length(frame - lag))
                    }
                    if value > bestValue { bestValue = value; best = lag }
                }
                if best > 0, energy > 0, bestValue / energy > 0.3 { pitches.append(sampleRate / Double(best)) }
            }
            start += frame
        }
        guard !pitches.isEmpty else { return nil }
        let sorted = pitches.sorted()
        return sorted[sorted.count / 2]
    }

    /// Pure: 0 or 1 for each line (nil pitch → nil), or nil when the split
    /// isn't clear. Two-means on one dimension.
    static func split(_ pitches: [Double?]) -> [Int?]? {
        let known = pitches.compactMap { $0 }
        guard known.count >= 6, let low = known.min(), let high = known.max(), high - low >= minimumGap else { return nil }
        var a = low, b = high
        for _ in 0..<20 {
            let groupA = known.filter { abs($0 - a) <= abs($0 - b) }
            let groupB = known.filter { abs($0 - a) > abs($0 - b) }
            guard !groupA.isEmpty, !groupB.isEmpty else { return nil }
            a = groupA.reduce(0, +) / Double(groupA.count)
            b = groupB.reduce(0, +) / Double(groupB.count)
        }
        let countA = known.filter { abs($0 - a) <= abs($0 - b) }.count
        let share = Double(min(countA, known.count - countA)) / Double(known.count)
        guard abs(b - a) >= minimumGap, share >= minimumShare else { return nil }
        return pitches.map { pitch in pitch.map { abs($0 - a) <= abs($0 - b) ? 0 : 1 } }
    }

    /// Renames "Others" lines to "Others 1" / "Others 2" when the voices split.
    static func label(_ lines: [MeetingTranscriptLine], others url: URL) -> [MeetingTranscriptLine] {
        guard isEnabled, let file = try? AVAudioFile(forReading: url) else { return lines }
        let rate = file.processingFormat.sampleRate
        let indexes = lines.indices.filter { lines[$0].speaker == "Others" }
        guard indexes.count >= 6 else { return lines }
        var pitches: [Double?] = []
        for (n, index) in indexes.enumerated() {
            let start = lines[index].time
            let end = n + 1 < indexes.count ? min(lines[indexes[n + 1]].time, start + 15) : start + 8
            pitches.append(samples(file, from: start, to: end).flatMap { pitch($0, sampleRate: rate) })
        }
        guard let groups = split(pitches) else { return lines }
        var out = lines
        for (n, index) in indexes.enumerated() {
            if let group = groups[n] { out[index].speaker = "Others \(group + 1)" }
        }
        return out
    }

    private static func samples(_ file: AVAudioFile, from start: Double, to end: Double) -> [Float]? {
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start) * rate)
        let count = AVAudioFrameCount(max(0, end - start) * rate)
        guard first < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: min(count, AVAudioFrameCount(file.length - first)))) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// 7.23: start recording without a click when the microphone turns on
/// during a calendar meeting (off by default; the red menu bar dot shows).
enum MeetingAutoRecord {
    static let defaultsKey = "AOMMeetingAutoRecord"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
