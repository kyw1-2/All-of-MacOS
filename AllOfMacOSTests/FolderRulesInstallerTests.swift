import Foundation
import XCTest
@testable import AllOfMacOS

/// Install App from Disk Image: the hdiutil parsers (fixtures captured from
/// hdiutil on this Mac), app discovery and the install plan. Nothing is ever
/// mounted: hdiutil is answered by a stub that points at a temporary folder
/// standing in for the mounted volume.
final class FolderRulesInstallerTests: XCTestCase {
    private var kit: FolderRulesTestKit!

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    /// `hdiutil attach … -plist` for an APFS image (the shape recorded on macOS 27.2).
    private func attachPlist(mountPoint: String) -> Data {
        let plist: [String: Any] = ["system-entities": [
            ["content-hint": "Apple_APFS", "dev-entry": "/dev/disk11s1", "potentially-mountable": false],
            ["content-hint": "GUID_partition_scheme", "dev-entry": "/dev/disk11", "potentially-mountable": false],
            ["content-hint": "41504653-0000-11AA-AA11-00306543ECAC", "dev-entry": "/dev/disk12s1", "mount-point": mountPoint,
             "potentially-mountable": true, "volume-kind": "apfs"],
            ["content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC", "dev-entry": "/dev/disk12", "potentially-mountable": false]
        ]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func imageInfo(license: Bool, encrypted: Bool) -> Data {
        let plist: [String: Any] = ["Format": "UDZO", "Properties": ["Checksummed": true, "Compressed": "yes", "Encrypted": encrypted,
                                                                     "Kernel Compatible": true, "Partitioned": false,
                                                                     "Software License Agreement": license]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func testParsersReadImageInfoAndAttachOutput() throws {
        XCTAssertEqual(FolderRulesDiskImageInstaller.parseImageInfo(imageInfo(license: true, encrypted: false)),
                       .init(hasLicenseAgreement: true, isEncrypted: false))
        XCTAssertEqual(FolderRulesDiskImageInstaller.parseImageInfo(imageInfo(license: false, encrypted: true)),
                       .init(hasLicenseAgreement: false, isEncrypted: true))
        XCTAssertNil(FolderRulesDiskImageInstaller.parseImageInfo(Data("garbage".utf8)))
        let attachment = try XCTUnwrap(FolderRulesDiskImageInstaller.parseAttach(attachPlist(mountPoint: "/private/tmp/mnt/dmg.Ee6PoC")))
        XCTAssertEqual(attachment.mountPoints.map(\.path), ["/private/tmp/mnt/dmg.Ee6PoC"])
        XCTAssertEqual(attachment.devices.first, "/dev/disk11", "the image's own device first")
        XCTAssertNil(FolderRulesDiskImageInstaller.parseAttach(Data()))
    }

    func testTheRecordedAttachOutputParses() throws {
        // The plist hdiutil printed for a probe image on this Mac (aom-335-kit/c-340-evidence).
        let recorded = URL(fileURLWithPath: "/Users/kim-yong-woo/aom-335-kit/c-340-evidence/hdiutil-attach-apfs.plist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: recorded.path), "evidence file not on this machine")
        let attachment = try XCTUnwrap(FolderRulesDiskImageInstaller.parseAttach(try Data(contentsOf: recorded)))
        XCTAssertEqual(attachment.mountPoints.count, 1)
        XCTAssertTrue(attachment.mountPoints[0].path.contains("/aom-c-probe/mnt/dmg."))
        XCTAssertEqual(attachment.devices.first, "/dev/disk11")
    }

    func testAppsAreFoundAtTheTopOfTheVolumeAndLinksAreIgnored() throws {
        let volume = try makeVolume(apps: ["Ice.app"], package: "Extras.pkg")
        XCTAssertEqual(FolderRulesDiskImageInstaller.apps(inVolume: volume).map(\.lastPathComponent), ["Ice.app"])
        XCTAssertEqual(FolderRulesDiskImageInstaller.installerPackages(inVolume: volume).map(\.lastPathComponent), ["Extras.pkg"])
    }

    func testThePlanNeverGuesses() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let one = [URL(fileURLWithPath: "/Volumes/Ice/Ice.app")]
        XCTAssertEqual(FolderRulesDiskImageInstaller.plan(imageName: "Ice.dmg", apps: one, packages: [], chosen: nil,
                                                          applicationsFolder: applications, exists: { _ in false }),
                       .install(app: one[0], destination: applications.appendingPathComponent("Ice.app", isDirectory: true), existing: nil))
        if case .install(_, _, let existing) = FolderRulesDiskImageInstaller.plan(imageName: "Ice.dmg", apps: one, packages: [], chosen: nil,
                                                                                  applicationsFolder: applications, exists: { _ in true }) {
            XCTAssertNotNil(existing, "an installed copy is reported, so the person is asked")
        } else { XCTFail("installs") }
        let two = one + [URL(fileURLWithPath: "/Volumes/Ice/Ice Helper.app")]
        guard case .skip(let reason) = FolderRulesDiskImageInstaller.plan(imageName: "Ice.dmg", apps: two, packages: [], chosen: nil,
                                                                          applicationsFolder: applications, exists: { _ in false }) else {
            return XCTFail("two apps: skip")
        }
        XCTAssertTrue(reason.contains("holds 2 apps"))
        XCTAssertEqual(FolderRulesDiskImageInstaller.plan(imageName: "Ice.dmg", apps: two, packages: [], chosen: two[1],
                                                          applicationsFolder: applications, exists: { _ in false }),
                       .install(app: two[1], destination: applications.appendingPathComponent("Ice Helper.app", isDirectory: true), existing: nil))
        guard case .skip(let none) = FolderRulesDiskImageInstaller.plan(imageName: "Zoom.dmg", apps: [],
                                                                        packages: [URL(fileURLWithPath: "/Volumes/Zoom/Zoom.pkg")], chosen: nil,
                                                                        applicationsFolder: applications, exists: { _ in false }) else {
            return XCTFail("no app: skip")
        }
        XCTAssertTrue(none.contains("no app inside") && none.contains("Zoom.pkg"))
    }

    func testAnInstallCopiesTheAppEjectsAndTrashesTheImageWithoutMounting() throws {
        let volume = try makeVolume(apps: ["Ice.app"])
        let applications = try kit.folder("Applications")
        let image = try kit.writeSettled("Ice.dmg", Data(repeating: 0, count: 512))
        var calls: [String] = []
        let environment = kit.environment(run: { request in
            calls.append(([request.name] + request.arguments.prefix(1)).joined(separator: " "))
            return self.answer(request, volume: volume)
        }, applications: applications)
        let step = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: environment,
                                                             interactive: false)
        XCTAssertEqual(step.record.result, .done, step.record.summary)
        XCTAssertEqual(kit.names(in: applications), ["Ice.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Ice.app/Contents/Info.plist").path))
        XCTAssertEqual(kit.names(), [], "the disk image went to the Trash")
        XCTAssertEqual(kit.names(in: kit.trash), ["Ice.dmg"])
        // The app as the installer found it on the "mounted" volume (paths come back resolved: /private/var/…).
        let app = try XCTUnwrap(FolderRulesDiskImageInstaller.apps(inVolume: volume).first)
        XCTAssertEqual(calls, ["hdiutil imageinfo", "hdiutil attach", "ditto " + app.path, "hdiutil detach"])
        let attach = try XCTUnwrap(kit.requests.first { $0.arguments.first == "attach" })
        XCTAssertTrue(attach.arguments.contains("-readonly") && attach.arguments.contains("-nobrowse") && attach.arguments.contains("-noautoopen"))
        XCTAssertFalse(kit.requests.contains { $0.arguments.contains("-force") }, "no -force when the normal eject worked")
        XCTAssertTrue(step.record.canUndo, "the image can come back from the Trash")
    }

    func testReplacingAsksAndKeepsTheOldAppInTheTrash() throws {
        let volume = try makeVolume(apps: ["Ice.app"])
        let applications = try kit.folder("Applications")
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("Ice.app/Contents", isDirectory: true),
                                                withIntermediateDirectories: true)
        try writeBundleMetadata(for: applications.appendingPathComponent("Ice.app"))
        try Data("old".utf8).write(to: applications.appendingPathComponent("Ice.app/Contents/old.txt"))
        let image = try kit.writeSettled("Ice.dmg", Data(repeating: 0, count: 512))
        var asked: [String] = []
        // Cancel first: nothing changes and the image stays.
        var environment = kit.environment(run: { self.answer($0, volume: volume) }, confirmReplace: { name in asked.append(name); return .cancel },
                                          applications: applications)
        var step = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: environment, interactive: false)
        XCTAssertEqual(step.record.result, .skipped)
        XCTAssertEqual(asked, ["Ice"])
        XCTAssertEqual(kit.names(), ["Ice.dmg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Ice.app/Contents/old.txt").path))
        // Keep Both: "Ice 2.app" beside the old one.
        environment.confirmReplace = { _ in .keepBoth }
        step = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(trashDiskImage: false), environment: environment,
                                                         interactive: false)
        XCTAssertEqual(kit.names(in: applications), ["Ice 2.app", "Ice.app"])
        // Replace: the old copy goes to the Trash.
        environment.confirmReplace = { _ in .replace }
        step = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: environment, interactive: false)
        XCTAssertEqual(step.record.result, .done, step.record.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Ice.app/Contents/old.txt").path))
        XCTAssertTrue(kit.names(in: kit.trash).contains("Ice.app"), "the old app is in the Trash")
        XCTAssertTrue(step.record.summary.contains("the old copy is in the Trash"))
    }

    func testSameNameDifferentBundleIsNeverReplaced() throws {
        let volume = try makeVolume(apps: ["Ice.app"])
        let applications = try kit.folder("Applications")
        let existing = applications.appendingPathComponent("Ice.app")
        try writeBundleMetadata(for: existing, bundleID: "org.other.publisher")
        let image = try kit.writeSettled("Ice.dmg", Data(repeating: 0, count: 512))
        var asked = false
        let environment = kit.environment(run: { self.answer($0, volume: volume) },
            confirmReplace: { _ in asked = true; return .replace }, applications: applications)
        let step = try FolderRulesDiskImageInstaller.install(image,
            options: FolderRuleInstallOptions(trashDiskImage: true),
            environment: environment, interactive: false)
        XCTAssertEqual(step.record.result, .skipped)
        XCTAssertFalse(asked)
        XCTAssertEqual(Bundle(url: existing)?.bundleIdentifier, "org.other.publisher")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "source DMG remains")
    }

    func testARunningAppALicenseOrAFailedAttachStopsTheInstall() throws {
        let volume = try makeVolume(apps: ["Ice.app"])
        let applications = try kit.folder("Applications")
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("Ice.app", isDirectory: true), withIntermediateDirectories: true)
        try writeBundleMetadata(for: applications.appendingPathComponent("Ice.app"))
        let image = try kit.writeSettled("Ice.dmg", Data(repeating: 0, count: 512))
        var environment = kit.environment(run: { self.answer($0, volume: volume) }, confirmReplace: { _ in .replace }, applications: applications)
        environment.isAppRunning = { _ in true }
        XCTAssertThrowsError(try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: environment,
                                                                       interactive: false)) { error in
            XCTAssertTrue((error as? FolderRuleFailure)?.message.contains("is open") == true)
        }
        XCTAssertTrue(kit.requests.contains { $0.arguments.first == "detach" }, "ejected even when it stops")

        let licensed = kit.environment(run: { request in
            request.arguments.first == "imageinfo"
                ? FolderRulesProcess.Result(status: 0, stdout: self.imageInfo(license: true, encrypted: false), stderr: "")
                : self.answer(request, volume: volume)
        }, applications: applications)
        let skipped = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: licensed, interactive: false)
        XCTAssertEqual(skipped.record.result, .skipped)
        XCTAssertTrue(skipped.record.summary.contains("license agreement"), "never accepted for the person")

        let broken = kit.environment(run: { request in
            request.arguments.first == "attach"
                ? FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: "hdiutil: attach failed - image not recognized")
                : self.answer(request, volume: volume)
        }, applications: applications)
        XCTAssertThrowsError(try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: broken,
                                                                       interactive: false)) { error in
            XCTAssertTrue((error as? FolderRuleFailure)?.message.contains("image not recognized") == true)
        }
        XCTAssertEqual(kit.names(), ["Ice.dmg"], "the image stays when nothing was installed")
    }

    func testANormalEjectFailureFallsBackToForce() throws {
        let volume = try makeVolume(apps: [])
        let image = try kit.writeSettled("Empty.dmg", Data(repeating: 0, count: 512))
        let environment = kit.environment(run: { request in
            if request.arguments.first == "detach", !request.arguments.contains("-force") {
                return FolderRulesProcess.Result(status: 16, stdout: Data(), stderr: "hdiutil: couldn't eject disk11 - Resource busy")
            }
            return self.answer(request, volume: volume)
        })
        let step = try FolderRulesDiskImageInstaller.install(image, options: FolderRuleInstallOptions(), environment: environment, interactive: false)
        XCTAssertEqual(step.record.result, .skipped)
        XCTAssertTrue(step.record.summary.contains("no app inside"))
        XCTAssertEqual(kit.requests.filter { $0.arguments.first == "detach" }.map { $0.arguments.contains("-force") }, [false, true])
    }

    // MARK: Helpers

    /// A folder laid out like a mounted app disk image: the apps, an
    /// "Applications" link, and optionally an installer package.
    private func makeVolume(apps: [String], package: String? = nil) throws -> URL {
        let volume = try kit.folder("Volume-\(UUID().uuidString.prefix(6))")
        for app in apps {
            let contents = volume.appendingPathComponent("\(app)/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try writeBundleMetadata(for: volume.appendingPathComponent(app))
        }
        try FileManager.default.createSymbolicLink(at: volume.appendingPathComponent("Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        if let package { try Data("xar!".utf8).write(to: volume.appendingPathComponent(package)) }
        return volume
    }

    private func writeBundleMetadata(for app: URL, bundleID: String? = nil) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let id = bundleID ?? "test.aom.\(app.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: ""))"
        let info = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "test"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Stands in for hdiutil (never run in tests) and copies for ditto.
    private func answer(_ request: FolderRulesProcess.Request, volume: URL) -> FolderRulesProcess.Result {
        switch (request.name, request.arguments.first) {
        case ("hdiutil", "imageinfo"):
            return FolderRulesProcess.Result(status: 0, stdout: imageInfo(license: false, encrypted: false), stderr: "")
        case ("hdiutil", "attach"):
            return FolderRulesProcess.Result(status: 0, stdout: attachPlist(mountPoint: volume.path),
                                             stderr: "hdiutil: WARNING: 'hdiutil attach' is deprecated.")
        case ("hdiutil", "detach"):
            return FolderRulesProcess.Result(status: 0, stdout: Data(), stderr: "")
        case ("ditto", _):
            guard request.arguments.count == 2 else { return FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: "bad") }
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: request.arguments[0]), to: URL(fileURLWithPath: request.arguments[1]))
                return FolderRulesProcess.Result(status: 0, stdout: Data(), stderr: "")
            } catch {
                return FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: error.localizedDescription)
            }
        default:
            return FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: "unexpected \(request.name)")
        }
    }
}
