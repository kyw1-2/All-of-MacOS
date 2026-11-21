import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The Files page's Tools menu: the PDF page tools, image and video
/// conversion, and the file information tools that 3.4.x offered on System
/// Tools. Every tool saves a new file or only reads; nothing overwrites the
/// original, and the ones that remove something ask first.
@MainActor
final class FileToolsModel: ObservableObject {
    enum Tool: String, Identifiable {
        case pdfMerge, pdfCompress, pdfSplit, pdfExtract, pdfRemove, pdfRotate, pdfReorder, imagesToPDF,
             pdfToImages, pdfProtect, pdfUnlock, pdfPageNumbers
        case convertImage, convertVideo, qrCode
        case batchRename, whatsUsing, fileHash
        var id: String { rawValue }
    }

    let toasts = AOMToastModel()
    @Published var processReview: ProcessReview?
    /// 7.2.2 (audit N01): the files waiting in the Batch Rename sheet.
    @Published var renameFiles: RenameFiles?
    /// 7.2.2 (audit N02): both compressions of one PDF, to choose from.
    @Published var pdfComparison: PDFComparison?
    private(set) var running: Set<Tool> = []

    let service = MacMagicSystemToolService.shared

    // MARK: - Panels

    private func pickFiles(types: [UTType], multiple: Bool, directories: Bool = false, message: String?) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func pickFolder(near source: URL, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.prompt = "Save Here"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// A save panel next to the source, never offering to overwrite it.
    private func saveURL(for source: URL, suffix: String, type: UTType = .pdf) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " (\(suffix))." + (type.preferredFilenameExtension ?? "pdf")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.standardizedFileURL != source.standardizedFileURL else {
            fail("Original Not Replaced", "Choose another name; the PDF tools never overwrite the original.")
            return nil
        }
        return url
    }

