import Foundation

/// Install App from Disk Image (Rapidmg-style, with hdiutil): mount the image
/// read-only and hidden, copy its one app to Applications, eject, and move
/// the image to the Trash. An app that is already installed is replaced
/// only after asking, and the old copy goes to the Trash. A license
/// agreement or a password is left to Finder, never accepted for the user.
/// The parsers and the plan are pure; the tests never mount anything.
enum FolderRulesDiskImageInstaller {
    struct ImageInfo: Equatable {
        var hasLicenseAgreement: Bool
        var isEncrypted: Bool
    }

    /// `hdiutil imageinfo -plist`: Properties › Software License Agreement and Encrypted.
    static func parseImageInfo(_ data: Data) -> ImageInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let properties = plist["Properties"] as? [String: Any] ?? [:]
        func flag(_ key: String) -> Bool {
            if let value = properties[key] as? Bool { return value }
            if let value = properties[key] as? NSNumber { return value.boolValue }
            if let value = properties[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
            return false
        }
        return ImageInfo(hasLicenseAgreement: flag("Software License Agreement"), isEncrypted: flag("Encrypted"))
    }

    struct Attachment: Equatable {
        /// Where each volume mounted.
        var mountPoints: [URL]
        /// The image's own device (/dev/disk11), shortest first.
        var devices: [String]
    }

