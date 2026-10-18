import Foundation
import CoreGraphics
import VisionKit

/// Low-latency interactive path: choose one recognizer and copy its result.
/// Geometry consumers keep using TextRecognitionEngine's detailed pipeline.
enum TextCaptureInstant {
    static func prefersLiveText(engine: TextRecognitionEngineMode, primaryLanguage: String?) -> Bool {
        if engine == .liveText { return true }
        guard engine == .automatic, let language = primaryLanguage else { return false }
        return ["ko", "ja", "zh", "yue"].contains(language.components(separatedBy: "-")[0])
    }

    static func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        guard options.prefersSpeed else {
            return try await TextRecognitionEngine.recognize(image, options: options)
        }
        let size = CGSize(width: image.width, height: image.height)
        guard image.width >= 2, image.height >= 2 else { return .empty(size) }
        let priority = TextCaptureLanguages.priorityList(selected: options.languages,
                                                         automatic: options.languages.isEmpty)
        let liveFirst = prefersLiveText(engine: options.engine, primaryLanguage: priority.first)
            && ImageAnalyzer.isSupported
        if liveFirst, let result = await liveResult(image, priority: priority, options: options) {
            return result
        }

        // No token boxes, upscaling, script voting, or crop re-reads are needed
        // to copy text. Those remain available through precision mode.
        let observations = try await TextRecognitionEngine.recognizeObservations(
            image, languages: TextRecognitionEngine.fastLanguages(priority), autoDetect: true,
            correction: options.usesLanguageCorrection, customWords: options.customWords)
        let lines = observations.compactMap { observation -> TextLayoutLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextLayoutLine(text: candidate.string,
                box: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                            width: box.width * size.width, height: box.height * size.height),
                confidence: observation.confidence)
        }
        let text = TextLayoutAssembler.assemble(lines, options: .init(
            keepsLineBreaks: options.keepsLineBreaks,
            joinsHyphenatedWords: options.joinsHyphenatedWords, detectsColumns: options.detectsColumns))
        // One fallback only, and only when the chosen engine found no text.
        if text.isEmpty, !liveFirst, options.engine != .vision,
           let result = await liveResult(image, priority: priority, options: options) {
            return result
        }
        return .init(text: text, lines: lines, imageSize: size,
                     detectedLanguage: TextRecognitionEngine.dominantLanguage(text),
                     passCount: 1, usedLiveText: false, upscale: 1, inverted: false,
                     liveTextTranscript: nil)
    }

    private static func liveResult(_ image: CGImage, priority: [String],
                                   options: TextRecognitionOptions) async -> TextRecognitionResult? {
        // Do not load every supported locale into the interactive Live Text model.
        guard let transcript = await TextRecognitionEngine.liveTextTranscript(
            image, locales: TextRecognitionEngine.fastLanguages(priority)),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = TextRecognitionEngine.postProcessTranscript(lines, options: options)
        return .init(text: text, lines: [], imageSize: CGSize(width: image.width, height: image.height),
                     detectedLanguage: TextRecognitionEngine.dominantLanguage(text),
                     passCount: 0, usedLiveText: true, upscale: 1, inverted: false,
                     liveTextTranscript: transcript)
    }
}

/// A structured task group waits for losing children even after cancelAll().
/// OS analysis can ignore cancellation, so use a one-shot continuation instead.
/// A late result cannot resume the caller twice or write to the clipboard.
final class TextAnalysisDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    private func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func register(_ task: Task<Void, Never>) {
        lock.lock()
        if finished { lock.unlock(); task.cancel(); return }
        tasks.append(task)
        lock.unlock()
    }

    private func finish(_ result: Value?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let pending = tasks
        tasks.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }

    static func run(seconds: Double, operation: @escaping @Sendable () async -> Value?) async -> Value? {
        let state = TextAnalysisDeadline<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                state.register(Task.detached(priority: .userInitiated) { state.finish(await operation()) })
                state.register(Task.detached {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
                    catch { return }
                    state.finish(nil)
                })
            }
        } onCancel: { state.finish(nil) }
    }
}