    private func promptText(_ title: String, _ message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func popUp(_ menu: NSMenu) {
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func run(_ tool: Tool, _ work: @escaping () throws -> String, then shown: @escaping (String) -> Void = { _ in }) {
        guard !running.contains(tool) else { return }
        running.insert(tool)
        Task.detached(priority: .userInitiated) {
            let outcome = Swift.Result { try work() }
            await MainActor.run {
                self.running.remove(tool)
                switch outcome {
                case .success(let message): shown(message)
                case .failure(let error): self.fail("Didn't Finish", error.localizedDescription)
                }
            }
        }
    }

    func fail(_ title: String, _ message: String) {
        toasts.show("\(title): \(message)", tone: .danger, seconds: min(12, 6 + Double(message.count) / 30))
    }

    func succeed(_ message: String) { toasts.show(message, tone: .success) }

    // MARK: - PDF

    private func pickPDF(_ message: String) -> URL? {
        pickFiles(types: [UTType.pdf], multiple: false, message: message)?.first
    }

    private func pageCount(_ url: URL) -> Int? {
        do { return try PDFTools.open(url).pageCount }
        catch { fail("PDF Not Read", error.localizedDescription); return nil }
    }

    func run(_ tool: Tool) {
        guard !running.contains(tool) else { return }
        switch tool {
        case .pdfMerge: mergePDFs()
        case .pdfCompress: compressPDF()
        case .pdfSplit: splitPDF()
        case .pdfExtract, .pdfRemove, .pdfReorder: pagesTool(tool)
        case .pdfRotate: rotatePDF()
        case .imagesToPDF: imagesToPDF()
        case .pdfToImages: pdfToImages()
        case .pdfProtect: protectPDF()
        case .pdfUnlock: unlockPDF()
        case .pdfPageNumbers: addPageNumbers()
        case .convertImage: convertImage()
        case .convertVideo: convertVideo()
        case .qrCode: makeQR()
        case .batchRename: batchRename()
        case .whatsUsing: whatIsUsingFile()
        case .fileHash: hashFile()
        }
    }

    private func mergePDFs() {
        guard let urls = pickFiles(types: [UTType.pdf], multiple: true, message: "Choose two or more PDFs; they're merged in name order."),
              urls.count >= 2 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run(.pdfMerge, {
            let skipped = try self.service.combinePDFs(urls: urls, to: destination)
            guard !skipped.isEmpty else { return "Merged \(urls.count) PDFs" }
            return "Merged \(urls.count - skipped.count) PDFs · left out (unreadable or locked): \(skipped.joined(separator: ", "))"
        }) { self.succeed($0) }
    }

    /// Makes both versions in a temporary folder and shows their sizes; the
    /// chosen one is saved next to the original under a new name.
    private func compressPDF() {
        guard let url = pickFiles(types: [UTType.pdf], multiple: false, message: "Choose the PDF to make smaller.")?.first else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOMCompress-\(UUID().uuidString)", isDirectory: true)
        guard !running.contains(.pdfCompress) else { return }
        running.insert(.pdfCompress)
        toasts.show("Compressing \(url.lastPathComponent) two ways…", tone: .info)
        let service = self.service
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var options: [PDFComparison.Option] = []
            var firstError: String?
            for mode in MacMagicSystemToolService.PDFCompression.allCases {
                let output = folder.appendingPathComponent("\(mode.rawValue).pdf")
                do {
                    try service.compressPDF(url: url, to: output, mode: mode)
                    options.append(.init(mode: mode, file: output, size: CleanupTools.allocatedSize(output)))
                } catch {
                    firstError = firstError ?? error.localizedDescription
                }
            }
            let original = CleanupTools.allocatedSize(url)
            let found = options
            let problem = firstError
            await MainActor.run {
                self.running.remove(.pdfCompress)
                self.toasts.dismiss()
                guard !found.isEmpty else {
                    try? FileManager.default.removeItem(at: folder)
                    self.fail("PDF Not Compressed", problem ?? "Neither way worked."); return
                }
                self.pdfComparison = PDFComparison(source: url, originalSize: original, options: found, folder: folder)
            }
        }
    }

    func savePDFComparison(_ option: PDFComparison.Option?) {
        guard let comparison = pdfComparison else { return }
        pdfComparison = nil
        defer { try? FileManager.default.removeItem(at: comparison.folder) }
        guard let option else { return }
        let destination = MacMagicSystemToolService.freeName(nextTo: comparison.source, suffix: "compressed")
        do {
            try FileManager.default.moveItem(at: option.file, to: destination)
            toasts.show("Saved \(destination.lastPathComponent) · \(SystemStatus.size(comparison.originalSize)) → \(SystemStatus.size(option.size))",
                        tone: .success, actionTitle: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        } catch { fail("PDF Not Saved", error.localizedDescription) }
    }

    private func splitPDF() {
        guard let url = pickPDF("Choose the PDF to split."), let count = pageCount(url) else { return }
        let menu = NSMenu()
        menu.addItem(header("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        menu.addItem(SystemToolMenuItem(title: "Every Page as Its Own PDF…") {
            guard let folder = self.pickFolder(near: url, message: "Choose where the \(count) single-page PDFs go.") else { return }
            self.run(.pdfSplit, { "Saved \(try PDFTools.splitIntoPages(url, into: folder).count) PDFs in \(folder.lastPathComponent)" }) { self.succeed($0) }
        })
        menu.addItem(SystemToolMenuItem(title: "By Ranges…") {
            guard let ranges = self.promptText("Split PDF", "One PDF per range, separated by commas (\(count) pages), for example 1-3, 4-6, 7-",
                                               placeholder: "1-3, 4-6, 7-"), !ranges.isEmpty else { return }
            do { _ = try PageRanges.groups(ranges, pageCount: count) } catch {
                self.fail("Ranges Not Understood", error.localizedDescription); return
            }
            guard let folder = self.pickFolder(near: url, message: "Choose where the PDFs go.") else { return }
            self.run(.pdfSplit, { "Saved \(try PDFTools.split(url, ranges: ranges, into: folder).count) PDFs in \(folder.lastPathComponent)" }) { self.succeed($0) }
        })
        popUp(menu)
    }

    /// Extract, Remove and Reorder: pick a PDF, type pages, save a copy.
    private func pagesTool(_ tool: Tool) {
        let (verb, prompt, placeholder, suffix): (String, String, String, String)
        switch tool {
        case .pdfExtract: (verb, prompt, placeholder, suffix) = ("Extract Pages", "Pages to keep, in the order you want them", "1-3, 5", "pages")
        case .pdfRemove: (verb, prompt, placeholder, suffix) = ("Remove Pages", "Pages to leave out", "2, 4-5", "pages removed")
        default: (verb, prompt, placeholder, suffix) = ("Reorder Pages", "The new order; pages you leave out follow in their old order", "3, 1-2", "reordered")
        }
        guard let url = pickPDF("Choose the PDF."), let count = pageCount(url) else { return }
        guard let text = promptText(verb, "\(prompt). The PDF has \(count) page\(count == 1 ? "" : "s"); 8- means 8 to the end.",
                                    placeholder: placeholder), !text.isEmpty else { return }
        do {
            switch tool {
            case .pdfRemove:
                let removed = try PageRanges.set(text, pageCount: count)
                guard removed.count < count else {
                    fail("Nothing Would Be Left", "Those are all \(count) pages; at least one has to stay."); return
                }
            case .pdfReorder: _ = try PageRanges.reorder(text, pageCount: count)
            default: _ = try PageRanges.pages(text, pageCount: count)
            }
        } catch { fail("Pages Not Understood", error.localizedDescription); return }
        let label = tool == .pdfExtract ? "pages \(PageRanges.describe((try? PageRanges.pages(text, pageCount: count)) ?? []))" : suffix
        guard let output = saveURL(for: url, suffix: label) else { return }
        run(tool, {
            switch tool {
            case .pdfExtract:
                return "Saved \(try PDFTools.extract(url, pages: text, to: output)) pages as \(output.lastPathComponent)"
            case .pdfRemove:
                return "Saved \(output.lastPathComponent) with \(try PDFTools.remove(url, pages: text, to: output)) of \(count) pages"
            default:
                let order = try PDFTools.reorder(url, order: text, to: output)
                return "Saved \(output.lastPathComponent) in the order \(PageRanges.describe(Array(order.prefix(8))))\(order.count > 8 ? "…" : "")"
            }
        }) { self.succeed($0) }
    }

    private func rotatePDF() {
        guard let url = pickPDF("Choose the PDF to rotate."), let count = pageCount(url) else { return }
        let menu = NSMenu()
        menu.addItem(header("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for (title, degrees) in [("90° Right…", 90), ("90° Left…", -90), ("180°…", 180)] {
            menu.addItem(SystemToolMenuItem(title: title) {
                guard let text = self.promptText("Rotate Pages \(title.replacingOccurrences(of: "…", with: ""))",
                                                 "Pages to rotate; leave empty for every page (\(count)).", placeholder: "all") else { return }
                let trimmed = text.lowercased() == "all" ? "" : text
                if !trimmed.isEmpty {
                    do { _ = try PageRanges.set(trimmed, pageCount: count) }
                    catch { self.fail("Pages Not Understood", error.localizedDescription); return }
                }
                guard let output = self.saveURL(for: url, suffix: "rotated") else { return }
                self.run(.pdfRotate, { "Turned \(try PDFTools.rotate(url, pages: trimmed, degrees: degrees, to: output)) pages in \(output.lastPathComponent)" }) { self.succeed($0) }
            })
        }
        popUp(menu)
    }

    private func imagesToPDF() {
        guard let images = pickFiles(types: [.image], multiple: true, message: "Choose the images; each becomes one page, in name order."),
              !images.isEmpty else { return }
        let sorted = images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let menu = NSMenu()
        menu.addItem(header("\(sorted.count) image\(sorted.count == 1 ? "" : "s")"))
        for size in PDFTools.PageSize.allCases {
            menu.addItem(SystemToolMenuItem(title: size.title + "…") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.directoryURL = sorted[0].deletingLastPathComponent()
                panel.nameFieldStringValue = sorted.count == 1 ? sorted[0].deletingPathExtension().lastPathComponent + ".pdf" : "Images.pdf"
                guard panel.runModal() == .OK, let output = panel.url else { return }
                self.run(.imagesToPDF, {
                    let pages = try PDFTools.imagesToPDF(sorted, pageSize: size, to: output)
                    let skipped = sorted.count - pages
                    return "Saved \(output.lastPathComponent) with \(pages) pages"
                        + (skipped > 0 ? " (\(skipped) file\(skipped == 1 ? "" : "s") weren't readable images)" : "")
                }) { self.succeed($0) }
            })
        }
        popUp(menu)
    }

    private func pdfToImages() {
        guard let url = pickPDF("Choose the PDF; every page becomes an image."), let count = pageCount(url) else { return }
        let menu = NSMenu()
        menu.addItem(header("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for format in PDFTools.ImageFormat.allCases {
            for dpi in PDFTools.dpiChoices {
                menu.addItem(SystemToolMenuItem(title: "\(format.title) at \(dpi) dpi…") {
                    guard let folder = self.pickFolder(near: url, message: "Choose where the \(count) images go.") else { return }
                    self.run(.pdfToImages, {
                        let outputs = try PDFTools.pdfToImages(url, format: format, dpi: dpi, into: folder)
                        return "Saved \(outputs.count) \(format.title) images in \(folder.lastPathComponent)"
                    }) { self.succeed($0) }
                })
            }
            if format != PDFTools.ImageFormat.allCases.last { menu.addItem(.separator()) }
        }
        popUp(menu)
    }

    private func protectPDF() {
        guard let url = pickPDF("Choose the PDF to protect.") else { return }
        guard let document = PDFDocument(url: url) else { fail("PDF Not Read", PDFTools.Failure.unreadable(url.lastPathComponent).localizedDescription); return }
        guard !document.isEncrypted else {
            fail("Already Protected", "“\(url.lastPathComponent)” already has a password. Remove it first to set a new one."); return
        }
        guard let password = promptPassword(title: "Add a Password", message: "People need this password to open the copy. AOM doesn't keep it, so note it somewhere safe.",
                                            confirm: true) else { return }
        guard let output = saveURL(for: url, suffix: "protected") else { return }
        run(.pdfProtect, { try PDFTools.protect(url, password: password, to: output); return "Saved \(output.lastPathComponent); it asks for the password" }) { self.succeed($0) }
    }

    private func unlockPDF() {
        guard let url = pickPDF("Choose the password-protected PDF.") else { return }
        guard let document = PDFDocument(url: url) else { fail("PDF Not Read", PDFTools.Failure.unreadable(url.lastPathComponent).localizedDescription); return }
        guard document.isEncrypted else { fail("Not Protected", PDFTools.Failure.notEncrypted(url.lastPathComponent).localizedDescription); return }
        guard let password = promptPassword(title: "Remove the Password", message: "Type the password that opens “\(url.lastPathComponent)”.",
                                            confirm: false) else { return }
        guard document.unlock(withPassword: password) else { fail("Wrong Password", PDFTools.Failure.wrongPassword.localizedDescription); return }
        guard let output = saveURL(for: url, suffix: "unlocked") else { return }
        run(.pdfUnlock, { try PDFTools.unprotect(url, password: password, to: output); return "Saved \(output.lastPathComponent) without a password" }) { self.succeed($0) }
    }

    private func addPageNumbers() {
        guard let url = pickPDF("Choose the PDF to number."), let count = pageCount(url) else { return }
        let menu = NSMenu()
        menu.addItem(header("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for position in PDFTools.NumberPosition.allCases {
            for style in PDFTools.NumberStyle.allCases {
                let sample = style.text(page: 1, total: count)
                menu.addItem(SystemToolMenuItem(title: "\(position.title): \(sample)…") {
                    guard let output = self.saveURL(for: url, suffix: "numbered") else { return }
                    self.run(.pdfPageNumbers, { "Numbered \(try PDFTools.addPageNumbers(url, position: position, style: style, to: output)) pages in \(output.lastPathComponent)" }) { self.succeed($0) }
                })
            }
        }
        popUp(menu)
    }

    /// A secure field (and a second one to confirm). Never logged or kept.
    private func promptPassword(title: String, message: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 280, height: 24))
        first.placeholderString = "Password"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        second.placeholderString = "Repeat password"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: confirm ? 54 : 24))
        stack.addSubview(first)
        if confirm { stack.addSubview(second); first.nextKeyView = second }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = first
        alert.addButton(withTitle: confirm ? "Add Password" : "Remove Password")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = first.stringValue
        guard !password.isEmpty else { fail("No Password", "Type a password, then try again."); return nil }
        if confirm && password != second.stringValue {
            fail("Passwords Don't Match", PDFTools.Failure.passwordsDiffer.localizedDescription); return nil
        }
        return password
    }

