import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

// 7.22 (DeepSeek 7.21 report §2.2/§4.2, Granola/MacWhisper): a meeting
// recorded without a bot — your microphone and the other apps' sound in
// two files, a transcript written on this Mac with "Me" and "Others" told
// apart by the file each line came from, and, when Apple Intelligence is
// on, a short summary with decisions and action items. Nothing leaves the
// Mac: recognition must run on-device, and the summary uses the on-device
// model only.
//
// Everything for one meeting sits in Documents/AOM Meetings/<date time
// title>/: microphone.caf, others.caf, transcript.md, summary.md and
// meeting.json. A crash leaves the CAF files playable.

struct MeetingRecording: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var folderName: String
    var hasOthers = false
    var transcriptLines: Int?
    var summarized = false
    var note: String?

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// One recognised stretch of speech.
struct MeetingTranscriptLine: Equatable {
    var time: Double
    var speaker: String
    var text: String
}

enum MeetingTranscript {
    /// Pure: both speakers' lines in time order, as Markdown.
    static func markdown(title: String, startedAt: Date, duration: TimeInterval?, lines: [MeetingTranscriptLine]) -> String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        var out = "# \(title)\n\n\(date)"
        if let duration { out += " · \(clock(duration))" }
        out += "\n\n## Transcript\n\n"
        if lines.isEmpty { out += "_No speech was recognised._\n" }
        for line in lines.sorted(by: { $0.time < $1.time }) {
            out += "**[\(clock(line.time))] \(line.speaker):** \(line.text)\n\n"
        }
        return out
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Pure: recognised words joined into lines — a new line after a pause
    /// of 1.2 s or 30 words.
    static func lines(words: [(time: Double, duration: Double, text: String)], speaker: String, offset: Double) -> [MeetingTranscriptLine] {
        var out: [MeetingTranscriptLine] = []
        var current: [String] = []
        var start = 0.0, lastEnd = -Double.infinity
        func flush() {
            if !current.isEmpty { out.append(.init(time: offset + start, speaker: speaker, text: current.joined(separator: " "))) }
            current.removeAll()
        }
        for word in words {
            if word.time - lastEnd > 1.2 || current.count >= 30 { flush(); start = word.time }
            current.append(word.text)
            lastEnd = word.time + word.duration
        }
        flush()
        return out
    }

    /// The summary prompt for the on-device model.
    static func summaryPrompt(_ transcript: String) -> String {
        """
        Summarise this meeting transcript in the language it is mostly in. Use exactly these Markdown sections: \
        "## Summary" (3–5 sentences), "## Decisions" (bullets), "## Action items" (bullets, with the owner \
        when the transcript names one), "## Open questions" (bullets). Write "None" under a section with nothing. \
        Do not invent names or facts.

        \(transcript)
        """
    }
}

