import AppKit
import ScreenCaptureKit

/// One display captured for a measuring session: the still image the
/// overlay shows and the same pixels copied into memory for edge scanning.
struct ScreenRulerFrame {
    let snapshot: ScreenRulerSnapshot
    let image: CGImage
}

enum ScreenRulerError: LocalizedError, Equatable {
    case noDisplays
    case unreadableCapture
    case captureFailed(String)
    case displaysChanged

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display is available to measure."
        case .unreadableCapture: return "The screen image could not be read for measuring."
        case .captureFailed(let reason): return "The screen could not be captured: \(reason)"
        case .displaysChanged: return "The displays changed while measuring started. Try again."
        }
    }
}

/// Captures every display once, at its native scale, with ScreenCaptureKit.
///
/// AOM's own windows are left out (the main window, HUDs, the closing status
/// menu), so the ruler measures what is behind them; AOM's menu bar icon
/// stays so the menu bar looks the same. A session never captures again:
/// every pointer move is answered from these pixels.
enum ScreenRulerCapture {
    /// The menu bar extras' window layer.
    static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

    /// `scales` maps each display to its `NSScreen.backingScaleFactor`, the
    /// fallback when the content filter does not report one.
    static func captureDisplays(scales: [CGDirectDisplayID: CGFloat]) async throws -> [ScreenRulerFrame] {
        try await ScreenCaptureService.withDeadline(seconds: 10) {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw ScreenRulerError.captureFailed(error.localizedDescription)
            }
            guard !content.displays.isEmpty else { throw ScreenRulerError.noDisplays }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter {
                $0.owningApplication?.processID == ownPID && $0.windowLayer != statusItemLayer
            }
            var frames: [ScreenRulerFrame] = []
            for display in content.displays {
                frames.append(try await capture(display, fallbackScale: scales[display.displayID] ?? 1,
                                                excluding: ownWindows))
            }
            return frames
        }
    }

    private static func capture(_ display: SCDisplay, fallbackScale: CGFloat,
                                excluding windows: [SCWindow]) async throws -> ScreenRulerFrame {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let reported = CGFloat(filter.pointPixelScale)
        let scale = reported > 0 ? reported : fallbackScale
        let config = SCStreamConfiguration()
        config.width = max(1, Int((display.frame.width * scale).rounded()))
        config.height = max(1, Int((display.frame.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenRulerError.captureFailed(error.localizedDescription)
        }
        guard let bitmap = ScreenRulerBitmap(image: image) else { throw ScreenRulerError.unreadableCapture }
        let geometry = ScreenRulerDisplay(id: display.displayID, frame: display.frame, scale: scale)
        return ScreenRulerFrame(snapshot: ScreenRulerSnapshot(display: geometry, bitmap: bitmap), image: image)
    }
}
