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
        run(.pdfMerge, { try self.service.combinePDFs(urls: urls, to: destination); return "Merged \(urls.count) PDFs" }) { self.succeed($0) }
    }

    private func compressPDF() {
        guard let url = pickFiles(types: [UTType.pdf], multiple: false, message: nil)?.first else { return }
        let destination = url.deletingPathExtension().appendingPathExtension("compressed.pdf")
        run(.pdfCompress, {
            try self.service.compressPDF(url: url, to: destination)
            let original = CleanupTools.allocatedSize(url), compressed = CleanupTools.allocatedSize(destination)
            return "Compressed: \(SystemStatus.size(original)) → \(SystemStatus.size(compressed))"
        }) { self.succeed($0) }
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
        let alert = NSAlert()
        alert.messageText = "Rename \(urls.count) File\(urls.count == 1 ? "" : "s")"
        alert.informativeText = "Replaces text in each name (extensions stay). {n} in the replacement becomes 1, 2, 3…"
        let find = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        find.placeholderString = "Find"
        let replace = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        replace.placeholderString = "Replace with"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        stack.addSubview(find); stack.addSubview(replace)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = find
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !find.stringValue.isEmpty || replace.stringValue.contains("{n}") else {
            fail("Nothing to Rename", "Type the text to find, or use {n} in the replacement."); return
        }
        do {
            let renamed = try service.batchRename(urls: urls, pattern: find.stringValue, replacement: replace.stringValue)
            succeed("Renamed \(renamed.count) file\(renamed.count == 1 ? "" : "s")")
        } catch { fail("Files Not Renamed", "No file was renamed: \(error.localizedDescription)") }
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
        .aomToast(model.toasts)
    }
}