@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    static let shared = MeetingRecorder()

    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing
        case summarizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordings: [MeetingRecording] = []
    @Published private(set) var lastMessage: String?

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    private var engine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var others: MeetingSystemAudioWriter?
    private var current: MeetingRecording?

    static var rootFolder: URL {
        if let preview = PresetManager.previewDirectory { return preview.appendingPathComponent("AOM Meetings") }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AOM Meetings")
    }

    override init() {
        super.init()
        reload()
    }

    func folder(of recording: MeetingRecording) -> URL { Self.rootFolder.appendingPathComponent(recording.folderName) }

    /// The meetings on disk, newest first.
    func reload() {
        guard !PresetManager.isRunningTests else { return }
        let root = Self.rootFolder
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
            return try? JSONDecoder.meetings.decode(MeetingRecording.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func toggle(title: String? = nil) {
        switch phase {
        case .recording: stop()
        case .idle: start(title: title)
        case .transcribing, .summarizing:
            GestureHUD.shared.show(title: "Meeting", detail: "The last meeting is still being transcribed.")
        }
    }

    // MARK: Recording

    func start(title: String? = nil) {
        guard phase == .idle else { return }
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                report("Microphone access is off for AOM. Turn it on in System Settings › Privacy & Security › Microphone.")
                return
            }
            let now = Date()
            let name = Self.folderName(title: title, at: now)
            let folder = Self.rootFolder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
                let file = try AVAudioFile(forWriting: folder.appendingPathComponent("microphone.caf"), settings: format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in try? file.write(from: buffer) }
                engine.prepare()
                try engine.start()
                self.engine = engine
                self.micFile = file
            } catch {
                report("The meeting could not start: \(error.localizedDescription)")
                return
            }
            var recording = MeetingRecording(title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Meeting",
                                             startedAt: now, folderName: name)
            // Other apps' sound needs Screen Recording permission; without it
            // only the microphone is recorded (and the note says so).
            if ScreenCaptureService.hasPermission {
                let writer = MeetingSystemAudioWriter(url: folder.appendingPathComponent("others.caf"))
                do { try await writer.start(); others = writer; recording.hasOthers = true }
                catch { recording.note = "Only your microphone was recorded: \(error.localizedDescription)" }
            } else {
                recording.note = "Only your microphone was recorded. Allow Screen Recording for AOM to record the other people too."
            }
            current = recording
            save(recording)
            phase = .recording(since: now)
            showIndicator(since: now)
            GestureHUD.shared.show(title: "Recording Meeting", detail: recording.hasOthers ? "Microphone and other apps' sound"
                                   : "Microphone only")
        }
    }

    func stop() {
        guard case .recording = phase, var recording = current else { return }
        hideIndicator()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        micFile = nil
        let writer = others
        others = nil
        recording.endedAt = Date()
        current = recording
        save(recording)
        phase = .transcribing
        Task { @MainActor in
            await writer?.stop()
            await finish(recording)
        }
    }

    // MARK: Indicator

    /// A red dot and the elapsed time in the menu bar for as long as the
    /// meeting records; clicking it stops. Always visible, so recording is
    /// never silent.
    private var indicator: NSStatusItem?
    private var indicatorTimer: Timer?

    private func showIndicator(since start: Date) {
        hideIndicator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording meeting")
        item.button?.contentTintColor = .systemRed
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Recording a meeting — click to stop"
        item.button?.target = self
        item.button?.action = #selector(indicatorClicked)
        indicator = item
        let update = { [weak item] in
            item?.button?.title = " " + MeetingTranscript.clock(Date().timeIntervalSince(start))
        }
        update()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in update() }
        RunLoop.main.add(timer, forMode: .common)
        indicatorTimer = timer
    }

    private func hideIndicator() {
        indicatorTimer?.invalidate(); indicatorTimer = nil
        if let indicator { NSStatusBar.system.removeStatusItem(indicator) }
        indicator = nil
    }

    @objc private func indicatorClicked() { stop() }

    // MARK: After recording

    private func finish(_ recording: MeetingRecording) async {
        var recording = recording
        let folder = folder(of: recording)
        var lines: [MeetingTranscriptLine] = []
        var notes: [String] = recording.note.map { [$0] } ?? []
        let authorized = await Self.speechAuthorization()
        if authorized {
            for (file, speaker) in [("microphone.caf", "Me"), ("others.caf", "Others")] {
                let url = folder.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do { lines += try await MeetingTranscriber.transcribe(url, speaker: speaker) }
                catch { notes.append("\(speaker): \(error.localizedDescription)") }
            }
        } else {
            notes.append("Speech Recognition is off for AOM, so no transcript was written. The recording is kept.")
        }
        // 7.23: "Others" split by voice when two voices are clearly apart.
        let othersURL = folder.appendingPathComponent("others.caf")
        if FileManager.default.fileExists(atPath: othersURL.path) {
            let sorted = lines.sorted { $0.time < $1.time }
            lines = await Task.detached(priority: .utility) { MeetingVoices.label(sorted, others: othersURL) }.value
        }
        // 7.23: one mixed file to share (meeting.m4a), the CAFs kept.
        let micURL = folder.appendingPathComponent("microphone.caf")
        _ = await MeetingMixdown.mix(microphone: micURL, others: othersURL, to: folder.appendingPathComponent("meeting.m4a"))
        let markdown = MeetingTranscript.markdown(title: recording.title, startedAt: recording.startedAt,
                                                  duration: recording.duration, lines: lines)
        try? markdown.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        recording.transcriptLines = lines.count
        if !lines.isEmpty, AOMAppleIntelligence.isAvailable {
            phase = .summarizing
            if let summary = await Self.summarize(markdown) {
                try? ("# \(recording.title)\n\n" + summary).write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
                recording.summarized = true
            }
        }
        recording.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        save(recording)
        current = nil
        phase = .idle
        reload()
        GestureHUD.shared.show(title: "Meeting Saved",
                               detail: lines.isEmpty ? (recording.note ?? "No speech was recognised.")
                                   : "\(lines.count) transcript lines\(recording.summarized ? " and a summary" : "")")
    }

    private static func summarize(_ transcript: String) async -> String? {
        // The on-device model's context is small: the first ~5,000 characters
        // of each third, summarised, then the parts combined.
        let parts = stride(from: 0, to: transcript.count, by: 5_000).prefix(3).map { start -> String in
            let begin = transcript.index(transcript.startIndex, offsetBy: start)
            let end = transcript.index(begin, offsetBy: min(5_000, transcript.distance(from: begin, to: transcript.endIndex)))
            return String(transcript[begin..<end])
        }
        var summaries: [String] = []
        for part in parts {
            guard let text = await ask(MeetingTranscript.summaryPrompt(part)) else { return nil }
            summaries.append(text)
        }
        if summaries.count == 1 { return summaries.first }
        return await ask(MeetingTranscript.summaryPrompt(summaries.joined(separator: "\n\n")))
    }

    private static func ask(_ prompt: String) async -> String? {
        var answer = ""
        do {
            for try await piece in AOMAppleIntelligence.stream(system: "You write concise, faithful meeting notes.",
                                                               turns: [AOMAITurn(role: .user, text: prompt)]) {
                switch piece {
                case .text(let more): answer += more
                case .snapshot(let all): answer = all
                default: break
                }
            }
        } catch { return nil }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func speechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    // MARK: Files

    nonisolated static func folderName(title: String?, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let cleaned = (title ?? "").components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return formatter.string(from: date) + (cleaned.isEmpty ? "" : " " + String(cleaned.prefix(60)))
    }

    private func save(_ recording: MeetingRecording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(recording) else { return }
        try? data.write(to: folder(of: recording).appendingPathComponent("meeting.json"), options: .atomic)
    }

    private func report(_ message: String) {
        lastMessage = message
        GestureHUD.shared.show(title: "Meeting Not Recorded", detail: message)
    }

    enum Failure: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone is available." }
    }
}