    // MARK: - Image and video

    private func convertImage() {
        guard let url = pickFiles(types: [UTType.image], multiple: false, message: nil)?.first else { return }
        let menu = NSMenu()
        for format in MacMagicSystemToolService.ImageFormat.allCases {
            menu.addItem(SystemToolMenuItem(title: "→ \(format.rawValue.uppercased())") {
                do {
                    let output = try self.service.convertImage(url: url, to: format)
                    self.succeed("Saved \(output.lastPathComponent)")
                } catch { self.fail("Image Not Converted", error.localizedDescription) }
            })
        }
        popUp(menu)
    }

    private func convertVideo() {
        guard let url = pickFiles(types: [UTType.movie, UTType.mpeg4Movie], multiple: false, message: nil)?.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-converted.mp4"
        guard panel.runModal() == .OK, let destination = panel.url,
              destination.standardizedFileURL != url.standardizedFileURL else { return }
        guard !running.contains(.convertVideo) else { return }
        running.insert(.convertVideo)
        Task {
            defer { running.remove(.convertVideo) }
            do {
                try await service.convertVideo(url: url, to: destination)
                succeed("Video converted to \(destination.lastPathComponent)")
            } catch { fail("Video Not Converted", error.localizedDescription) }
        }
    }

    private func makeQR() {
        guard let text = promptText("QR Code", "Text or link to encode:", placeholder: "https://…"), !text.isEmpty else { return }
        guard let image = service.generateQRCode(text: text) else { fail("QR Code Not Made", "The text is too long for a QR code."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "QR.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fail("QR Code Not Saved", "The image could not be encoded as PNG."); return
        }
        do { try png.write(to: url); succeed("QR saved") } catch { fail("QR Code Not Saved", error.localizedDescription) }
    }

    // MARK: - File info

    private func batchRename() {
        guard let urls = pickFiles(types: [.item], multiple: true, message: "Choose the files to rename."), !urls.isEmpty else { return }
        renameFiles = RenameFiles(urls: urls)
    }

    /// Runs the previewed renames (all or none) and offers Undo.
    func applyRename(_ rows: [BatchRename.Row]) {
        renameFiles = nil
        do {
            let done = try BatchRename.apply(rows)
            let count = done.moves.count
            guard count > 0 else { succeed("No name changed"); return }
            toasts.show("Renamed \(count) file\(count == 1 ? "" : "s")", tone: .success, actionTitle: "Undo") { [weak self] in
                let failed = BatchRename.undo(done)
                if failed == 0 { self?.succeed("Names put back") }
                else { self?.fail("Not All Names Put Back", "\(failed) file\(failed == 1 ? " was" : "s were") moved or renamed since.") }
            }
        } catch { fail("Files Not Renamed", error.localizedDescription) }
    }

    private func whatIsUsingFile() {
        guard let url = pickFiles(types: [.item], multiple: false, directories: true,
                                  message: "Choose a file, folder or disk to see which processes have it open.")?.first else { return }
        Task {
            guard !running.contains(.whatsUsing) else { return }
            running.insert(.whatsUsing)
            defer { running.remove(.whatsUsing) }
            do {
                let users = try await service.findProcessesLockingFile(at: url)
                guard !users.isEmpty else { succeed("Nothing has \(url.lastPathComponent) open"); return }
                processReview = ProcessReview(title: "Using \(url.lastPathComponent)", rows: users.map {
                    .init(id: $0.id, pid: $0.pid, command: $0.command, detail: "PID \($0.pid) · \($0.user) · fd \($0.fileDescriptor)")
                })
            } catch { fail("Couldn't Check", error.localizedDescription) }
        }
    }

    /// Called by the process sheet's Quit button.
    func quitProcess(_ row: ProcessReview.Row) {
        let alert = NSAlert()
        alert.messageText = "Quit \(row.command)?"
        alert.informativeText = "Process \(row.pid) is asked to quit. Unsaved work in it may be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try NetworkTools.quit(pid: row.pid)
            processReview?.rows.removeAll { $0.pid == row.pid }
            if processReview?.rows.isEmpty == true { processReview = nil }
            succeed("Asked \(row.command) to quit")
        } catch { fail("Not Quit", error.localizedDescription) }
    }

