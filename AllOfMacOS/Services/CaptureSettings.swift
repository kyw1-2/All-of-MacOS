import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// User-facing capture preferences, persisted in `UserDefaults`.
///
/// Every value here is read at the moment a capture runs rather than cached, so
/// changing a setting takes effect on the next capture without a restart — the
/// capture path is short-lived and there is nothing to invalidate.
enum RecordingAudioSource: String, CaseIterable, Identifiable {
    case off, computer, microphone

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .computer: return "Computer Audio"
        case .microphone: return "Microphone"
        }
    }
}

enum CaptureFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg, heic, tiff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    /// JPEG and HEIC are lossy, so they need an explicit quality.
    var isLossy: Bool { self == .jpeg || self == .heic }
}

/// Where the Quick Access Overlay parks itself on screen.
enum OverlayCorner: String, CaseIterable, Identifiable, Codable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        }
    }

    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

enum OverlaySize: String, CaseIterable, Identifiable, Codable {
    case extraSmall, small, medium, large, extraLarge
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extraSmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Thumbnail edge length in points.
    var thumbnailSide: CGFloat {
        switch self {
        case .extraSmall: return 100
        case .small: return 120
        case .medium: return 160
        case .large: return 220
        case .extraLarge: return 270
        }
    }

    /// Fixed width allowing all 7 action buttons to breathe comfortably.
    var panelWidth: CGFloat {
        switch self {
        case .extraSmall: return 235
        case .small: return 240
        case .medium: return 270
        case .large: return 315
        case .extraLarge: return 365
        }
    }
}

/// What the overlay does with itself once it has been sitting there.
enum OverlayAutoClose: String, CaseIterable, Identifiable, Codable {
    case never, afterDrag, afterInterval
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .afterDrag: return "After Dragging"
        case .afterInterval: return "After Delay"
        }
    }
}

/// What happens the instant a capture completes, before any overlay appears.
enum AfterCaptureAction: String, CaseIterable, Identifiable, Codable {
    case showOverlay, copyToClipboard, saveToDisk, openAnnotate, doNothing
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showOverlay: return "Show Quick Access Overlay"
        case .copyToClipboard: return "Copy to Clipboard"
        case .saveToDisk: return "Save to Disk"
        case .openAnnotate: return "Open Annotate"
        case .doNothing: return "Do Nothing"
        }
    }
}

/// The capture preferences store.
///
/// These live in `UserDefaults` rather than the preset JSON on purpose: they
/// describe the machine (screen-recording grant, save folder, display layout)
/// more than they describe a gesture binding, and a preset imported from another
/// Mac should not drag someone else's save path along with it.
enum CaptureSettings {
    private static let d = UserDefaults.standard

    private enum Key {
        static let format = "AOMCaptureFormat"
        static let jpegQuality = "AOMCaptureQuality"
        static let showsCursor = "AOMCaptureShowsCursor"
        static let windowShadow = "AOMCaptureWindowShadow"
        static let hidesDesktopIcons = "AOMCaptureHidesDesktopIcons"
        static let playsSound = "AOMCapturePlaysSound"
        static let selfTimerSeconds = "AOMCaptureSelfTimer"
        static let pixelSnap = "AOMCapturePixelSnap"
        static let freezeScreen = "AOMCaptureFreezeScreen"
        static let saveDirectory = "AOMCaptureSaveDirectory"
        static let afterCapture = "AOMCaptureAfterAction"
        static let overlayEnabled = "AOMCaptureOverlayEnabled"
        static let overlayCorner = "AOMCaptureOverlayCorner"
        static let overlaySize = "AOMCaptureOverlaySize"
        static let overlayAutoClose = "AOMCaptureOverlayAutoClose"
        static let overlayAutoCloseSave = "AOMCaptureOverlayAutoCloseSave"
        static let overlayInterval = "AOMCaptureOverlayInterval"
        static let overlayOnActiveDisplay = "AOMCaptureOverlayActiveDisplay"
        static let overlayCloseAfterDrag = "AOMCaptureOverlayCloseAfterDrag"
        static let overlayAsksForName = "AOMCaptureAsksForName"
        static let historyCapacity = "AOMCaptureHistoryCapacity"
        static let lastArea = "AOMCaptureLastArea"
        static let lastAreaDisplayID = "AOMCaptureLastAreaDisplayID"
        static let recordSystemAudio = "AOMCaptureRecordSystemAudio"
        static let recordingAudioSource = "AOMCaptureRecordingAudioSource"
        static let recordingFPS = "AOMCaptureRecordingFPS"
        static let recordingQuality = "AOMCaptureRecordingQuality"
        static let recordingClickIndicators = "AOMCaptureRecordingClickIndicators"
        static let recordingCursorMotion = "AOMCaptureRecordingCursorMotion"
        static let pinnedShadow = "AOMPinnedShadow"
        static let pinnedCorners = "AOMPinnedCorners"
        static let pinnedBorder = "AOMPinnedBorder"
        static let recognizeKeepsLineBreaks = "AOMOCRKeepsLineBreaks"
    }