private extension JSONDecoder {
    static var meetings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Other apps' sound

/// The system's sound (every app but AOM) from ScreenCaptureKit, written as
/// it arrives. The stream asks for a 2×2 picture once a second because a
/// stream must have a display; only the audio is kept.
final class MeetingSystemAudioWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let url: URL
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.meeting-audio")

    init(url: URL) { self.url = url }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw MeetingRecorder.Failure.noMicrophone }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { file = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var basic = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &basic) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)
        }
        try? file?.write(from: buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        GestureLog.shared.logFromAnyThread("Meeting audio stopped: \(error.localizedDescription)", level: .error)
    }
}

// MARK: - Transcription

/// On-device speech recognition, never the server: a file is read in
/// 50-second pieces (recognition of one long request can stop early), each
/// recognised on this Mac, and the words joined into timed lines.
enum MeetingTranscriber {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let why) = self { return why }; return nil }
    }

    static let chunkSeconds = 50.0

    static func recognizer() -> SFSpeechRecognizer? {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        let locale = Locale(identifier: preferred.hasPrefix("ko") ? "ko-KR" : preferred)
        return SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    static func transcribe(_ url: URL, speaker: String) async throws -> [MeetingTranscriptLine] {
        guard let recognizer = recognizer(), recognizer.isAvailable else { throw Failure.unavailable("Speech recognition isn't available for this language.") }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable("On-device recognition isn't available for \(recognizer.locale.identifier); nothing was sent off this Mac.")
        }
        // 7.23: macOS 26's SpeechAnalyzer reads the whole file at once with
        // better accuracy and timing; SFSpeechRecognizer stays the fallback.
        if #available(macOS 26.0, *), let words = try? await MeetingSpeechAnalyzer.transcribe(url, locale: recognizer.locale) {
            return MeetingTranscript.lines(words: words, speaker: speaker, offset: 0)
        }
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let chunkFrames = AVAudioFrameCount(chunkSeconds * format.sampleRate)
        var lines: [MeetingTranscriptLine] = []
        var offset = 0.0
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aom-meeting-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try source.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            try? FileManager.default.removeItem(at: temporary)
            do {
                let piece = try AVAudioFile(forWriting: temporary, settings: format.settings,
                                            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try piece.write(from: buffer)
            }
            let words = try await recognize(temporary, with: recognizer)
            lines += MeetingTranscript.lines(words: words, speaker: speaker, offset: offset)
            offset += Double(buffer.frameLength) / format.sampleRate
        }
        return lines
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [(time: Double, duration: Double, text: String)] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        (time: $0.timestamp, duration: $0.duration, text: $0.substring)
                    })
                } else if let error {
                    resumed = true
                    // Silence ("No speech detected") is not a failure.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 { continuation.resume(returning: []) }
                    else { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
