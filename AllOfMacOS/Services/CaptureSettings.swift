import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// User-facing capture preferences, persisted in `UserDefaults`.
///
/// Every value here is read at the moment a capture runs rather than cached, so
/// changing a setting takes effect on the next capture without a restart — the
/// capture path is short-lived and there is nothing to invalidate.
enum RecordingAudioSource: String, CaseIterable, Identifiable {
    case off, computer, microphone, computerAndMicrophone

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .computer: return "Computer Audio"
        case .microphone: return "Microphone"
        case .computerAndMicrophone: return "Computer + Microphone"
        }
    }
}

enum CaptureFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg, heic, tiff, webp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .webp: return "WebP"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .webp: return UTType("org.webmproject.webp") ?? .image
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .webp: return "webp"
        }
    }

    /// JPEG and HEIC are lossy, so they need an explicit quality.
    var isLossy: Bool { self == .jpeg || self == .heic || self == .webp }
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

    /// CleanShot's "Position on screen" only offers Left / Right (bottom
    /// corners). The top corners stay available as AOM extras.
    var positionName: String {
        switch self {
        case .bottomLeft: return "Left"
        case .bottomRight: return "Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }

    /// Picker order: the two CleanShot positions first, then the AOM extras.
    static let pickerOrder: [OverlayCorner] = [.bottomLeft, .bottomRight, .topLeft, .topRight]

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

    /// Position on CleanShot's 5-tick "Overlay size" slider (0…4).
    var sliderIndex: Int { Self.allCases.firstIndex(of: self) ?? 1 }

    /// Clamped inverse of `sliderIndex`; out-of-range values snap to the ends.
    static func fromSliderIndex(_ index: Int) -> OverlaySize {
        allCases[min(allCases.count - 1, max(0, index))]
    }

    /// Thumbnail edge length in points.
    var thumbnailSide: CGFloat {
        switch self {
        case .extraSmall: return 100
        case .small: return 132
        case .medium: return 160
        case .large: return 210
        case .extraLarge: return 260
        }
    }

    /// Card width; the thumbnail is aspect-fit inside `panelWidth × thumbnailSide`.
    var panelWidth: CGFloat {
        switch self {
        case .extraSmall: return 180
        case .small: return 230
        case .medium: return 270
        case .large: return 330
        case .extraLarge: return 400
        }
    }
}

/// CleanShot's auto-close interval menu (tags are seconds).
enum OverlayAutoCloseInterval {
    static let choices: [Int] = [5, 10, 15, 30, 60, 120, 300, 600]

    static func label(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
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
        static let snapsSelection = "AOMCaptureSnapSelection"
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
        static let overlayAfterCopyOrSave = "AOMCaptureOverlayAfterCopyOrSave"
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
        static let crosshairMode = "AOMCaptureCrosshairMode"
        static let showsMagnifier = "AOMCaptureShowsMagnifier"
        static let selfTimerInterval = "AOMCaptureSelfTimerInterval"
    }

    /// The capture and recording preferences a profile backup carries
    /// (audit 2026-10-28 F07: "여러 캡처 설정" were missing). What describes
    /// this machine stays out: the save folder and the last selected area.
    static var backedUpKeys: [String] {
        [Key.format, Key.jpegQuality, Key.showsCursor, Key.windowShadow, Key.hidesDesktopIcons, Key.playsSound,
         Key.selfTimerSeconds, Key.selfTimerInterval, Key.pixelSnap, Key.snapsSelection, Key.freezeScreen,
         Key.afterCapture, Key.overlayEnabled, Key.overlayCorner, Key.overlaySize, Key.overlayAutoClose,
         Key.overlayAutoCloseSave, Key.overlayInterval, Key.overlayOnActiveDisplay, Key.overlayCloseAfterDrag,
         Key.overlayAfterCopyOrSave, Key.overlayAsksForName, Key.historyCapacity, Key.recordSystemAudio,
         Key.recordingAudioSource, Key.recordingFPS, Key.recordingQuality, Key.recordingClickIndicators,
         Key.recordingCursorMotion, Key.pinnedShadow, Key.pinnedCorners, Key.pinnedBorder,
         Key.recognizeKeepsLineBreaks, Key.crosshairMode, Key.showsMagnifier,
         // Kept next to the views that own them.
         "AOMCaptureHistoryRetentionDays", "AOMCaptureColorProfile", "AOMCaptureFilenameTemplate",
         "AOMCaptureFilenameUTC", "AOMCaptureGridDensity", "AOMCaptureRecordingOutputFormat",
         "AOMCaptureRecordingGIFFPS", "AOMCaptureRecordingCameraOverlay", "AOMCaptureRecordingCameraBubble",
         "AOMCaptureRecordingKeystrokeOverlay", "AOMCaptureRecordingKeystrokeStyle",
         "AOMCaptureRecordingKeystrokeSize", "AOMCaptureRecordingKeystrokePosition",
         "AOMCaptureRecordingKeystrokeAllKeys", "AOMCaptureRecordingFocus", "AOMCaptureRecordingFocusOn",
         "AOMCaptureRecordingFocusOff", "AOMAnnotationStylePresets", "AOMAnnotationMyColors",
         "AOMAnnotationBackgroundPresets", "AOMAnnotationBackgroundAutoPresetID"] + recording333BackedUpKeys
    }

    /// Never in a backup: they describe this Mac, not the user's choices.
    static let machineSpecificKeys = [Key.saveDirectory, Key.lastArea, Key.lastAreaDisplayID]

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

    /// CleanShot-style smart snapping: an area selection's edges stick to
    /// nearby window and display edges. Hold ⌃ while dragging to place freely.
    static var snapsSelection: Bool {
        get { d.object(forKey: Key.snapsSelection) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.snapsSelection) }
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
        get { OverlayCorner(rawValue: d.string(forKey: Key.overlayCorner) ?? "") ?? .bottomLeft }
        set { d.set(newValue.rawValue, forKey: Key.overlayCorner) }
    }

    static var overlaySize: OverlaySize {
        get { OverlaySize(rawValue: d.string(forKey: Key.overlaySize) ?? "") ?? .small }
        set { d.set(newValue.rawValue, forKey: Key.overlaySize) }
    }

    /// New installs close cards after a delay so captures never pile up on
    /// screen (they stay in Capture History). A stored choice is never
    /// overridden — only the value for people who never picked one changes.
    static let defaultOverlayAutoClose: OverlayAutoClose = .afterInterval
    static let defaultOverlayIntervalSeconds = 300

    static var overlayAutoClose: OverlayAutoClose {
        get { OverlayAutoClose(rawValue: d.string(forKey: Key.overlayAutoClose) ?? "") ?? defaultOverlayAutoClose }
        set { d.set(newValue.rawValue, forKey: Key.overlayAutoClose) }
    }

    /// When After Capture copies or saves, also show the Quick Access card.
    /// Off by default: the copy/save is the feedback (no double overlay).
    static var overlayAfterCopyOrSave: Bool {
        get { d.object(forKey: Key.overlayAfterCopyOrSave) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.overlayAfterCopyOrSave) }
    }

    /// If true, auto-close saves previously unsaved captures first. On a
    /// write failure the overlay remains open for manual recovery.
    /// CleanShot's auto-close "Action" defaults to "Save and Close".
    static var overlayAutoCloseSave: Bool {
        get { d.object(forKey: Key.overlayAutoCloseSave) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.overlayAutoCloseSave) }
    }

    static var overlayIntervalSeconds: Int {
        get { d.object(forKey: Key.overlayInterval) as? Int ?? defaultOverlayIntervalSeconds }
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
        get { recordingAudioSource == .computer || recordingAudioSource == .computerAndMicrophone }
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
            d.set(newValue == .computer || newValue == .computerAndMicrophone, forKey: Key.recordSystemAudio)
        }
    }

    static var recordingCameraOverlay: Bool {
        get { d.bool(forKey: "AOMCaptureRecordingCameraOverlay") }
        set { d.set(newValue, forKey: "AOMCaptureRecordingCameraOverlay") }
    }
    /// CleanShot's live webcam bubble while recording (with Camera Overlay on).
    static var recordingCameraBubble: Bool {
        get { d.object(forKey: "AOMCaptureRecordingCameraBubble") as? Bool ?? true }
        set { d.set(newValue, forKey: "AOMCaptureRecordingCameraBubble") }
    }
    /// CleanShot's keystroke-overlay options for recordings.
    static var recordingKeystrokePosition: KeystrokeOverlayPosition {
        get { KeystrokeOverlayPosition(rawValue: d.string(forKey: "AOMCaptureRecordingKeystrokePosition") ?? "") ?? .bottom }
        set { d.set(newValue.rawValue, forKey: "AOMCaptureRecordingKeystrokePosition") }
    }
    static var recordingKeystrokeSize: KeystrokeOverlaySize {
        get { KeystrokeOverlaySize(rawValue: d.string(forKey: "AOMCaptureRecordingKeystrokeSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "AOMCaptureRecordingKeystrokeSize") }
    }
    static var recordingKeystrokeStyle: AOMKeystrokeStyle {
        get { AOMKeystrokeStyle(rawValue: d.string(forKey: "AOMCaptureRecordingKeystrokeStyle") ?? "") ?? .dark }
        set { d.set(newValue.rawValue, forKey: "AOMCaptureRecordingKeystrokeStyle") }
    }
    /// Off (default): shortcuts and navigation keys only. On: every key,
    /// except while a password field has Secure Input.
    static var recordingKeystrokesAllKeys: Bool {
        get { d.bool(forKey: "AOMCaptureRecordingKeystrokeAllKeys") }
        set { d.set(newValue, forKey: "AOMCaptureRecordingKeystrokeAllKeys") }
    }

    static var recordingKeystrokeOverlay: Bool {
        get { d.bool(forKey: "AOMCaptureRecordingKeystrokeOverlay") }
        set { d.set(newValue, forKey: "AOMCaptureRecordingKeystrokeOverlay") }
    }

    /// CleanShot's "Do Not Disturb while recording". macOS has no public Focus
    /// API, so AOM runs two user-owned Shortcuts (each a single "Set Focus"
    /// action) when a recording starts and when it ends.
    static var recordingFocus: Bool {
        get { d.bool(forKey: "AOMCaptureRecordingFocus") }
        set { d.set(newValue, forKey: "AOMCaptureRecordingFocus") }
    }
    static let defaultRecordingFocusOnShortcut = "AOM Focus On"
    static let defaultRecordingFocusOffShortcut = "AOM Focus Off"
    static var recordingFocusOnShortcut: String {
        get { d.string(forKey: "AOMCaptureRecordingFocusOn").flatMap { $0.isEmpty ? nil : $0 } ?? defaultRecordingFocusOnShortcut }
        set { d.set(newValue, forKey: "AOMCaptureRecordingFocusOn") }
    }
    static var recordingFocusOffShortcut: String {
        get { d.string(forKey: "AOMCaptureRecordingFocusOff").flatMap { $0.isEmpty ? nil : $0 } ?? defaultRecordingFocusOffShortcut }
        set { d.set(newValue, forKey: "AOMCaptureRecordingFocusOff") }
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

    /// Crosshair guides on the area-selection overlay (CleanShot "Crosshair mode").
    static var crosshairMode: CrosshairMode {
        get { CrosshairMode(rawValue: d.string(forKey: Key.crosshairMode) ?? "") ?? .always }
        set { d.set(newValue.rawValue, forKey: Key.crosshairMode) }
    }

    /// Pixel loupe next to the pointer while selecting. Holding Shift still
    /// shows it on demand when this is off (AOM behaviour).
    static var showsMagnifier: Bool {
        get { d.object(forKey: Key.showsMagnifier) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.showsMagnifier) }
    }

    /// Countdown used by the dedicated Self-Timer mode (2/5/10/15 s, default 2).
    /// Independent of `selfTimerSeconds`, which delays *every* capture.
    static var selfTimerInterval: Int {
        get {
            let value = d.integer(forKey: Key.selfTimerInterval)
            return SelfTimerInterval.choices.contains(value) ? value : 2
        }
        set { d.set(SelfTimerInterval.choices.contains(newValue) ? newValue : 2, forKey: Key.selfTimerInterval) }
    }
}

enum SelfTimerInterval {
    static let choices = [2, 5, 10, 15]
}

/// CleanShot "Crosshair mode": Always enabled / When ⌘ Command is pressed / Disabled.
enum CrosshairMode: String, CaseIterable, Identifiable {
    case always, whileCommand, disabled
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: return "Always Enabled"
        case .whileCommand: return "When ⌘ Command Is Pressed"
        case .disabled: return "Disabled"
        }
    }

    func showsCrosshair(commandPressed: Bool) -> Bool {
        switch self {
        case .always: return true
        case .whileCommand: return commandPressed
        case .disabled: return false
        }
    }
}

