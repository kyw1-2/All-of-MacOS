import AVFoundation
import Foundation

/// Fire-and-forget feedback sounds, played off the main thread.
///
/// `NSSound(named:)` searches the sound folders and its first `play()` waits
/// for CoreAudio to start the output device (seconds with Bluetooth
/// headphones) — on the main thread, exactly when a capture result or a paste
/// should appear. Players are prepared once on a private queue and reused.
enum AOMSystemSound {
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.system-sound", qos: .userInitiated)
    private static var players: [String: AVAudioPlayer] = [:]

    static func play(_ name: String, volume: Float = 1) {
        queue.async {
            guard let player = player(name) else { return }
            player.volume = volume
            player.currentTime = 0
            player.play()
        }
    }

    /// Resolves and prepares the sounds ahead of time so the first use is instant.
    static func prewarm(_ names: [String] = ["Pop", "Funk", "Grab", "Glass", "Tink"]) {
        queue.async { for name in names { _ = player(name) } }
    }

    private static func player(_ name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let candidates = ["/System/Library/Sounds/\(name).aiff", "/Library/Sounds/\(name).aiff",
                          NSHomeDirectory() + "/Library/Sounds/\(name).aiff"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