    private func hashFile() {
        guard let url = pickFiles(types: [.item], multiple: false, message: nil)?.first else { return }
        let expected = FileTools.expectedHash(in: NSPasteboard.general.string(forType: .string))
        toasts.show("Hashing \(url.lastPathComponent)…", tone: .info, seconds: 4)
        run(.fileHash, { try FileTools.sha256Hex(fileAt: url) }) { hash in
            if let expected {
                // Keep the hash the user pasted; just say whether it matches.
                if expected == hash { self.succeed("SHA-256 matches the clipboard") }
                else { self.fail("SHA-256 Doesn't Match", "\(url.lastPathComponent) is \(hash), not the \(expected) on the clipboard.") }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
                self.succeed("SHA-256 copied: \(hash.prefix(16))…")
            }
        }
    }
}

/// The Files page's Tools menu and its three groups (PDF, Image & Video,
/// File Info). Each item runs one tool; everything the tools open is a panel
/// or a sheet over the page.
struct FilesToolsMenu: View {
    @ObservedObject var model: FileToolsModel

    private static let groups: [(title: String, tools: [(FileToolsModel.Tool, String)])] = [
        ("PDF", [(.pdfMerge, "Merge PDFs…"), (.pdfCompress, "Compress PDF…"), (.pdfSplit, "Split PDF…"),
                 (.pdfExtract, "Extract Pages…"), (.pdfRemove, "Remove Pages…"), (.pdfRotate, "Rotate Pages…"),
                 (.pdfReorder, "Reorder Pages…"), (.imagesToPDF, "Images to PDF…"), (.pdfToImages, "PDF to Images…"),
                 (.pdfProtect, "Add PDF Password…"), (.pdfUnlock, "Remove PDF Password…"), (.pdfPageNumbers, "Add Page Numbers…")]),
        ("Image & Video", [(.convertImage, "Convert Image…"), (.convertVideo, "Convert Video…"), (.qrCode, "QR Code…")]),
        ("File Info", [(.batchRename, "Batch Rename…"), (.whatsUsing, "What's Using a File…"), (.fileHash, "File SHA-256…")])
    ]

