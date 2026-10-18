import Foundation
import CoreGraphics
import ImageIO

/// macOS interactive screenshot selection. The installed TextSniper binary
/// also references the system screencapture utility, although its precise
/// launch arguments could not be established from static inspection.
/// Completion is asynchronous; selection never blocks the UI thread.
enum TextCaptureSelection {
    static func capture() async throws -> CGImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-TextCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("selection.png")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard process.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: output.path) else {
                    continuation.resume(throwing: CaptureError.cancelled)
                    return
                }
                guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    continuation.resume(throwing: CaptureError.captureFailed("The selected image could not be read."))
                    return
                }
                continuation.resume(returning: image)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
