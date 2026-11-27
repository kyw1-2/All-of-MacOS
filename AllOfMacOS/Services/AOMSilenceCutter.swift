import AVFoundation
import Foundation

/// 7.22 (DeepSeek 7.21 report §3.1/§4.3): Screen Studio's "remove silences".
/// The recording's audio is read once as 16 kHz mono, measured in 10 ms
/// frames, and the quiet stretches become cuts in the Studio sequence — the
/// movie itself is never changed, and every cut can be undone.
///
/// Defaults are Screen Studio's "podcast" preset as found in its bundle
/// (`shortestSilenceMs` 400, `keptAroundSpeechMs` 300, `fadeMs` 10,
/// `pauseBelowSpeechDb` 30); the code is AOM's own.
enum AOMSilenceCutter {
    struct Options: Equatable {
        var shortestSilence: Double = 0.4
        var keptAroundSpeech: Double = 0.3
        /// Quieter than the speech level by this much counts as a pause.
        var belowSpeechDb: Float = 30
        /// Never call anything louder than this silence, whatever the speech level.
        var ceilingDb: Float = -30
        /// And always call anything quieter than this silence.
        var floorDb: Float = -60

        static let gentle = Options(shortestSilence: 0.8, keptAroundSpeech: 0.4, belowSpeechDb: 34)
        static let standard = Options()
        static let tight = Options(shortestSilence: 0.25, keptAroundSpeech: 0.18, belowSpeechDb: 26)
    }

    static let frameSeconds = 0.01
    /// Fade at each cut so a cut never clicks.
    static let fadeSeconds = 0.01

    // MARK: Pure

    /// Level per frame in dBFS (−120 for digital silence).
    static func levels(samples: [Float], frameLength: Int) -> [Float] {
        guard frameLength > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / frameLength + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + frameLength)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            out.append(rms > 1e-6 ? 20 * log10(rms) : -120)
            index = end
        }
        return out
    }

    /// The speech level: the 95th percentile of the frames above −70 dB.
    static func speechLevel(_ levels: [Float]) -> Float? {
        let voiced = levels.filter { $0 > -70 }.sorted()
        guard voiced.count >= 10 else { return nil }
        return voiced[min(voiced.count - 1, Int(Double(voiced.count) * 0.95))]
    }

    /// Silent stretches in seconds, already shrunk by `keptAroundSpeech` on
    /// both sides (the start and end of the recording keep nothing extra).
    static func silentRanges(levels: [Float], frame: Double = frameSeconds, options: Options = .standard) -> [ClosedRange<Double>] {
        guard let speech = speechLevel(levels) else { return [] }
        let threshold = min(options.ceilingDb, max(options.floorDb, speech - options.belowSpeechDb))
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?
        let total = Double(levels.count) * frame
        func close(_ end: Int) {
            guard let begin = runStart else { return }
            runStart = nil
            let start = Double(begin) * frame, finish = Double(end) * frame
            guard finish - start >= options.shortestSilence else { return }
            let keptStart = begin == 0 ? 0 : start + options.keptAroundSpeech
            let keptEnd = end >= levels.count ? total : finish - options.keptAroundSpeech
            if keptEnd - keptStart >= 0.05 { ranges.append(keptStart...keptEnd) }
        }
        for (index, level) in levels.enumerated() {
            if level < threshold { if runStart == nil { runStart = index } } else { close(index) }
        }
        close(levels.count)
        return ranges
    }

    /// `clips` without the `silences` (source seconds), in the same order.
    /// Pieces shorter than 50 ms are dropped.
    static func removing(_ silences: [ClosedRange<Double>], from clips: [AOMStudioClip]) -> [AOMStudioClip] {
        let cuts = silences.sorted { $0.lowerBound < $1.lowerBound }
        var out: [AOMStudioClip] = []
        for clip in clips {
            var cursor = clip.start
            for cut in cuts where cut.upperBound > clip.start && cut.lowerBound < clip.end {
                if cut.lowerBound - cursor >= 0.05 { out.append(AOMStudioClip(start: cursor, end: min(clip.end, cut.lowerBound))) }
                cursor = max(cursor, cut.upperBound)
            }
            if clip.end - cursor >= 0.05 { out.append(AOMStudioClip(start: cursor, end: clip.end)) }
        }
        return out
    }

    /// Total seconds the cuts remove from `clips`.
    static func removedSeconds(_ silences: [ClosedRange<Double>], from clips: [AOMStudioClip]) -> Double {
        clips.reduce(0) { $0 + $1.duration } - removing(silences, from: clips).reduce(0) { $0 + $1.duration }
    }

    /// Output times where one clip ends and the next begins.
    static func boundaries(_ clips: [AOMStudioClip]) -> [Double] {
        var time = 0.0
        var out: [Double] = []
        for clip in clips.dropLast() { time += clip.duration; out.append(time) }
        return out
    }

    // MARK: Reading the movie

    enum Failure: LocalizedError {
        case noAudio, unreadable
        var errorDescription: String? {
            switch self {
            case .noAudio: return "This recording has no sound to look for pauses in."
            case .unreadable: return "The recording's sound could not be read."
            }
        }
    }

    /// Reads the first audio track as 16 kHz mono and returns its frame levels.
    static func levels(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        return try await Task.detached(priority: .userInitiated) { () throws -> [Float] in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            guard reader.canAdd(output) else { throw Failure.unreadable }
            reader.add(output)
            guard reader.startReading() else { throw Failure.unreadable }
            var levels: [Float] = []
            var carry: [Float] = []
            let frameLength = 160
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                carry += samples
                let whole = carry.count / frameLength * frameLength
                if whole > 0 {
                    levels += Self.levels(samples: Array(carry[..<whole]), frameLength: frameLength)
                    carry.removeFirst(whole)
                }
            }
            if !carry.isEmpty { levels += Self.levels(samples: carry, frameLength: frameLength) }
            guard reader.status != .failed else { throw Failure.unreadable }
            return levels
        }.value
    }
}
