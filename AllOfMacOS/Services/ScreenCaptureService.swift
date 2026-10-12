import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A completed capture, before any encoding or overlay work.
///
/// `image` is the raw pixels; everything else is context the overlay, the
/// history list and the annotate editor need so they never have to re-derive it
/// from the image alone.
struct CaptureResult {
    let image: CGImage
    /// Global top-left-origin rect the image covers, in points.
    let globalRect: CGRect
    let scale: CGFloat
    let kind: CaptureKind
    /// Set only for window captures, so the overlay can name what was captured.
    let windowTitle: String?
    let capturedAt: Date

    init(image: CGImage, globalRect: CGRect, scale: CGFloat, kind: CaptureKind,
         windowTitle: String? = nil, capturedAt: Date = Date()) {
        self.image = image
        self.globalRect = globalRect
        self.scale = scale
        self.kind = kind
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    var pointSize: CGSize { CGSize(width: globalRect.width, height: globalRect.height) }
}

enum CaptureKind: String, Codable {
    case fullscreen, area, window, windowUnderCursor, previousArea, scrolling, selection, videoRecording

    var displayName: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .area: return "Area"
        case .window: return "Window"
        case .windowUnderCursor: return "Window Under Cursor"
        case .previousArea: return "Previous Area"
        case .scrolling: return "Scrolling"
        case .selection: return "Selection"
        case .videoRecording: return "Screen Recording"
        }
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case noWindowFound
    case areaTooSmall
    case captureFailed(String)
    case encodeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording."
        case .noDisplays: return "No display is available to capture."
        case .noWindowFound: return "No capturable window was found under the pointer."
        case .areaTooSmall: return "The selected area is too small to capture."
        case .captureFailed(let reason): return "Capture failed: \(reason)"
        case .encodeFailed: return "The capture could not be encoded in the chosen format."
        case .cancelled: return "Capture cancelled."
        }
    }
}

