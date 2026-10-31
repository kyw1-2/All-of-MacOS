import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Sample folders, rules and activity for isolated UI previews, only with
/// `--aom-preview-folder-rules-sample`. Everything lives in the preview's
/// own data folder; the user's folders are never read.
///
///     --aom-preview-folder-rules-sample            sample folders, rules and activity
///     --aom-preview-folder-rules-select <name>     select the rule, folder or "activity"
///     --aom-preview-folder-rules-turn-on           show the preview before turning the rule on
///     --aom-preview-folder-rules-approval          show the floating approval card
@MainActor
enum FolderRulesPreviewSamples {
    private static var prepared = false

    static func prepare(engine: FolderRulesEngine, model: FolderRulesPageModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, arguments.contains("--aom-preview-folder-rules-sample"), !prepared,
              let root = FolderRulesLocations.sampleRoot else { return }
        prepared = true
        let downloads = FolderRulesLocations.downloads
        let desktop = FolderRulesLocations.desktop
        _ = FolderRulesLocations.documents
        _ = FolderRulesLocations.pictures
        writeSamples(downloads: downloads, desktop: desktop)
        engine.loadPreviewSample(root: root, downloads: downloads, desktop: desktop)
        if let index = arguments.firstIndex(of: "--aom-preview-folder-rules-select"), arguments.indices.contains(index + 1) {
            let name = arguments[index + 1]
            if name == "activity" {
                model.selection = .activity
            } else if let rule = engine.config.rules.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                model.selection = .rule(rule.id)
            } else if let folder = engine.config.folders.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                model.selection = .folder(folder.id)
            }
        }
        if arguments.contains("--aom-preview-folder-rules-turn-on") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.setEnabled(true) }
        }
        if arguments.contains("--aom-preview-folder-rules-approval") {
            FolderRulesApprovalPanel.shared.observe(engine)
        }
    }

    private static func writeSamples(downloads: URL, desktop: URL) {
        let fileManager = FileManager.default
        // Written an hour "ago", so the samples count as settled files.
        let settled = Date().addingTimeInterval(-3_600)
        func write(_ name: String, in folder: URL, _ data: Data) -> URL {
            let url = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                try? data.write(to: url)
                try? fileManager.setAttributes([.modificationDate: settled], ofItemAtPath: url.path)
            }
            return url
        }
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        _ = write("Invoice-2026-10.pdf", in: downloads, pdf)
        _ = write("쿠팡 영수증.pdf", in: downloads, pdf)
        _ = write("Lecture notes week 9.pdf", in: downloads, pdf)
        _ = write("Rapidmg-1.3.1.dmg", in: downloads, Data(repeating: 0, count: 4_096))
        _ = write("dataset.zip", in: downloads, Data("PK\u{05}\u{06}".utf8) + Data(repeating: 0, count: 18))
        _ = write("Movie trailer.mp4.crdownload", in: downloads, Data(repeating: 1, count: 2_048))
        for (index, name) in ["Screenshot 2026-10-31 at 10.12.03.png", "Screenshot 2026-10-31 at 14.40.51.png"].enumerated() {
            let url = desktop.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            writePNG(to: url, width: 1440 + index * 160, height: 900)
            try? fileManager.setAttributes([.modificationDate: settled], ofItemAtPath: url.path)
            let flag = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            if let flag { FolderRuleMetadata.setAttribute(FolderRuleMetadata.screenCaptureAttribute, flag, at: url.path) }
        }
        _ = write("Project plan.key", in: desktop, Data(repeating: 2, count: 1_024))
    }

    private static func writePNG(to url: URL, width: Int, height: Int) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 0.18, green: 0.59, blue: 0.29, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: width / 8, y: height / 6, width: width * 3 / 4, height: height * 2 / 3))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