    var body: some View {
        Menu {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                Section(group.title) {
                    ForEach(group.tools, id: \.0) { tool, title in
                        Button(title) { model.run(tool) }
                    }
                }
            }
        } label: {
            Label("Tools", systemImage: "wand.and.stars")
        }
        .help("PDF, image, video and file information tools")
        .sheet(item: $model.processReview) { review in
            ProcessReviewSheet(review: review, onQuit: { model.quitProcess($0) },
                               onSort: { _ in }, onClose: { model.processReview = nil })
        }
        .sheet(item: $model.pdfComparison) { comparison in
            PDFComparisonSheet(comparison: comparison, onSave: { model.savePDFComparison($0) })
        }
        .sheet(item: $model.renameFiles) { files in
            BatchRenameSheet(urls: files.urls, onRename: { model.applyRename($0) }, onCancel: { model.renameFiles = nil })
        }
        .aomToast(model.toasts)
    }
}

struct RenameFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// 7.2.2 (audit N01): Batch Rename with presets and every new name shown
/// before anything moves.
struct BatchRenameSheet: View {
    let urls: [URL]
    let onRename: ([BatchRename.Row]) -> Void
    let onCancel: () -> Void
    @State private var preset = "replace"
    @State private var find = ""
    @State private var template = ""
    @State private var start = 1
    @FocusState private var focus: Field?
    private enum Field { case find, template }