/// Screen capture built on ScreenCaptureKit.
///
/// `SCScreenshotManager` is used rather than the deprecated
/// `CGWindowListCreateImage` because the latter is unavailable to apps linked
/// against recent SDKs and returns nothing on modern macOS. The one-shot
/// screenshot API also avoids running a continuous `SCStream`, which would keep
/// the screen-recording indicator lit for the whole session.
///
/// Every method here is safe to call from any thread; the ScreenCaptureKit
/// calls are async and the completion lands back on the main actor.
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()
    private init() {}

    // MARK: - Permission

    /// Whether this process may read screen contents.
    ///
    /// `CGPreflightScreenCaptureAccess` reports the current grant without
    /// prompting, which is what a status display needs; the requesting variant
    /// is only used from an explicit user action.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. Returns the state *before* the prompt, so a
    /// caller should re-check `hasPermission` after the user responds.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Shareable content

    private func shareableContent() async throws -> SCShareableContent {
        do {
            // On-screen windows only: an off-screen window has no meaningful
            // pixels to capture, and including them makes the picker noisy.
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// Runs `work`, failing after `seconds` instead of waiting forever.
    ///
    /// ScreenCaptureKit's content query never returns when the process lacks the
    /// screen-recording grant — it is not an error, it simply hangs. Without a
    /// deadline the whole capture path would sit there with no UI and no message,
    /// which is the worst possible failure for something bound to a gesture.
    static func withDeadline<T>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureError.captureFailed("Screen capture did not respond within \(Int(seconds)) seconds. Check Screen Recording permission.")
            }
            guard let first = try await group.next() else {
                throw CaptureError.captureFailed("Screen capture returned no result.")
            }
            group.cancelAll()
            return first
        }
    }

    /// The display whose visible area contains the most of `rect`, falling back
    /// to the display nearest the rect's centre.
    ///
    /// This mirrors `WindowGeometry.screenIndex` but works on `SCDisplay` values,
    /// which carry their own frame rather than being matched against a screen list.
    static func bestDisplay(for rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { display -> CGFloat in
            let overlap = display.frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
            return displays[best]
        }
        return displays.min {
            hypot($0.frame.midX - rect.midX, $0.frame.midY - rect.midY) <
            hypot($1.frame.midX - rect.midX, $1.frame.midY - rect.midY)
        }
    }

    /// The display currently holding the pointer.
    static func displayUnderPointer(in displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        // NSEvent.mouseLocation is bottom-left origin from the primary display;
        // SCDisplay.frame is top-left origin. Flip through the primary's height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        return displays.first { $0.frame.contains(flipped) } ?? bestDisplay(for: CGRect(origin: flipped, size: .zero), in: displays)
    }

    // MARK: - Configuration

    /// Builds a configuration for capturing `sourceRect` (points, top-left
    /// origin, relative to the display being captured).
    ///
    /// `width` and `height` are pixels while `sourceRect` is points, so the
    /// pixel dimensions are the point dimensions multiplied by the display's
    /// backing scale — this is what keeps a Retina capture at native resolution
    /// instead of a half-size image stretched back up.
    private func configuration(sourceRect: CGRect, scale: CGFloat, showsCursor: Bool,
                               pixelSnap: Bool, hidesShadow: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        var rect = sourceRect
        if pixelSnap {
            // Snap the origin to whole pixels so the captured image does not
            // resample every edge, which is what makes a 1px selection blurry.
            rect = CGRect(x: (rect.origin.x * scale).rounded() / scale,
                          y: (rect.origin.y * scale).rounded() / scale,
                          width: (rect.width * scale).rounded() / scale,
                          height: (rect.height * scale).rounded() / scale)
        }
        config.sourceRect = rect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.scalesToFit = false
        // Only meaningful for a single-window filter; a display capture ignores it.
        config.ignoreShadowsSingleWindow = hidesShadow
        return config
    }

    // MARK: - Fullscreen

    func captureFullscreen(display: SCDisplay? = nil, showsCursor: Bool = CaptureSettings.showsCursor) async throws -> CaptureResult {
        try await Self.withDeadline(seconds: 20) { [self] in
            let content = try await shareableContent()
            guard let target = display ?? content.displays.first else { throw CaptureError.noDisplays }
            return try await captureDisplay(target, sourceRect: target.frame, scale: 1,
                                            showsCursor: showsCursor, kind: .fullscreen)
        }
    }

    /// Captures every attached display as one image, laid out in the same
    /// relative arrangement the user sees.
    func captureAllDisplays(showsCursor: Bool = CaptureSettings.showsCursor) async throws -> [CaptureResult] {
        try await Self.withDeadline(seconds: 30) { [self] in
            let content = try await shareableContent()
            guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
            var results: [CaptureResult] = []
            for display in content.displays {
                results.append(try await captureDisplay(display, sourceRect: display.frame, scale: 1,
                                                        showsCursor: showsCursor, kind: .fullscreen))
            }
            return results
        }
    }

    private func captureDisplay(_ display: SCDisplay, sourceRect: CGRect, scale: CGFloat,
                                showsCursor: Bool, kind: CaptureKind,
                                hidesShadow: Bool = true, pixelSnap: Bool = CaptureSettings.pixelSnap) async throws -> CaptureResult {
        let content = try await shareableContent()
        guard let fresh = content.displays.first(where: { $0.displayID == display.displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplays
        }
        let filter = SCContentFilter(display: fresh, excludingWindows: [])
        let backingScale = backingScale(for: fresh)
        let config = configuration(sourceRect: sourceRect, scale: backingScale,
                                   showsCursor: showsCursor, pixelSnap: pixelSnap, hidesShadow: hidesShadow)
        let image = try await capture(filter: filter, config: config)
        return CaptureResult(image: image, globalRect: sourceRect, scale: backingScale, kind: kind)
    }

    // MARK: - Area

    /// Captures a global rect (top-left origin, points).
    ///
    /// A selection can straddle two displays. ScreenCaptureKit captures one
    /// display per filter, so the display with the largest overlap wins and the
    /// part of the rect outside it is clipped — which is what the user sees
    /// happen, since the overlay draws that boundary too.
    func captureArea(_ globalRect: CGRect, showsCursor: Bool = CaptureSettings.showsCursor,
                     pixelSnap: Bool = CaptureSettings.pixelSnap) async throws -> CaptureResult {
        guard globalRect.width >= 1, globalRect.height >= 1 else { throw CaptureError.areaTooSmall }
        return try await Self.withDeadline(seconds: 20) { [self] in
        let content = try await shareableContent()
        guard let display = Self.bestDisplay(for: globalRect, in: content.displays) else {
            throw CaptureError.noDisplays
        }
        let local = globalRect.offsetBy(dx: -display.frame.origin.x, dy: -display.frame.origin.y)
        let clipped = local.intersection(CGRect(origin: .zero, size: display.frame.size))
        guard clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.areaTooSmall }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let backingScale = backingScale(for: display)
        let config = configuration(sourceRect: clipped, scale: backingScale,
                                   showsCursor: showsCursor, pixelSnap: pixelSnap, hidesShadow: true)
        let image = try await capture(filter: filter, config: config)
        // Report the clipped global rect so downstream code (history, annotate,
        // pin placement) agrees with the pixels that actually came back.
        let globalClipped = clipped.offsetBy(dx: display.frame.origin.x, dy: display.frame.origin.y)
        return CaptureResult(image: image, globalRect: globalClipped, scale: backingScale, kind: .area)
        }
    }

    // MARK: - Window

    /// Captures one window, including its shadow unless the user turned that off.
    func captureWindow(_ window: SCWindow) async throws -> CaptureResult {
        try await Self.withDeadline(seconds: 20) { [self] in
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = backingScale(for: window)
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !CaptureSettings.windowShadow
        let image = try await capture(filter: filter, config: config)
        return CaptureResult(image: image, globalRect: window.frame, scale: scale,
                             kind: .window, windowTitle: window.title)
        }
    }

    /// The frontmost active window where the user is currently working / typing.
    /// Prefers the key window of `NSWorkspace.shared.frontmostApplication`,
    /// falling back to the topmost standard application window on screen.
    func frontmostCapturableWindow(excludingPID ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> SCWindow {
        try await Self.withDeadline(seconds: 20) { [self] in
            let content = try await shareableContent()
            let frontApp = NSWorkspace.shared.frontmostApplication

            if let frontApp, frontApp.processIdentifier != ownPID {
                let appWindows = content.windows.filter { w in
                    guard w.isOnScreen, let app = w.owningApplication else { return false }
                    guard app.processID == frontApp.processIdentifier else { return false }
                    guard w.windowLayer == 0 || (w.windowLayer > 0 && w.windowLayer < 10) else { return false }
                    guard w.frame.width >= 100, w.frame.height >= 100 else { return false }
                    return true
                }
                if let best = appWindows.first { return best }
            }

            let anyWindows = content.windows.filter { w in
                guard w.isOnScreen, let app = w.owningApplication, app.processID != ownPID else { return false }
                guard w.windowLayer == 0 else { return false }
                guard w.frame.width >= 100, w.frame.height >= 100 else { return false }
                return true
            }
            guard let best = anyWindows.first else { throw CaptureError.noWindowFound }
            return best
        }
    }

    /// The frontmost capturable window under the pointer.
    ///
    /// `CGWindowListCopyWindowInfo` is used only to learn *which* window is under
    /// the cursor — the pixels still come from ScreenCaptureKit. The list is
    /// ordered front-to-back, so the first hit that is on screen, large enough to
    /// be a real window, and owned by another process is the answer.
    func windowUnderCursor(excludingPID ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> SCWindow {
        try await Self.withDeadline(seconds: 20) { [self] in
        let content = try await shareableContent()
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)

        let candidates = content.windows.filter { window in
            guard window.isOnScreen, let app = window.owningApplication else { return false }
            guard app.processID != ownPID else { return false }
            // Ignore the desktop, the menu bar and tiny helper windows: they are
            // technically windows but nobody means to capture them.
            guard window.frame.width >= 40, window.frame.height >= 40 else { return false }
            return window.frame.contains(flipped)
        }
        guard let best = candidates.first else { throw CaptureError.noWindowFound }
        return best
        }
    }

    /// Every capturable window, for a picker UI.
    func capturableWindows() async throws -> [SCWindow] {
        try await Self.withDeadline(seconds: 20) { [self] in
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { window in
            guard window.isOnScreen, let app = window.owningApplication else { return false }
            guard app.processID != ownPID else { return false }
            return window.frame.width >= 40 && window.frame.height >= 40
        }
        }
    }

    // MARK: - Capture primitive

    private func capture(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    // MARK: - Scale helpers

    /// The backing scale factor for the display an `SCDisplay` covers.
    ///
    /// ScreenCaptureKit does not report this, so it is matched against
    /// `NSScreen` by display ID. A display with no `NSScreen` (a headless or
    /// just-disconnected one) falls back to 1 rather than guessing 2, because
    /// over-reporting the scale produces a stretched image while under-reporting
    /// only loses sharpness.
    func backingScale(for display: SCDisplay) -> CGFloat {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == display.displayID {
                return screen.backingScaleFactor
            }
        }
        return 1
    }

    /// The scale of the display a window sits on, by largest overlap.
    func backingScale(for window: SCWindow) -> CGFloat {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 1 }
        let primaryHeight = screens[0].frame.height
        var best = screens[0]
        var bestArea: CGFloat = 0
        for screen in screens {
            // NSScreen frames are bottom-left origin; the window frame is
            // top-left origin. Convert before comparing.
            let flipped = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
            let overlap = flipped.intersection(window.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { bestArea = area; best = screen }
        }
        return best.backingScaleFactor
    }

    // MARK: - Encoding

    /// Encodes a capture to the user's chosen format.
    func encode(_ result: CaptureResult, format: CaptureFormat = CaptureSettings.format,
                quality: Double = CaptureSettings.quality) throws -> Data {
        let data: Data?
        switch format {
        case .png:
            data = Self.representation(result.image, as: .png, quality: 1)
        case .jpeg:
            data = Self.representation(result.image, as: .jpeg, quality: quality)
        case .tiff:
            data = Self.representation(result.image, as: .tiff, quality: 1)
        case .heic:
            data = Self.encodeHEIC(result.image, quality: quality)
        }
        guard let data else { throw CaptureError.encodeFailed }
        return data
    }

    private static func representation(_ image: CGImage, as type: NSBitmapImageRep.FileType, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        // Tag the file with the display's own colour space so a capture on a
        // wide-gamut display keeps its colour instead of shifting to sRGB.
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: type, properties: [.compressionFactor: quality])
    }

    /// HEIC has no `NSBitmapImageRep` type, so it goes through ImageIO directly.
    private static func encodeHEIC(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes a capture to disk with a timestamped name and returns the URL.
    @discardableResult
    func writeToDisk(_ result: CaptureResult, directory: URL = CaptureSettings.saveDirectory,
                     format: CaptureFormat = CaptureSettings.format,
                     fileName: String? = nil) throws -> URL {
        let data = try encode(result, format: format)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName ?? CaptureNaming.defaultName(for: result)
        var url = directory.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        // Never clobber an existing file: two captures inside the same second are
        // ordinary, and silently overwriting one would lose it.
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Puts the capture on the general pasteboard as image data, so it pastes
    /// into anything that accepts an image rather than only into Finder.
    func copyToClipboard(_ result: CaptureResult, format: CaptureFormat = CaptureSettings.format) throws {
        let data = try encode(result, format: format)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType(format.contentType.identifier)) else {
            throw CaptureError.captureFailed("The image could not be copied to the clipboard.")
        }
        // A TIFF entry alongside is what makes Preview, Notes and Keynote accept
        // the paste without knowing about HEIC or WebP.
        if let tiff = Self.representation(result.image, as: .tiff, quality: 1) {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Copies the file itself (not its pixels) so pasting into Finder or Mail
    /// attaches the image rather than inlining it.
    @discardableResult
    func copyFileToClipboard(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }
}

/// Timestamped file naming, matching the `Screenshot 2026-10-11 at 17.42.03`
/// shape macOS itself uses so captures sort next to system ones.
enum CaptureNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Independent, optional filename template modeled on the controls visible
    /// in the official UI. Tokens are plain text, not executable expressions.
    /// An empty template deliberately preserves AOM's legacy naming format.
    static func templateName(_ pattern: String, date: Date, kind: String,
                             windowTitle: String?, width: Int, height: Int,
                             prefix: String = "Screenshot", utc: Bool = false) -> String {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : .current
        f.dateFormat = "yyyy-MM-dd"
        let dateString = f.string(from: date)
        f.dateFormat = "HH.mm.ss"
        let timeString = f.string(from: date)
        let substitutions: [String: String] = [
            "{prefix}": prefix, "{date}": dateString, "{time}": timeString,
            "{datetime}": dateString + " at " + timeString,
            "{kind}": kind, "{window}": windowTitle ?? "",
            "{width}": String(width), "{height}": String(height)
        ]
        var name = pattern
        // Replace tokens longest first so similarly-prefixed names remain stable.
        for key in substitutions.keys.sorted(by: { $0.count > $1.count }) {
            name = name.replacingOccurrences(of: key, with: substitutions[key]!)
        }
        // Strip file separators, invisible control characters and platform-
        // sensitive punctuation; never allow a user template to escape the
        // configured capture directory or create hidden "." paths.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        let sanitized = name.unicodeScalars.map { safe.contains($0) ? String($0) : "-" }.joined()
        let normalized = sanitized.replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return String(normalized.prefix(120))
    }

    static func defaultName(for result: CaptureResult, prefix: String = "Screenshot") -> String {
        let pattern = UserDefaults.standard.string(forKey: "AOMCaptureFilenameTemplate") ?? ""
        if !pattern.isEmpty {
            let named = templateName(pattern, date: result.capturedAt,
                                     kind: result.kind.displayName,
                                     windowTitle: result.windowTitle,
                                     width: result.image.width, height: result.image.height,
                                     prefix: prefix,
                                     utc: UserDefaults.standard.bool(forKey: "AOMCaptureFilenameUTC"))
            if !named.isEmpty { return named }
        }
        let stamp = formatter.string(from: result.capturedAt)
        // A window capture is easier to find again if it says which window it was.
        if let title = result.windowTitle, !title.isEmpty {
            let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted)
                .joined()
                .trimmingCharacters(in: .whitespaces)
            if !safe.isEmpty { return "\(prefix) \(stamp) \(String(safe.prefix(60)))" }
        }
        return "\(prefix) \(stamp)"
    }
}