    static var format: CaptureFormat {
        get { CaptureFormat(rawValue: d.string(forKey: Key.format) ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: Key.format) }
    }

    /// 0…1, used only by the lossy formats.
    static var quality: Double {
        get { d.object(forKey: Key.jpegQuality) as? Double ?? 0.9 }
        set { d.set(min(1, max(0.1, newValue)), forKey: Key.jpegQuality) }
    }

    static var showsCursor: Bool {
        get { d.object(forKey: Key.showsCursor) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.showsCursor) }
    }

    static var windowShadow: Bool {
        get { d.object(forKey: Key.windowShadow) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.windowShadow) }
    }

    static var hidesDesktopIcons: Bool {
        get { d.object(forKey: Key.hidesDesktopIcons) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.hidesDesktopIcons) }
    }

    static var playsSound: Bool {
        get { d.object(forKey: Key.playsSound) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.playsSound) }
    }

    /// Zero means no self-timer.
    static var selfTimerSeconds: Int {
        get { d.object(forKey: Key.selfTimerSeconds) as? Int ?? 0 }
        set { d.set(min(60, max(0, newValue)), forKey: Key.selfTimerSeconds) }
    }

    static var pixelSnap: Bool {
        get { d.object(forKey: Key.pixelSnap) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.pixelSnap) }
    }

    /// Dims and freezes the desktop behind the selection overlay, so windows that
    /// are animating do not move out from under the rectangle you are drawing.
    static var freezeScreen: Bool {
        get { d.object(forKey: Key.freezeScreen) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.freezeScreen) }
    }

    static var saveDirectory: URL {
        get {
            if let path = d.string(forKey: Key.saveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { d.set(newValue.path, forKey: Key.saveDirectory) }
    }

    static var afterCapture: AfterCaptureAction {
        get { AfterCaptureAction(rawValue: d.string(forKey: Key.afterCapture) ?? "") ?? .showOverlay }
        set { d.set(newValue.rawValue, forKey: Key.afterCapture) }
    }

    static var overlayEnabled: Bool {
        get { d.object(forKey: Key.overlayEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.overlayEnabled) }
    }

    static var overlayCorner: OverlayCorner {
        get { OverlayCorner(rawValue: d.string(forKey: Key.overlayCorner) ?? "") ?? .bottomRight }
        set { d.set(newValue.rawValue, forKey: Key.overlayCorner) }
    }

    static var overlaySize: OverlaySize {
        get { OverlaySize(rawValue: d.string(forKey: Key.overlaySize) ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: Key.overlaySize) }
    }

    static var overlayAutoClose: OverlayAutoClose {
        get { OverlayAutoClose(rawValue: d.string(forKey: Key.overlayAutoClose) ?? "") ?? .never }
        set { d.set(newValue.rawValue, forKey: Key.overlayAutoClose) }
    }

    /// If true, auto-close saves previously unsaved captures first. On a
    /// write failure the overlay remains open for manual recovery.
    static var overlayAutoCloseSave: Bool {
        get { d.bool(forKey: Key.overlayAutoCloseSave) }
        set { d.set(newValue, forKey: Key.overlayAutoCloseSave) }
    }

    static var overlayIntervalSeconds: Int {
        get { d.object(forKey: Key.overlayInterval) as? Int ?? 5 }
        set { d.set(min(600, max(1, newValue)), forKey: Key.overlayInterval) }
    }

    /// Independent of the auto-close timer; only after a successful drop.
    static var overlayCloseAfterDrag: Bool {
        get { d.object(forKey: Key.overlayCloseAfterDrag) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.overlayCloseAfterDrag) }
    }

    static var overlayFollowsActiveDisplay: Bool {
        get { d.object(forKey: Key.overlayOnActiveDisplay) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.overlayOnActiveDisplay) }
    }

    static var asksForNameAfterCapture: Bool {
        get { d.object(forKey: Key.overlayAsksForName) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.overlayAsksForName) }
    }

    /// How many recent captures to keep. Zero disables history entirely.
    static var historyCapacity: Int {
        get { d.object(forKey: Key.historyCapacity) as? Int ?? 40 }
        set { d.set(min(500, max(0, newValue)), forKey: Key.historyCapacity) }
    }

    /// The last area the user dragged, in the pointer display's visible-frame
    /// coordinates, so "Capture Previous Area" can replay it. Stored as a plain
    /// string so a corrupt value degrades to "no previous area" rather than
    /// throwing during decode.
    static var lastArea: CGRect? {
        get {
            guard let raw = d.string(forKey: Key.lastArea) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            guard rect.width >= 1, rect.height >= 1, rect.width.isFinite, rect.height.isFinite else { return nil }
            return rect
        }
        set {
            guard let rect = newValue else {
                d.removeObject(forKey: Key.lastArea)
                d.removeObject(forKey: Key.lastAreaDisplayID)
                return
            }
            d.set("\(rect.origin.x),\(rect.origin.y),\(rect.width),\(rect.height)", forKey: Key.lastArea)
        }
    }

    /// The display associated with the last area (local coordinates alone are ambiguous).
    static var lastAreaDisplayID: CGDirectDisplayID? {
        get {
            guard d.object(forKey: Key.lastAreaDisplayID) != nil else { return nil }
            return CGDirectDisplayID(d.integer(forKey: Key.lastAreaDisplayID))
        }
        set {
            if let newValue { d.set(Int(newValue), forKey: Key.lastAreaDisplayID) }
            else { d.removeObject(forKey: Key.lastAreaDisplayID) }
        }
    }

    /// ScreenCaptureKit system audio is opt-in; older installations remain silent.
    static var recordSystemAudio: Bool {
        get { recordingAudioSource == .computer }
        set { recordingAudioSource = newValue ? .computer : .off }
    }

    static var recordingAudioSource: RecordingAudioSource {
        get {
            if let raw = d.string(forKey: Key.recordingAudioSource),
               let value = RecordingAudioSource(rawValue: raw) { return value }
            // Import the preference from an early 1.30.0 development build.
            return d.bool(forKey: Key.recordSystemAudio) ? .computer : .off
        }
        set {
            d.set(newValue.rawValue, forKey: Key.recordingAudioSource)
            d.set(newValue == .computer, forKey: Key.recordSystemAudio)
        }
    }

    static var recordingFPS: Int {
        get {
            let value = d.integer(forKey: Key.recordingFPS)
            return [15, 30, 60].contains(value) ? value : 30
        }
        set { d.set([15, 30, 60].contains(newValue) ? newValue : 30, forKey: Key.recordingFPS) }
    }

    static var recordingQuality: Int {
        get {
            let value = d.integer(forKey: Key.recordingQuality)
            return [1, 2, 3].contains(value) ? value : 2
        }
        set { d.set(min(3, max(1, newValue)), forKey: Key.recordingQuality) }
    }

    static var recordingCursorMotion: Bool {
        get { d.bool(forKey: Key.recordingCursorMotion) }
        set { d.set(newValue, forKey: Key.recordingCursorMotion) }
    }

    static var recordingClickIndicators: Bool {
        get { d.bool(forKey: Key.recordingClickIndicators) }
        set { d.set(newValue, forKey: Key.recordingClickIndicators) }
    }

    static var pinnedShadow: Bool {
        get { d.object(forKey: Key.pinnedShadow) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.pinnedShadow) }
    }

    static var pinnedRoundedCorners: Bool {
        get { d.object(forKey: Key.pinnedCorners) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.pinnedCorners) }
    }

    static var pinnedBorder: Bool {
        get { d.object(forKey: Key.pinnedBorder) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.pinnedBorder) }
    }

    /// CleanShot offers both; the split matters for pasting into a spreadsheet
    /// versus into prose.
    static var ocrKeepsLineBreaks: Bool {
        get { d.object(forKey: Key.recognizeKeepsLineBreaks) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.recognizeKeepsLineBreaks) }
    }
}