extension FolderRulesEngine {
    /// Replaces the preview's rules and activity with the samples. Previews only.
    func loadPreviewSample(root: URL, downloads: URL, desktop: URL) {
        guard PresetManager.isUIPreview else { return }
        let downloadsFolder = FolderRuleFolder(path: downloads.path)
        let desktopFolder = FolderRuleFolder(path: desktop.path)
        var receipts = FolderRuleTemplates.template("receipts")!.make(downloadsFolder.id)
        receipts.isEnabled = true
        var screenshots = FolderRuleTemplates.template("file-screenshots")!.make(desktopFolder.id)
        screenshots.isEnabled = true
        let install = FolderRuleTemplates.template("install-disk-images")!.make(downloadsFolder.id)
        let installers = FolderRuleTemplates.template("old-installers")!.make(downloadsFolder.id)
        let optimize = FolderRuleTemplates.template("optimize-screenshots")!.make(desktopFolder.id)
        var sample = FolderRulesConfig(isEnabled: true, folders: [downloadsFolder, desktopFolder],
                                       rules: [receipts, install, installers, optimize, screenshots])
        sample.version = FolderRulesConfig.currentVersion
        let now = Date()
        func step(_ kind: FolderRuleActionKind, _ summary: String, from: String? = nil, to: String? = nil) -> FolderRuleStepRecord {
            FolderRuleStepRecord(action: kind, result: .done, summary: summary,
                                 undo: from.flatMap { original in to.map { FolderRuleUndo.moveBack(current: $0, original: original) } })
        }
        let pictures = FolderRulesSafety.display(FolderRulesLocations.pictures.appendingPathComponent("Screenshots/2026-10"))
        let receiptsFolder = FolderRulesSafety.display(FolderRulesLocations.documents.appendingPathComponent("Receipts"))
        let lines: [FolderRuleActivity] = [
            FolderRuleActivity(date: now.addingTimeInterval(-240), ruleID: screenshots.id, ruleName: screenshots.name,
                               folderName: desktopFolder.name, fileName: "Screenshot 2026-10-31 at 09.58.10.png", result: .succeeded,
                               detail: "Moved to \(pictures)",
                               steps: [step(.move, "Moved to \(pictures)", from: desktop.appendingPathComponent("Screenshot 2026-10-31 at 09.58.10.png").path,
                                            to: root.appendingPathComponent("Pictures/Screenshots/2026-10/Screenshot 2026-10-31 at 09.58.10.png").path)]),
            FolderRuleActivity(date: now.addingTimeInterval(-1_900), ruleID: receipts.id, ruleName: receipts.name,
                               folderName: downloadsFolder.name, fileName: "청구서_2026_10.pdf", result: .succeeded,
                               detail: "Moved to \(receiptsFolder) · Tagged “Receipt”",
                               steps: [step(.move, "Moved to \(receiptsFolder)", from: downloads.appendingPathComponent("청구서_2026_10.pdf").path,
                                            to: root.appendingPathComponent("Documents/Receipts/청구서_2026_10.pdf").path),
                                       step(.addTags, "Tagged “Receipt”")]),
            FolderRuleActivity(date: now.addingTimeInterval(-5_400), ruleID: nil, ruleName: "Install Disk Image",
                               folderName: "~/Downloads", fileName: "Ice-0.11.12.dmg", result: .succeeded,
                               detail: "Installed “Ice” in /Applications; the disk image is in the Trash"),
            FolderRuleActivity(date: now.addingTimeInterval(-90_000), ruleID: installers.id, ruleName: installers.name,
                               folderName: downloadsFolder.name, fileName: "Zoom.pkg", result: .failed,
                               detail: "Couldn't finish: “Zoom.pkg” couldn't be moved to the Trash because it's in use.")
        ]
        replaceForPreview(config: sample, activity: lines)
        if ProcessInfo.processInfo.arguments.contains("--aom-preview-folder-rules-approval") {
            let image = downloads.appendingPathComponent("Rapidmg-1.3.1.dmg")
            if let info = FolderRuleFileReader.read(image) {
                addPreviewApproval(FolderRuleApprovalRequest(key: FolderRuleMemory.key(rule: install.id, info), ruleID: install.id,
                                                             folderID: downloadsFolder.id, info: info))
            }
        }
    }
}
