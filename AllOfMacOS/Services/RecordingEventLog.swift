import Foundation

/// A small persistent record of how screen recordings ended, added with the
/// 2026-10-28 audit's recording work (F06). Until 3.3.1 a failed,
/// truncated or partly saved take left only a transient HUD and an NSLog line.
///
/// One JSON object per line in `Application Support/AllOfMacOS/Diagnostics/
/// recording-events.jsonl` (0600): time, event, the movie's file name — never
/// its folder or any content — and a short reason. Only the newest
/// `maximumLines` are kept.
enum RecordingEventLog {
    static let maximumLines = 500
    static let fileName = "recording-events.jsonl"
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.recording-events", qos: .utility)

    /// Tests and UI previews never write into the real Application Support.
    static var defaultDirectory: URL {
        if let preview = PresetManager.previewDirectory { return preview.appendingPathComponent("Diagnostics", isDirectory: true) }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "AOMTestDiagnostics-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/Diagnostics", isDirectory: true)
    }

    static func record(_ event: String, file: URL?, detail: String = "",
                       directory: URL = RecordingEventLog.defaultDirectory, now: Date = Date()) {
        let entry: [String: String] = [
            "time": ISO8601DateFormatter().string(from: now),
            "event": event,
            "file": file?.lastPathComponent ?? "",
            "detail": String(detail.prefix(600)),
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let target = directory.appendingPathComponent(fileName)
        queue.async { append(String(decoding: line, as: UTF8.self), to: target) }
    }

    /// Waits for queued writes (tests, and before reading the archive).
    static func flush() { queue.sync {} }

    /// The archived events, oldest first.
    static func entries(directory: URL = RecordingEventLog.defaultDirectory) -> [[String: String]] {
        flush()
        guard let text = try? String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    private static func append(_ line: String, to target: URL) {
        let folder = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var lines = ((try? String(contentsOf: target, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        lines.append(line)
        if lines.count > maximumLines { lines.removeFirst(lines.count - maximumLines) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            NSLog("[AOM] Recording event log not written: %@", error.localizedDescription)
        }
    }
}
