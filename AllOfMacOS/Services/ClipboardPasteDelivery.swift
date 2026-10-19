import Foundation

/// A frontmost PID does not imply keyboard ownership: a nonactivating shelf
/// may still own key focus. Relinquish it before testing readiness or sending.
@MainActor
enum ClipboardPasteDelivery {
    struct Environment {
        var relinquishFocus: () -> Void
        var targetIsAlive: () -> Bool
        var targetIsFrontmost: () -> Bool
        var activateTarget: () -> Bool
        var clipboardVersion: () -> Int
        var send: () -> Bool
    }
    enum Outcome: Equatable { case pasted, cancelled, clipboardChanged, unavailable, permissionDenied, activationTimedOut }

    static func deliver(version: Int, environment e: Environment, attempts: Int = 150,
                        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(10)) }) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        guard e.targetIsAlive() else { return .unavailable }
        guard e.clipboardVersion() == version else { return .clipboardChanged }
        e.relinquishFocus()
        if !e.targetIsFrontmost(), !e.activateTarget() { return .unavailable }
        for index in 0..<max(1, attempts) {
            guard !Task.isCancelled else { return .cancelled }
            guard e.targetIsAlive() else { return .unavailable }
            guard e.clipboardVersion() == version else { return .clipboardChanged }
            if e.targetIsFrontmost() { return e.send() ? .pasted : .permissionDenied }
            if index + 1 < attempts {
                do { try await wait() } catch { return .cancelled }
            }
        }
        return .activationTimedOut
    }
}
