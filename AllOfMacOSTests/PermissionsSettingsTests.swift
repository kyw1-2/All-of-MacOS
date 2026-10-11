import XCTest
@testable import AllOfMacOS

@MainActor
final class PermissionsSettingsTests: XCTestCase {
    func testSystemSettingsDeepLinksMatchSupportedMacOSVersions() {
        XCTAssertEqual(AOMPermission.screenPane(major: 14), "Privacy_ScreenCapture")
        XCTAssertEqual(AOMPermission.screenPane(major: 15), "Privacy_ScreenCapture")
        XCTAssertEqual(AOMPermission.screenPane(major: 26), "Privacy_AudioCapture")
        XCTAssertEqual(AOMPermission.screenPane(major: 27), "Privacy_AudioCapture")

        let urls = AOMPermission.allCases.map(\.systemSettingsURL)
        XCTAssertEqual(Set(urls).count, AOMPermission.allCases.count)
        for url in urls {
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            XCTAssertTrue(url.absoluteString.contains("Privacy_"))
        }
    }

    func testOptionalPerTargetPermissionsNeverClaimGloballyGranted() {
        XCTAssertEqual(AOMPermission.automation.status, .manualReview)
        XCTAssertEqual(AOMPermission.filesAndFolders.status, .manualReview)
        XCTAssertEqual(AOMPermission.clipboard.status, .manualReview)
        XCTAssertEqual(AOMPermission.fullDiskAccess.status, .manualReview)
    }

    func testRequiredPermissionsIncludeMicrophoneOnlyWhenSelected() {
        let old = CaptureSettings.recordingAudioSource
        defer { CaptureSettings.recordingAudioSource = old }
        CaptureSettings.recordingAudioSource = .off
        XCTAssertEqual(Set(AOMPermission.required), Set([
            .accessibility, .inputMonitoring, .screenRecording
        ]))
        CaptureSettings.recordingAudioSource = .microphone
        XCTAssertTrue(AOMPermission.required.contains(.microphone))
        XCTAssertEqual(AOMPermission.required.count, 4)
        CaptureSettings.recordingAudioSource = .computer
        XCTAssertFalse(AOMPermission.required.contains(.microphone))
    }

    func testPermissionLabelsHaveDistinctAccessibleDestinations() {
        XCTAssertEqual(Set(AOMPermission.allCases.map(\.id)).count, 8)
        XCTAssertTrue(AOMPermission.allCases.allSatisfy {
            !$0.title.isEmpty && !$0.explanation.isEmpty && !$0.icon.isEmpty
        })
        XCTAssertEqual(AOMPermissionStatus.granted.label, "Available")
        XCTAssertEqual(AOMPermissionStatus.denied.label, "Needs Setup")
        XCTAssertEqual(AOMPermissionStatus.manualReview.label, "Check Manually")
    }
}
