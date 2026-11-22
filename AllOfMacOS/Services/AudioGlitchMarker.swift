import AppKit
import Foundation

/// 7.6 (Codex AUD-01 + M12): "I just heard a glitch". One press records the
/// moment; ten seconds later AOM gathers the audio events from ten seconds
/// before to ten seconds after (output gaps and their measured cause,
/// overloads, clock skips, capture gaps), the routes playing (app, direct
/// or queued, AirPlay or not) and the system load, saves them as
/// Diagnostics/audio-marks/<time>.json and says what it found. It never
/// touches playback: no reconnect, no volume, no output change. No audio,
/// titles, network names or device serials are kept.
@MainActor
enum AudioGlitchMarker {
    static let window: TimeInterval = 10

    struct Summary: Equatable {
        var gaps = 0
        var gapFrames: Int64 = 0
        var causes: [String: Int] = [:]
        var overloads = 0
        var other = 0

        var headline: String {
            guard gaps + overloads + other > 0 else {
                return "AOM recorded no output gap within ±10 s; the glitch may come from the app, the network or the receiver"
            }
            var parts: [String] = []
            if gaps > 0 {
                let why = causes.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                parts.append("\(gaps) output gap\(gaps == 1 ? "" : "s")" + (why.isEmpty ? "" : " (\(why))"))
            }
            if overloads > 0 { parts.append("\(overloads) overload\(overloads == 1 ? "" : "s")") }
            if other > 0 { parts.append("\(other) other audio event\(other == 1 ? "" : "s")") }
            return parts.joined(separator: ", ") + " within ±10 s"
        }
    }

    /// Pure: what the events around `mark` say. A gap and its cause are one
    /// gap; events of other sessions after a reset aren't merged in.
    static func summarize(_ events: [AudioEventLog.Event], around mark: Date) -> Summary {
        var summary = Summary()
        for event in events where abs(event.time.timeIntervalSince(mark)) <= window {
            switch event.kind {
            case .cycleGap:
                summary.gaps += 1
                summary.gapFrames += event.value
            case .gapCause:
                if let cause = AirPlayGapCause(rawValue: UInt64(max(0, event.value))) { summary.causes[cause.label, default: 0] += 1 }
            case .overload: summary.overloads += 1
            case .clockSkip, .captureGap, .captureClockReset, .underrun, .dropped, .mixLate: summary.other += 1
            default: break
            }
        }
        return summary
    }

    private static var pending = false
    /// The newest saved mark (Reveal Last Glitch Mark).
    static let lastKey = "AOMAudioGlitch.lastMark"
    static let keep = 50

    static func mark() {
        guard !pending else {
            GestureHUD.shared.show(title: "Glitch Already Marked", detail: "AOM is still collecting the 10 seconds after the last mark.")
            return
        }
        pending = true
        let markedAt = Date()
        AudioEventLog.shared.record(.userMark, source: "user", detail: "heard a glitch")
        AudioEventLog.shared.poll()
        var routes: [[String: Any]] = []
        if #available(macOS 14.2, *) { routes = AppAudioEngine.shared.markRoutes() }
        let load = AudioSystemLoad.summary(AudioSystemLoad.current()) ?? "no load problem"
        GestureHUD.shared.show(title: "Glitch Marked", detail: "Collecting what AOM saw 10 seconds before and after…", icon: "waveform.badge.exclamationmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            pending = false
            AudioEventLog.shared.poll()
            let events = AudioEventLog.shared.snapshot().events.filter { abs($0.time.timeIntervalSince(markedAt)) <= window }
            let summary = summarize(events, around: markedAt)
            // Read again now, so the file shows what changed over the ten seconds after (Gemini 7.6 idea).
            var after: [[String: Any]] = []
            if #available(macOS 14.2, *) { after = AppAudioEngine.shared.markRoutes() }
            let loadAfter = AudioSystemLoad.summary(AudioSystemLoad.current()) ?? "no load problem"
            let file = save(markedAt: markedAt, routes: routes, load: load, routesAfter: after, loadAfter: loadAfter, events: events, summary: summary)
            var detail = summary.headline + "."
            if file == nil { detail += " The record couldn't be saved." }
            if routes.isEmpty { detail += " No app was playing through AOM." }
            if !UserDefaults.standard.bool(forKey: AudioEventLog.diagnosticsKey) { detail += " Audio diagnostics are off, so some counters are missing." }
            GestureHUD.shared.show(title: summary.gaps > 0 ? "Output Gap Found" : "Glitch Marked", detail: detail, icon: "waveform.badge.exclamationmark")
            if let file { GestureLog.shared.logFromAnyThread("Audio glitch mark saved: \(file.path)", level: .action) }
        }
    }

    private static func save(markedAt: Date, routes: [[String: Any]], load: String, routesAfter: [[String: Any]], loadAfter: String,
                             events: [AudioEventLog.Event], summary: Summary) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("AllOfMacOS/Diagnostics/audio-marks", isDirectory: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        let object: [String: Any] = [
            "markedAt": formatter.string(from: markedAt),
            "windowSeconds": window,
            "summary": summary.headline,
            "gaps": summary.gaps, "gapFrames": summary.gapFrames, "gapCauses": summary.causes, "overloads": summary.overloads,
            "routes": routes, "systemLoad": load,
            "routesAfter10s": routesAfter, "systemLoadAfter10s": loadAfter,
            "events": events.map { $0.json },
            "listening": "user mark only; no audio recorded",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let name = formatter.string(from: markedAt).replacingOccurrences(of: ":", with: "-") + ".json"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(url.path, forKey: lastKey)
            prune(folder)
            return url
        } catch { return nil }
    }

    /// Keeps the newest `keep` marks.
    static func prune(_ folder: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        for file in files.dropFirst(keep) { try? FileManager.default.removeItem(at: file) }
    }

    /// Shows the newest mark in Finder (Gemini 7.6 idea).
    static func revealLast() {
        guard let path = UserDefaults.standard.string(forKey: lastKey), FileManager.default.fileExists(atPath: path) else {
            GestureHUD.shared.show(title: "No Glitch Mark Yet", detail: "Use I Just Heard a Glitch when you hear a crackle.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
