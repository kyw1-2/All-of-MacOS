import Foundation
import AppKit
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

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

    init() {}

    // MARK: - Finder Tweaks

    /// Toggles visibility of hidden files in Finder and restarts Finder to apply.
    @discardableResult
    func toggleHiddenFiles() async -> Bool {
        let suite = "com.apple.finder"
        let key = "AppleShowAllFiles"
        let current = UserDefaults(suiteName: suite)?.bool(forKey: key) ?? false
        let next = !current
        UserDefaults(suiteName: suite)?.set(next, forKey: key)
        
        // Sync using defaults CLI for cross-process visibility
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", next ? "true" : "false"]
        try? process.run()
        process.waitUntilExit()

        await restartFinder()
        return next
    }

    /// Toggles desktop icons on macOS and restarts Finder.
    @discardableResult
    func toggleDesktopIcons() async -> Bool {
        let suite = "com.apple.finder"
        let key = "CreateDesktop"
        let current = UserDefaults(suiteName: suite)?.bool(forKey: key) ?? true
        let next = !current
        UserDefaults(suiteName: suite)?.set(next, forKey: key)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", next ? "true" : "false"]
        try? process.run()
        process.waitUntilExit()

        await restartFinder()
        return next
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

    /// Flushes macOS local DNS resolver cache and sends HUP to mDNSResponder.
    func flushDNSCache() async throws {
        let dscache = Process()
        dscache.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        dscache.arguments = ["-flushcache"]
        try dscache.run()
        dscache.waitUntilExit()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-HUP", "mDNSResponder"]
        try kill.run()
        kill.waitUntilExit()
    }

    // MARK: - File Maintenance & Attributes

    /// Recursively erases all .DS_Store files within a given directory URL.
    func eraseDSStoreFiles(in directory: URL) async throws -> Int {
        let fileManager = FileManager.default
        var deletedCount = 0

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: []
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == ".DS_Store" {
                do {
                    try fileManager.removeItem(at: fileURL)
                    deletedCount += 1
                } catch {
                    continue
                }
            }
        }
        return deletedCount
    }

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

    /// Sets or clears the Darwin immutable flag (UF_IMMUTABLE / uchg).
    func setFileLocked(url: URL, locked: Bool) throws {
        try updateFileFlag(url: url, flag: UInt32(UF_IMMUTABLE), enabled: locked)
    }

    /// Sets or clears only UF_HIDDEN; unrelated Finder/backup flags survive.
    func setFileHidden(url: URL, hidden: Bool) throws {
        try updateFileFlag(url: url, flag: UInt32(UF_HIDDEN), enabled: hidden)
    }

    private func updateFileFlag(url: URL, flag: UInt32, enabled: Bool) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let flags = enabled ? metadata.st_flags | flag : metadata.st_flags & ~flag
        guard flags != metadata.st_flags else { return }
        guard lchflags(url.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - PDF Tools

    /// Combines PDF documents in order into a single file at the destination.
    func combinePDFs(urls: [URL], to destination: URL) throws {
        let merged = PDFDocument()
        var index = 0
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let document = PDFDocument(url: url) else { continue }
            for page in 0..<document.pageCount {
                guard let page = document.page(at: page) else { continue }
                merged.insert(page, at: index)
                index += 1
            }
        }
        guard merged.pageCount > 0 else { throw CocoaError(.fileWriteUnknown) }
        guard merged.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Compresses a PDF by re-rendering every page as a scaled JPEG-backed
    /// PDF page (MacMagic's compresspdfs approach).
    func compressPDF(url: URL, to destination: URL, quality: Double = 0.65) throws {
        guard let source = PDFDocument(url: url) else { throw CocoaError(.fileReadUnknown) }
        let output = PDFDocument()
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { continue }
            let thumbnail = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
            guard let tiff = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { continue }
            if let pageImage = PDFPage(image: NSImage(data: jpeg) ?? NSImage()) {
                output.insert(pageImage, at: index)
            }
        }
        guard output.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
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
    func convertVideo(url: URL, to destination: URL, preset: String = AVAssetExportPresetHighestQuality) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.fileReadUnknown)
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        try await session.export()
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

    /// Turns the primary Wi-Fi interface off (MacMagic's disconnectwifi).
    func disconnectWiFi() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networksetup")
        process.arguments = ["-setairportpower", "en0", "off"]
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - File Management

    /// Plain-text batch rename with an optional sequential token "{n}".
    /// Validate the plan before moving files; surface filesystem failures.
    func batchRename(urls: [URL], pattern: String, replacement: String, startingNumber: Int = 1) throws -> [URL] {
        var renamed: [URL] = []
        var targets = Set<URL>()
        for (index, url) in urls.enumerated() {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let (number, overflow) = startingNumber.addingReportingOverflow(index)
            guard !overflow else { throw CocoaError(.fileWriteInvalidFileName) }
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            // This is a plain-text replacement: "$1" and backslashes are literal.
            let newName = name.replacingOccurrences(of: pattern, with: replacement)
                .replacingOccurrences(of: "{n}", with: String(number))
            guard !newName.isEmpty, newName != ".", newName != "..",
                  !newName.contains("/"), !newName.contains("\0") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let filename = ext.isEmpty ? newName : "\(newName).\(ext)"
            let target = url.deletingLastPathComponent().appendingPathComponent(filename)
            guard targets.insert(target.standardizedFileURL).inserted else {
                throw CocoaError(.fileWriteFileExists)
            }
            if target.standardizedFileURL != url.standardizedFileURL,
               FileManager.default.fileExists(atPath: target.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            renamed.append(target)
        }
        for (source, target) in zip(urls, renamed) where source.standardizedFileURL != target.standardizedFileURL {
            try FileManager.default.moveItem(at: source, to: target)
        }
        return renamed
    }

    /// Force-deletes a stubborn file: clears the immutable flag first, then
    /// removes it (MacMagic's forcedelete).
    func forceDelete(url: URL) throws {
        try? setFileLocked(url: url, locked: false)
        try FileManager.default.removeItem(at: url)
    }

    /// Empties the user Trash directory.
    func forceEmptyTrash() async throws {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let items = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
