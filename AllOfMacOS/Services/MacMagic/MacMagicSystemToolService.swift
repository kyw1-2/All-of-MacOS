import Foundation
import AppKit
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Why a system tool did not do what its tile says. Until 3.3.1 Flush DNS
/// ignored the exit status of its commands and Empty Trash dropped every
/// per-item error, so both could announce success after doing nothing
/// (audit 2026-10-28 F09).
enum SystemToolError: LocalizedError, Equatable {
    /// A helper command ran and exited unsuccessfully.
    case commandFailed(command: String, status: Int32, message: String)
    /// macOS keeps AOM out of the Trash folder (Full Disk Access).
    case trashNotReadable
    /// A Finder preference could not be written.
    case finderSettingNotSaved(String)
    /// A Dock, screenshot or global preference could not be written.
    case settingNotSaved(String)
    /// The tool needs input it didn't get (an empty clipboard, a bad port).
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let status, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return "\(command) failed (exit status \(status))\(detail)"
        case .trashNotReadable:
            return "macOS doesn't let All of MacOS read the Trash. Turn on All of MacOS in System Settings › Privacy & Security › Full Disk Access, or empty the Trash in Finder."
        case .finderSettingNotSaved(let key):
            return "Finder's \(key) setting could not be changed, so nothing was toggled."
        case .settingNotSaved(let key):
            return "The \(key) setting could not be changed, so nothing was changed."
        case .invalidInput(let message):
            return message
        }
    }

    /// macOS refused the command for lack of privileges (restarting the
    /// system DNS resolver needs an administrator). Run by anyone but root,
    /// `killall` only looks at the caller's own processes, so for
    /// mDNSResponder it answers "No matching processes belonging to you were
    /// found" (exit 1) rather than a permission error.
    var needsAdministrator: Bool {
        guard case .commandFailed(_, _, let message) = self else { return false }
        let text = message.lowercased()
        return text.contains("not permitted") || text.contains("permission denied")
            || text.contains("no matching processes belonging to you")
    }
}

/// System maintenance and file utility suite replicating MacMagic 2.0 features inside AOM.
final class MacMagicSystemToolService {
    static let shared = MacMagicSystemToolService()

    struct LockingProcess: Identifiable, Equatable {
        var id: String { "\(pid):\(command)" }
        let command: String
        let pid: pid_t
        let user: String
        let fileDescriptor: String
    }

    /// One helper command a tool runs.
    struct ToolCommand: Equatable {
        let path: String
        let arguments: [String]
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// What Empty Trash actually did.
    struct TrashResult: Equatable {
        var deleted = 0
        /// "name: reason" for every item that could not be deleted.
        var failures: [String] = []
        var succeeded: Bool { failures.isEmpty }

        /// The message for the user; never "emptied" when anything was left.
        var summary: String {
            if failures.isEmpty {
                return deleted == 0 ? "Trash was already empty" : "Trash emptied (\(deleted) item\(deleted == 1 ? "" : "s"))"
            }
            let kept = failures.count
            return "Deleted \(deleted) item\(deleted == 1 ? "" : "s"); \(kept) could not be deleted: "
                + failures.prefix(3).joined(separator: "; ") + (kept > 3 ? "; …" : "")
        }
    }

    init() {}

    // MARK: - Finder Tweaks

    /// Reads a Finder boolean the way Finder does: a missing key means
    /// `fallback`. `bool(forKey:) ?? fallback` never reaches the fallback,
    /// because UserDefaults answers false for a missing key — so the first
    /// Desktop Icons toggle on a Mac with the default setting wrote true and
    /// changed nothing (audit 2026-10-28 F10).
    static func finderFlag(_ key: String, in defaults: UserDefaults?, default fallback: Bool) -> Bool {
        guard let defaults, defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    /// The state the Desktop Icons tool switches to: Finder draws desktop
    /// icons unless `CreateDesktop` is false.
    static func nextDesktopIconsState(in defaults: UserDefaults?) -> Bool {
        !finderFlag("CreateDesktop", in: defaults, default: true)
    }

    /// Toggles visibility of hidden files in Finder and restarts Finder to apply.
    /// Returns the new state; throws when the setting could not be written.
    @discardableResult
    func toggleHiddenFiles() async throws -> Bool {
        let key = "AppleShowAllFiles"
        let next = !Self.finderFlag(key, in: UserDefaults(suiteName: "com.apple.finder"), default: false)
        try writeFinderFlag(key, next)
        await restartFinder()
        return next
    }

    /// Toggles desktop icons on macOS and restarts Finder. Returns the new
    /// state; throws when the setting could not be written.
    @discardableResult
    func toggleDesktopIcons() async throws -> Bool {
        let next = Self.nextDesktopIconsState(in: UserDefaults(suiteName: "com.apple.finder"))
        try writeFinderFlag("CreateDesktop", next)
        await restartFinder()
        return next
    }

    /// Writes a Finder boolean through cfprefsd (the mechanism the capture
    /// menu's Hide Desktop Icons uses) and reports a failed synchronise
    /// instead of claiming the new state.
    private func writeFinderFlag(_ key: String, _ value: Bool) throws {
        let domain = "com.apple.finder" as CFString
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw SystemToolError.finderSettingNotSaved(key) }
    }