    private var rows: [BatchRename.Row] { BatchRename.plan(urls, find: find, template: template, startingNumber: start) }

    var body: some View {
        let rows = self.rows
        let problems = rows.filter { $0.problem != nil }.count
        let changing = rows.filter(\.changes).count
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack {
                Text("Rename \(urls.count) File\(urls.count == 1 ? "" : "s")").font(AOMFont.title)
                Spacer()
                Picker("Preset", selection: $preset) {
                    ForEach(BatchRename.presets) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: preset) { _, id in
                    guard let chosen = BatchRename.presets.first(where: { $0.id == id }) else { return }
                    find = chosen.find
                    template = chosen.replace
                    focus = chosen.find.isEmpty && chosen.replace.isEmpty ? .find : .template
                }
            }
            Grid(alignment: .leading, horizontalSpacing: AOMSpace.x2, verticalSpacing: AOMSpace.x2) {
                GridRow {
                    Text("Find").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    TextField("Text to replace (empty: the whole name)", text: $find).focused($focus, equals: .find)
                }
                GridRow {
                    Text("New").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    TextField("Replacement or name, e.g. {name} {n}", text: $template).focused($focus, equals: .template)
                }
                GridRow {
                    Text("Start at").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    Stepper(value: $start, in: 0...99_999) { Text("\(start)").monospacedDigit() }
                        .fixedSize()
                }
            }
            Text("{name} the old name · {n} 1, 2, 3 · {nn} 01, 02 · {date} today. Extensions stay.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            List(rows) { row in
                HStack(spacing: AOMSpace.x2) {
                    Text(row.source.lastPathComponent)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(AOMColor.textTertiary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.newName)
                            .foregroundStyle(row.problem != nil ? AOMColor.dangerText : (row.changes ? AOMColor.text : AOMColor.textTertiary))
                            .lineLimit(1).truncationMode(.middle)
                        if let problem = row.problem {
                            Text(problem).font(AOMFont.caption).foregroundStyle(AOMColor.dangerText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AOMFont.body)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)
            HStack {
                Text(problems > 0 ? "\(problems) name\(problems == 1 ? " needs" : "s need") a change; nothing is renamed until all are fine."
                     : "\(changing) of \(rows.count) change. Undo puts them back.")
                    .font(AOMFont.caption)
                    .foregroundStyle(problems > 0 ? AOMColor.dangerText : AOMColor.textSecondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onRename(rows) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AOMPrimaryButtonStyle())
                    .disabled(problems > 0 || changing == 0)
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: 620, height: 480)
        .onAppear { focus = .find }
    }
}

struct PDFComparison: Identifiable {
    struct Option: Identifiable {
        var id: String { mode.rawValue }
        let mode: MacMagicSystemToolService.PDFCompression
        let file: URL
        let size: Int64
    }

    let id = UUID()
    let source: URL
    let originalSize: Int64
    let options: [Option]
    /// The temporary folder both versions were written to.
    let folder: URL

    /// Pure: "−62%", or nil when it isn't smaller.
    static func saving(original: Int64, compressed: Int64) -> String? {
        guard original > 0, compressed < original else { return nil }
        let percent = Int((Double(original - compressed) / Double(original) * 100).rounded())
        return percent == 0 ? "<1% smaller" : "\(percent)% smaller"
    }
}

/// 7.2.2 (audit N02): the two compressions side by side.
struct PDFComparisonSheet: View {
    let comparison: PDFComparison
    let onSave: (PDFComparison.Option?) -> Void

    private var best: String? {
        comparison.options.filter { $0.size < comparison.originalSize }
            .first { $0.mode == .keepText && Double($0.size) < Double(comparison.originalSize) * 0.9 }?.id
            ?? comparison.options.filter { $0.size < comparison.originalSize }.min { $0.size < $1.size }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text("Compress “\(comparison.source.lastPathComponent)”").font(AOMFont.title).lineLimit(1).truncationMode(.middle)
            Text("Now \(SystemStatus.size(comparison.originalSize)). Save the one you want; it goes next to the original, which stays as it is.")
                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(comparison.options) { option in
                let saving = PDFComparison.saving(original: comparison.originalSize, compressed: option.size)
                HStack(alignment: .top, spacing: AOMSpace.x3) {
                    Image(systemName: option.mode == .keepText ? "doc.text" : "photo.on.rectangle")
                        .font(.system(size: 18)).foregroundStyle(AOMColor.textSecondary).frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        HStack(spacing: AOMSpace.x1) {
                            Text(option.mode.title).font(AOMFont.bodyEmphasis)
                            if option.id == best { AOMStatusPill("Suggested", tone: .success) }
                        }
                        Text(option.mode.detail).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        Text("\(SystemStatus.size(option.size)) · \(saving ?? "not smaller")")
                            .font(AOMFont.callout.monospacedDigit())
                            .foregroundStyle(saving == nil ? AOMColor.warningText : AOMColor.text)
                    }
                    Spacer(minLength: AOMSpace.x2)
                    Button("Save") { onSave(option) }
                        .buttonStyle(AOMPrimaryButtonStyle())
                        .disabled(saving == nil)
                }
                .padding(AOMSpace.x3)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AOMColor.text.opacity(0.04)))
            }
            HStack {
                Spacer()
                Button("Cancel") { onSave(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: 480)
    }
}
