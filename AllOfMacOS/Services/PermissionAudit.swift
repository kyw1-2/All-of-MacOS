import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid
import SwiftUI

/// The public APIs expose four permission states. Other TCC grants are
/// scoped to a target app or individual file and cannot be reliably aggregated.
enum AOMPermission: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording, microphone
    case automation, filesAndFolders, clipboard, fullDiskAccess

    var id: String { rawValue }
    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .automation: "Automation"
        case .filesAndFolders: "Files & Folders"
        case .clipboard: "Pasteboard"
        case .fullDiskAccess: "Full Disk Access"
        }
    }
    var explanation: String {
        switch self {
        case .accessibility: "Move windows, send keys and run gesture actions"
        case .inputMonitoring: "Detect global key combinations and key sequences"
        case .screenRecording: "Capture screens, windows and recordings"
        case .microphone: "Record sound when Microphone is selected"
        case .automation: "Optional AppleScript control of other applications"
        case .filesAndFolders: "Protected folders used as save destinations"
        case .clipboard: "macOS may request consent when accessing pasted data"
        case .fullDiskAccess: "Optional for protected files used by advanced custom actions"
        }
    }
    var icon: String {
        switch self {
        case .accessibility: "figure.stand"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "record.circle"
        case .microphone: "mic.fill"
        case .automation: "gearshape.2.fill"
        case .filesAndFolders: "folder.fill"
        case .clipboard: "doc.on.clipboard"
        case .fullDiskAccess: "externaldrive.fill"
        }
    }
    var essential: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording: true
        case .microphone: CaptureSettings.recordingAudioSource == .microphone
        default: false
        }
    }
    var status: AOMPermissionStatus {
        switch self {
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            // Checks event-listening capability, not existence of a Settings row.
            // Accessibility can also cause macOS to return Granted here.
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .notDetermined
            }
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .notDetermined
            }
        case .automation, .filesAndFolders, .clipboard, .fullDiskAccess:
            .manualReview
        }
    }
    static func screenPane(major: Int) -> String {
        major >= 26 ? "Privacy_AudioCapture" : "Privacy_ScreenCapture"
    }
    var paneName: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: Self.screenPane(major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        case .microphone: "Privacy_Microphone"
        case .automation: "Privacy_Automation"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .clipboard: "Privacy_Pasteboard"
        case .fullDiskAccess: "Privacy_AllFiles"
        }
    }
    var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(paneName)")!
    }
    static var required: [Self] { allCases.filter(\.essential) }
    static var optional: [Self] {
        allCases.filter { !$0.essential &&
            ($0 != .clipboard || ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15)
        }
    }
    func openSettings() -> Bool {
        if NSWorkspace.shared.open(systemSettingsURL) { return true }
        return NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
    }
}

enum AOMPermissionStatus: Equatable {
    case granted, denied, notDetermined, manualReview
    var label: String {
        switch self {
        case .granted: "Available"
        case .denied: "Needs Setup"
        case .notDetermined: "Not Requested"
        case .manualReview: "Check Manually"
        }
    }
    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.circle.fill"
        case .notDetermined: "questionmark.circle"
        case .manualReview: "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .granted: .green
        case .denied: .orange
        case .notDetermined, .manualReview: .secondary
        }
    }
}
