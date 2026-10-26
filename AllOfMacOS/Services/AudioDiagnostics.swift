import Foundation

/// Opt-in local counters only: never records sample audio. Encoding takes
/// place on control; bounded atomic file replacement happens off the UI queue.
enum AudioDiagnostics {
    private static let writer = DispatchQueue(label: "com.kyw.aom.audio.diagnostics", qos: .utility)
    static func write(captures: [String: [String: Any]], outputs: [String: [String: Any]]) {
        let object: [String: Any] = ["timestamp": Date().timeIntervalSince1970,
            "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "AOMSourceRevision") as? String ?? "test",
            "captures": captures, "outputs": outputs]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        writer.async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let directory = base.appendingPathComponent("AllOfMacOS/Diagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try data.write(to: directory.appendingPathComponent("audio-health.json"), options: .atomic)
            } catch { /* Optional diagnostics must never interrupt playback. */ }
        }
    }
}