    /// `hdiutil attach -plist`: every system entity's mount point and device.
    static func parseAttach(_ data: Data) -> Attachment? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let mounts = entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let devices = entities.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }
        return Attachment(mountPoints: mounts, devices: devices)
    }

    /// Apps at the top of a mounted volume. Links (the usual "Applications"
    /// shortcut) are not apps.
    static func apps(inVolume volume: URL) -> [URL] {
        items(inVolume: volume) { $0.pathExtension.lowercased() == "app" }
    }

    static func installerPackages(inVolume volume: URL) -> [URL] {
        items(inVolume: volume) { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
    }

    private static func items(inVolume volume: URL, where accept: (URL) -> Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isAliasFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries.filter { entry in
            guard accept(entry), let values = try? entry.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isSymbolicLink != true && values.isAliasFile != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    enum Plan: Equatable {
        /// Copy `app` to `destination`; `existing` is the installed copy, if any.
        case install(app: URL, destination: URL, existing: URL?)
        /// Nothing to install: no app, or several and nobody chose.
        case skip(String)
    }

    /// Which app goes where. `chosen` is the app the person picked when the
    /// image holds several (the manual install asks; rules never guess).
    static func plan(imageName: String, apps: [URL], packages: [URL], chosen: URL?, applicationsFolder: URL,
                     exists: (URL) -> Bool) -> Plan {
        let app: URL
        if apps.count == 1, let only = apps.first {
            app = only
        } else if apps.count > 1 {
            guard let chosen, apps.contains(chosen) else {
                return .skip("Skipped: “\(imageName)” holds \(apps.count) apps. Open it to choose one.")
            }
            app = chosen
        } else if let package = packages.first {
            return .skip("Skipped: no app inside “\(imageName)”; it has the installer “\(package.lastPathComponent)”. Open it to install.")
        } else {
            return .skip("Skipped: no app inside “\(imageName)”.")
        }
        let destination = applicationsFolder.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        return .install(app: app, destination: destination, existing: exists(destination) ? destination : nil)
    }

    /// Mounts, installs, ejects and trashes the image. Runs on the engine's
    /// queue; questions go to the main thread through the environment.
    static func install(_ image: URL, options: FolderRuleInstallOptions, environment: FolderRulesEnvironment,
                        interactive: Bool) throws -> FolderRuleExecutor.Step {
        func step(_ result: FolderRuleStepRecord.Result, _ summary: String, next: URL?, undo: FolderRuleUndo? = nil,
                  produced: URL? = nil) -> FolderRuleExecutor.Step {
            FolderRuleExecutor.Step(record: FolderRuleStepRecord(action: .installApp, result: result, summary: summary, undo: undo),
                                    next: next, produced: produced)
        }
        let name = image.lastPathComponent
        let infoRequest = FolderRulesProcess.Request("/usr/bin/hdiutil", ["imageinfo", "-plist", image.path], timeout: 60)
        let infoResult = environment.run(infoRequest)
        if infoResult.succeeded, let info = parseImageInfo(infoResult.stdout) {
            if info.hasLicenseAgreement {
                return step(.skipped, "Skipped: “\(name)” has a license agreement. Open it in Finder to read and accept it.", next: image)
            }
            if info.isEncrypted {
                return step(.skipped, "Skipped: “\(name)” is password-protected. Open it in Finder to enter the password.", next: image)
            }
        }

        let fileManager = FileManager.default
        let mountRoot = fileManager.temporaryDirectory.appendingPathComponent("AOMFolderRules-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attachRequest = FolderRulesProcess.Request("/usr/bin/hdiutil",
                                                       ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen",
                                                        "-mountrandom", mountRoot.path, "-plist"], timeout: 600)
        let attachResult = environment.run(attachRequest)
        guard attachResult.succeeded, let attachment = parseAttach(attachResult.stdout), !attachment.mountPoints.isEmpty else {
            if let attachment = parseAttach(attachResult.stdout) { detach(attachment, environment: environment) }
            rmdir(mountRoot.path)
            throw FolderRuleFailure("Couldn't open “\(name)”: \(attachResult.failure(attachRequest))")
        }
        var detached = false
        func finishMount() -> String? {
            guard !detached else { return nil }
            detached = true
            let problem = detach(attachment, environment: environment)
            rmdir(mountRoot.path)
            return problem
        }
        defer { _ = finishMount() }

        let apps = attachment.mountPoints.flatMap(apps(inVolume:))
        let packages = attachment.mountPoints.flatMap(installerPackages(inVolume:))
        let chosen = apps.count > 1 && interactive ? environment.chooseApp(apps) : nil
        if apps.count > 1, interactive, chosen == nil {
            return step(.skipped, "Cancelled: no app chosen from “\(name)”.", next: image)
        }
        let made = plan(imageName: name, apps: apps, packages: packages, chosen: chosen,
                        applicationsFolder: environment.applicationsFolder, exists: { FolderRulesSafety.exists($0.path) })
        guard case .install(let app, var destination, let existing) = made else {
            if case .skip(let reason) = made { return step(.skipped, reason, next: image) }
            return step(.skipped, "Skipped: nothing to install.", next: image)
        }
        let appName = app.deletingPathExtension().lastPathComponent
        var replaced: URL?
        if let existing {
            if environment.isAppRunning(existing) {
                throw FolderRuleFailure("“\(appName)” is open. Quit it, then install again.")
            }
            switch environment.confirmReplace(appName) {
            case .cancel:
                return step(.skipped, "Kept the installed “\(appName)”.", next: image)
            case .keepBoth:
                destination = FolderRulePatterns.uniqueURL(destination) { FolderRulesSafety.exists($0.path) }
            case .replace:
                replaced = existing
            }
        }

        let folder = environment.applicationsFolder
        if fileManager.isWritableFile(atPath: folder.path) {
            let staging = folder.appendingPathComponent(".\(app.lastPathComponent).aom-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let copy = FolderRulesProcess.Request("/usr/bin/ditto", [app.path, staging.path], timeout: 900)
            let copied = environment.run(copy)
            guard copied.succeeded else {
                if FolderRulesSafety.exists(staging.path) { try? fileManager.removeItem(at: staging) }
                throw FolderRuleFailure("Couldn't copy “\(appName)” to \(FolderRulesSafety.display(folder)): \(copied.failure(copy))")
            }
            var trashedOld: URL?
            if let replaced {
                do {
                    trashedOld = try environment.trash(replaced)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw FolderRuleFailure("Couldn't move the installed “\(appName)” to the Trash, so nothing changed. \(FolderRuleFailure.wrapping(error, "").message)")
                }
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                if let trashedOld { try? fileManager.moveItem(at: trashedOld, to: destination) }
                try? fileManager.removeItem(at: staging)
                throw FolderRuleFailure.wrapping(error, "Couldn't finish installing “\(appName)”.")
            }
        } else {
            guard replaced == nil else {
                throw FolderRuleFailure("You can't change apps in \(FolderRulesSafety.display(folder)) without an administrator. Move the old “\(appName)” to the Trash in Finder, then install again.")
            }
            if let failure = environment.copyAsAdministrator(app, destination) { throw failure }
        }

        var summary = "Installed “\(destination.deletingPathExtension().lastPathComponent)” in \(FolderRulesSafety.display(folder))"
        if replaced != nil { summary += "; the old copy is in the Trash" }
        if let problem = finishMount() { summary += ". \(problem)" }
        var next: URL? = image
        var undo: FolderRuleUndo?
        if options.trashDiskImage {
            if let place = try? environment.trash(image) {
                next = nil
                undo = .moveBack(current: place.path, original: image.path)
                summary += "; the disk image is in the Trash"
            } else {
                summary += "; the disk image couldn't go to the Trash"
            }
        }
        if options.openAfterInstall { _ = environment.open(destination, nil) }
        return step(.done, summary, next: next, undo: undo, produced: destination)
    }

    /// Ejects every volume of the image: the normal way first, `-force`
    /// only if that failed. Returns a note when the image stayed attached.
    @discardableResult
    static func detach(_ attachment: Attachment, environment: FolderRulesEnvironment) -> String? {
        let target = attachment.mountPoints.first?.path ?? attachment.devices.first
        guard let target else { return nil }
        let normal = environment.run(FolderRulesProcess.Request("/usr/bin/hdiutil", ["detach", target], timeout: 60))
        if normal.succeeded { return nil }
        let forced = environment.run(FolderRulesProcess.Request("/usr/bin/hdiutil", ["detach", target, "-force"], timeout: 60))
        return forced.succeeded ? nil : "The disk image is still mounted; eject it in Finder."
    }
}