    /// Runs a helper to completion and returns its exit status and standard
    /// error (standard output is discarded).
    static func run(_ command: ToolCommand) throws -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.path)
        process.arguments = command.arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, so a chatty helper cannot fill the pipe and stall.
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }

    /// Restarts the Finder process cleanly.
    func restartFinder() async {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.finder" }
        for app in apps {
            app.terminate()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // If Finder does not auto-relaunch immediately, open it
        if NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == "com.apple.finder" }).isEmpty {
            NSWorkspace.shared.launchApplication(
                withBundleIdentifier: "com.apple.finder",
                options: [],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
        }
    }

    // MARK: - System Network & DNS

    static let dnsFlushCommands = [
        ToolCommand(path: "/usr/bin/dscacheutil", arguments: ["-flushcache"]),
        ToolCommand(path: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    ]

    /// Flushes macOS local DNS resolver cache and sends HUP to mDNSResponder.
    /// Every step must exit 0; the first one that does not is thrown with its
    /// exit status and standard error. AOM runs as the user, not root, so
    /// `killall` cannot signal mDNSResponder (even for an administrator
    /// account); `needsAdministrator` then tells the caller to offer
    /// `flushDNSCacheAsAdministrator()` instead of announcing success.
    func flushDNSCache(commands: [ToolCommand] = MacMagicSystemToolService.dnsFlushCommands) async throws {
        for command in commands {
            let result = try Self.run(command)
            guard result.status == 0 else {
                throw SystemToolError.commandFailed(command: command.name, status: result.status, message: result.message)
            }
        }
    }

    enum AdministratorResult: Equatable { case done, cancelled, failed(String) }

    /// The same flush with an administrator password, through the standard
    /// macOS authorization prompt. Only ever started by the user.
    @MainActor
    func flushDNSCacheAsAdministrator() -> AdministratorResult {
        let shell = Self.dnsFlushCommands.map { ([$0.path] + $0.arguments).joined(separator: " ") }.joined(separator: " && ")
        let source = "do shell script \"\(shell)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed("The request could not be prepared.") }
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "macOS refused the request.")
    }

    // MARK: - File Maintenance & Attributes

    /// Identifies all processes currently locking or holding open file descriptors for a target path.
    func findProcessesLockingFile(at url: URL) async throws -> [LockingProcess] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [url.path]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var results: [LockingProcess] = []

        let lines = output.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        // Skip header line
        for line in lines.dropFirst() {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 4, let pid = pid_t(tokens[1]) else { continue }
            results.append(LockingProcess(
                command: tokens[0],
                pid: pid,
                user: tokens[2],
                fileDescriptor: tokens[3]
            ))
        }
        return results
    }

    // MARK: - PDF Tools

    /// Merges in name order. 7.2.2 (audit B05): a PDF that can't be read or
    /// is locked is no longer dropped silently — its name is returned so the
    /// result says so, and nothing is written when none could be read.
    @discardableResult
    func combinePDFs(urls: [URL], to destination: URL) throws -> [String] {
        let merged = PDFDocument()
        var index = 0
        var skipped: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                skipped.append(url.lastPathComponent)
                continue
            }
            for page in 0..<document.pageCount {
                guard let page = document.page(at: page) else { continue }
                merged.insert(page, at: index)
                index += 1
            }
        }
        guard merged.pageCount > 0 else { throw SystemToolError.invalidInput("None of the PDFs could be read (\(skipped.joined(separator: ", ")))") }
        guard merged.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
        return skipped
    }

    /// 7.2.2 (audit N02, B04): two ways to make a PDF smaller.
    enum PDFCompression: String, CaseIterable, Identifiable {
        /// Text, links and vector drawings stay; only the images inside are
        /// recompressed as JPEG at screen resolution.
        case keepText
        /// Every page becomes one JPEG image (MacMagic's compresspdfs): the
        /// smallest for scans, but the text can no longer be selected or searched.
        case pagesAsImages

        var id: String { rawValue }
        var title: String { self == .keepText ? "Keep Text" : "Pages as Images" }
        var detail: String {
            self == .keepText ? "Text stays selectable; images are recompressed."
                              : "Each page becomes a picture; text can't be selected or searched."
        }
    }

    func compressPDF(url: URL, to destination: URL, mode: PDFCompression = .keepText, quality: Double = 0.65) throws {
        guard let source = PDFDocument(url: url) else { throw CocoaError(.fileReadUnknown) }
        guard !source.isLocked else { throw SystemToolError.invalidInput("The PDF is password-protected. Remove the password first.") }
        switch mode {
        case .keepText:
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard source.write(to: destination, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
        case .pagesAsImages:
            let output = PDFDocument()
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                // 150 dpi (7.2.1 drew at 72 dpi, which blurred small text).
                let bounds = page.bounds(for: .mediaBox).size
                let scale = min(150.0 / 72.0, 4_000 / max(bounds.width, bounds.height, 1))
                let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let tiff = thumbnail.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                      let image = NSImage(data: jpeg) else { throw CocoaError(.fileWriteUnknown) }
                image.size = bounds
                guard let pageImage = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
                output.insert(pageImage, at: output.pageCount)
            }
            guard output.pageCount == source.pageCount else { throw CocoaError(.fileWriteUnknown) }
            guard output.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Pure: "Report (compressed).pdf", then "(compressed 2)" … — never an
    /// existing file (7.2.1 overwrote "Report.compressed.pdf", audit B03).
    static func freeName(nextTo source: URL, suffix: String, ext: String = "pdf",
                         exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let label = number == 1 ? suffix : "\(suffix) \(number)"
            let candidate = folder.appendingPathComponent("\(base) (\(label)).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: - Media Tools

    enum ImageFormat: String, CaseIterable { case png, jpeg, heic, webp }

    /// Converts an image file to another format, returning the new file URL.
    func convertImage(url: URL, to format: ImageFormat, quality: Double = 0.85) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        if format == .webp {
            guard let bytes = WebPEncoder.encode(image: image, quality: quality) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let destination = url.deletingPathExtension().appendingPathExtension("webp")
            guard destination.standardizedFileURL != url.standardizedFileURL else {
                throw CocoaError(.fileWriteFileExists)
            }
            try bytes.write(to: destination, options: .withoutOverwriting)
            return destination
        }
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .webp: throw CocoaError(.fileWriteUnknown) // handled by the bundled encoder above
        }
        let base = url.deletingPathExtension().lastPathComponent
        let destinationURL = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(format.rawValue).\(type.preferredFilenameExtension ?? format.rawValue)")
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return destinationURL
    }

    /// Generates a QR code image for the text at the given scale.
    func generateQRCode(text: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Converts a video to H.264 MP4 (or another preset) via AVAssetExportSession.
    ///
    /// 7.2.3 (audit B06): `export()` never throws, so a failed export was
    /// reported as converted. `export(to:as:)` throws on failure and
    /// cancellation; the export goes to a temporary file first, is checked
    /// for a video track, and only then takes the destination's place, so a
    /// failed or partial export leaves nothing behind (and an existing file
    /// the save panel agreed to replace is replaced, not left as it was).
    func convertVideo(url: URL, to destination: URL, preset: String = AVAssetExportPresetHighestQuality) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.fileReadUnknown)
        }
        let files = FileManager.default
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(destination.lastPathComponent)
        try await session.export(to: temporary, as: .mp4)
        try await Self.checkConvertedVideo(temporary)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
    }

    /// A finished export is a non-empty file with a video track.
    static func checkConvertedVideo(_ url: URL) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The export finished without writing a video."])
        }
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The exported file has no video in it."])
        }
    }

    // MARK: - System Management

    /// Total size of the user's cache directories (~/Library/Caches and the
    /// app-support cache roots), computed without deleting anything.
    func diskCacheSize() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    }

    func clearDiskCache() throws -> Int64 {
        try clearDiskCache(in: diskCacheSize())
    }

    /// Explicit root keeps verification isolated from the user's real caches.
    func clearDiskCache(in caches: URL) throws -> Int64 {
        var freed: Int64 = 0
        let items = try FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
        for item in items {
            // AOM's own live cache must survive.
            if item.lastPathComponent.lowercased().contains("allofmacos") { continue }
            let size = (try? directorySize(item)) ?? 0
            do {
                try FileManager.default.removeItem(at: item)
                freed += size
            } catch { continue }
        }
        return freed
    }

    func directorySize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - File Management

    /// 7.2.2: the preview, all-or-nothing moves and Undo live in `BatchRename`.
    func batchRename(urls: [URL], pattern: String, replacement: String, startingNumber: Int = 1) throws -> [URL] {
        for url in urls where !url.isFileURL || !FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        let rows = BatchRename.plan(urls, find: pattern, template: replacement, startingNumber: startingNumber)
        try BatchRename.apply(rows)
        return rows.map(\.target)
    }

    /// Empties the user Trash directory and reports what it deleted and what
    /// it could not (a locked item, an item owned by another user). Until
    /// 3.3.1 every per-item error was dropped, so "Trash emptied" could follow
    /// a run that deleted nothing. `trash` is injectable for tests.
    func forceEmptyTrash(at trash: URL? = nil) async throws -> TrashResult {
        let trashURL = trash ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            // ~/.Trash is privacy-protected; reading it needs Full Disk Access.
            throw SystemToolError.trashNotReadable
        }
        var result = TrashResult()
        for item in items {
            do {
                try FileManager.default.removeItem(at: item)
                result.deleted += 1
            } catch {
                result.failures.append("\(item.lastPathComponent): \(Self.reason(error))")
            }
        }
        return result
    }

    /// The POSIX reason behind a file error ("Operation not permitted"),
    /// which says more than Foundation's generic sentence.
    private static func reason(_ error: Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return String(cString: strerror(code.rawValue))
        }
        return error.localizedDescription
    }
}