// MARK: - Capture Text (appended)

extension CaptureSettings {
    /// Capture Text (OCR) preferences — languages, engine, clipboard, HUD,
    /// speech. `ocrKeepsLineBreaks` above and `textCapture.keepsLineBreaks`
    /// share the "AOMOCRKeepsLineBreaks" key.
    static var textCapture: TextCaptureSettings { .shared }
}

/// Where recorded keystrokes appear.
enum KeystrokeOverlayPosition: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var displayName: String { self == .top ? "Top" : "Bottom" }
    /// AOMStudioSettings.keystrokeY (0 top … 1 bottom).
    var studioY: Double { self == .top ? 0.1 : 0.9 }
}

enum KeystrokeOverlaySize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    /// AOMStudioSettings.keystrokeScale.
    var studioScale: Double {
        switch self {
        case .small: return 0.75
        case .medium: return 1
        case .large: return 1.4
        }
    }
}

// MARK: - Recording display options (3.3.3, C06)

/// Modifier keys that make a key press a shortcut worth showing. ⇧ is off by
/// default: with it, Shift-typed capitals and symbols count as shortcuts.
enum KeystrokeShortcutModifier: String, CaseIterable, Identifiable {
    case command, control, option, shift
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        }
    }
    var displayName: String { "\(symbol) \(rawValue.capitalized)" }
    /// What AOM showed before 3.3.3.
    static let defaultSet: Set<KeystrokeShortcutModifier> = [.command, .control, .option]

    /// Stored as a comma-separated list of raw values, e.g. "command,option".
    static func parse(_ text: String?) -> Set<KeystrokeShortcutModifier> {
        guard let text else { return defaultSet }
        return Set(text.split(separator: ",").compactMap { KeystrokeShortcutModifier(rawValue: String($0).trimmingCharacters(in: .whitespaces)) })
    }
    static func serialize(_ set: Set<KeystrokeShortcutModifier>) -> String {
        allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

extension CaptureSettings {
    enum RecordingKey {
        static let showsCursor = "AOMCaptureRecordingShowsCursor"
        static let cursorSize = "AOMCaptureRecordingCursorSize"
        static let cursorHighlight = "AOMCaptureRecordingCursorHighlight"
        static let cursorHighlightColor = "AOMCaptureRecordingCursorHighlightColor"
        static let cursorHighlightSize = "AOMCaptureRecordingCursorHighlightSize"
        static let clickStyle = "AOMCaptureRecordingClickStyle"
        static let clickColor = "AOMCaptureRecordingClickColor"
        static let rightClickColor = "AOMCaptureRecordingRightClickColor"
        static let clickSize = "AOMCaptureRecordingClickSize"
        static let clickDuration = "AOMCaptureRecordingClickDuration"
        static let keystrokeModifiers = "AOMCaptureRecordingKeystrokeModifiers"
    }

    /// The 3.3.3 recording keys a profile backup carries.
    static var recording333BackedUpKeys: [String] {
        [RecordingKey.showsCursor, RecordingKey.cursorSize, RecordingKey.cursorHighlight, RecordingKey.cursorHighlightColor,
         RecordingKey.cursorHighlightSize, RecordingKey.clickStyle, RecordingKey.clickColor, RecordingKey.rightClickColor,
         RecordingKey.clickSize, RecordingKey.clickDuration, RecordingKey.keystrokeModifiers]
    }

    private static func clamped(_ key: String, _ range: ClosedRange<Double>, default value: Double) -> Double {
        guard let stored = d.object(forKey: key) as? Double, stored.isFinite else { return value }
        return min(range.upperBound, max(range.lowerBound, stored))
    }
    private static func color(_ key: String, default value: AOMRGBAColor) -> AOMRGBAColor {
        d.string(forKey: key).flatMap(AOMRGBAColor.init(hex:)) ?? value
    }

    /// The user's explicit "Show Cursor" choice for recordings, nil until set.
    static var recordingShowsCursorChoice: Bool? { d.object(forKey: RecordingKey.showsCursor) as? Bool }

    /// Whether recordings show the pointer. Independent of Show Mouse Clicks
    /// once chosen (audit CS-38: clicks used to force the system pointer on).
    /// Until then the pre-3.3.3 rule applies to the system pointer: the
    /// screenshot Show Cursor option or Show Mouse Clicks.
    static var recordingShowsCursor: Bool {
        get { recordingShowsCursorChoice ?? (showsCursor || recordingClickIndicators) }
        set { d.set(newValue, forKey: RecordingKey.showsCursor) }
    }

    /// Size of the editable pointer drawn from the cursor track (0.5…3).
    static var recordingCursorSize: Double {
        get { clamped(RecordingKey.cursorSize, 0.5...3, default: 1) }
        set { d.set(newValue.isFinite ? min(3, max(0.5, newValue)) : 1, forKey: RecordingKey.cursorSize) }
    }

    /// A halo under the pointer, drawn at export from the cursor track.
    static var recordingCursorHighlight: Bool {
        get { d.bool(forKey: RecordingKey.cursorHighlight) }
        set { d.set(newValue, forKey: RecordingKey.cursorHighlight) }
    }

    static var recordingCursorHighlightStyle: AOMCursorHighlight {
        get {
            AOMCursorHighlight(color: color(RecordingKey.cursorHighlightColor, default: AOMCursorHighlight.defaultColor),
                               size: clamped(RecordingKey.cursorHighlightSize, AOMCursorHighlight.sizeRange, default: 1))
        }
        set {
            d.set(newValue.color.hex, forKey: RecordingKey.cursorHighlightColor)
            d.set(newValue.clampedSize, forKey: RecordingKey.cursorHighlightSize)
        }
    }

    /// Click marks for recordings: shape, left and right colours, size, duration.
    static var recordingClickStyle: AOMClickStyle {
        get {
            AOMClickStyle(shape: AOMClickRingStyle(rawValue: d.string(forKey: RecordingKey.clickStyle) ?? "") ?? .ring,
                          leftColor: color(RecordingKey.clickColor, default: AOMClickStyle.defaultLeftColor),
                          rightColor: color(RecordingKey.rightClickColor, default: AOMClickStyle.defaultRightColor),
                          size: clamped(RecordingKey.clickSize, AOMClickStyle.sizeRange, default: 1),
                          duration: clamped(RecordingKey.clickDuration, AOMClickStyle.durationRange, default: 0.65))
        }
        set {
            d.set(newValue.shape.rawValue, forKey: RecordingKey.clickStyle)
            d.set(newValue.leftColor.hex, forKey: RecordingKey.clickColor)
            d.set(newValue.rightColor.hex, forKey: RecordingKey.rightClickColor)
            d.set(newValue.clampedSize, forKey: RecordingKey.clickSize)
            d.set(newValue.clampedDuration, forKey: RecordingKey.clickDuration)
        }
    }

    /// Which modifiers make a key press count as a shortcut for the keystroke
    /// overlay (default ⌘ ⌃ ⌥, as before 3.3.3).
    static var recordingKeystrokeModifiers: Set<KeystrokeShortcutModifier> {
        get { KeystrokeShortcutModifier.parse(d.string(forKey: RecordingKey.keystrokeModifiers)) }
        set { d.set(KeystrokeShortcutModifier.serialize(newValue), forKey: RecordingKey.keystrokeModifiers) }
    }
}

extension AOMStudioSettings {
    /// What a finished recording's Presentation shows, and where Edit
    /// Recording starts when no Studio project was saved yet.
    static func recordingDefaults(track: AOMCursorTrack?) -> AOMStudioSettings {
        let showsClicks = CaptureSettings.recordingClickIndicators
        var style = AOMStudioSettings(cursorPoints: track?.points ?? [],
                                      clicks: showsClicks ? (track?.clicks ?? []) : [],
                                      keystrokes: track?.keystrokes ?? [])
        style.showClickRipples = showsClicks
        style.clickStyle = CaptureSettings.recordingClickStyle
        style.cursorOverlaySize = CaptureSettings.recordingCursorSize
        // An editable track replaces the pointer; it stays visible unless the
        // user chose to hide it. A track kept only for the highlight never
        // draws a second pointer over the one already in the video.
        let pointerWanted = CaptureSettings.recordingShowsCursorChoice ?? true
        style.cursorStyle = track?.pointerInVideo == true || !pointerWanted ? .hidden : .arrow
        style.cursorHighlight = CaptureSettings.recordingCursorHighlight ? CaptureSettings.recordingCursorHighlightStyle : nil
        style.keystrokeScale = CaptureSettings.recordingKeystrokeSize.studioScale
        style.keystrokeY = CaptureSettings.recordingKeystrokePosition.studioY
        style.keystrokeStyle = CaptureSettings.recordingKeystrokeStyle
        return style
    }
}
