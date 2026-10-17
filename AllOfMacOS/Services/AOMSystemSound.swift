import AudioToolbox
import Foundation

/// Fire-and-forget system sounds for capture feedback.
///
/// `NSSound(named:)` searches the sound folders and the first `play()` can
/// wait for CoreAudio to start the output device (seconds with Bluetooth
/// headphones) — on the main thread, right when a capture result should
/// appear. System Sound Services plays asynchronously off the main thread.
enum AOMSystemSound {
    private static let lock = NSLock()
    private static var ids: [String: SystemSoundID] = [:]
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.system-sound", qos: .userInitiated)

    static func play(_ name: String) {
        queue.async {
            guard let id = soundID(name) else { return }
            AudioServicesPlaySystemSoundWithCompletion(id, nil)
        }
    }

    /// Resolves the sounds ahead of time so the first capture is instant.
    static func prewarm(_ names: [String] = ["Pop", "Funk", "Grab", "Glass"]) {
        queue.async { for name in names { _ = soundID(name) } }
    }

    private static func soundID(_ name: String) -> SystemSoundID? {
        lock.lock(); defer { lock.unlock() }
        if let id = ids[name] { return id }
        let candidates = ["/System/Library/Sounds/\(name).aiff", "/Library/Sounds/\(name).aiff",
                          NSHomeDirectory() + "/Library/Sounds/\(name).aiff"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == kAudioServicesNoError else { return nil }
        ids[name] = id
        return id
    }
}
