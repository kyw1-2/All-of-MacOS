import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The 3.4.0 tools: Homebrew (a sheet with its own job runner), VPN and
/// Tailscale, the PDF page tools, the Metal HUD switch, and the app
/// uninstaller's review after design-3.4.0 b.16. Same rules as the rest of
/// the page: every PDF tool writes a new file and never changes the
/// original, anything that removes or installs asks first, success only
/// after the result was checked.
extension SystemToolsModel {
    nonisolated static let tools340: Set<SystemToolID> = [
        .brewOutdated, .brewUpgradeAll, .brewInstalled, .brewUpdate, .brewCleanup, .brewDoctor, .brewServices, .brewSearch,
        .vpn, .tailscale, .openVPN,
        .pdfSplit, .pdfExtract, .pdfRemovePages, .pdfRotate, .pdfReorder, .imagesToPDF, .pdfToImages, .pdfProtect, .pdfUnlock,
        .pdfPageNumbers, .metalHUD
    ]

    func run340(_ id: SystemToolID) {
        let brew = HomebrewModel.shared
        switch id {
        case .brewOutdated: brew.present(.outdated, refresh: true)
        case .brewUpgradeAll: brew.present(.outdated, refresh: false); brew.whenIdle { brew.requestUpgradeAll() }
        case .brewInstalled: brew.present(.installed, refresh: true)
        case .brewUpdate: brew.present(.outdated, refresh: false); brew.whenIdle { brew.update() }
        case .brewCleanup: brew.present(.outdated, refresh: false); brew.whenIdle { brew.cleanUp() }
        case .brewDoctor: brew.present(.outdated, refresh: false); brew.whenIdle { brew.doctor() }
        case .brewServices: brew.present(.services, refresh: true)
        case .brewSearch: brew.present(.search, refresh: false)
        case .vpn: VPNModel.shared.present()
        case .tailscale: tailscaleMenu()
        case .openVPN: openOpenVPNConnect()
        case .pdfSplit: splitPDF()
        case .pdfExtract: pagesTool(.pdfExtract)
        case .pdfRemovePages: pagesTool(.pdfRemovePages)
        case .pdfRotate: rotatePDF()
        case .pdfReorder: pagesTool(.pdfReorder)
        case .imagesToPDF: imagesToPDF()
        case .pdfToImages: pdfToImages()
        case .pdfProtect: protectPDF()
        case .pdfUnlock: unlockPDF()
        case .pdfPageNumbers: addPageNumbers()
        case .metalHUD: toggleMetalHUD()
        default: break
        }
    }

    // MARK: - States

    /// Cheap states, on the main thread with the others.
    func refresh340States(into next: inout [SystemToolID: SystemToolState]) {
        if let outdated = HomebrewModel.shared.outdated {
            next[.brewOutdated] = outdated.isEmpty ? .on("Up to date") : .value("\(outdated.count) to upgrade")
        }
        if let services = VPNModel.shared.lastServices {
            next[.vpn] = Self.vpnState(services)
        }
        if let status = VPNModel.shared.tailscale {
            next[.tailscale] = Self.tailscaleState(status)
        }
    }

    nonisolated static func vpnState(_ services: [VPNTools.Service]) -> SystemToolState {
        let up = services.filter { $0.state == .connected }
        if up.count == 1 { return .on(DisplaySoundState.shortName(up[0].name, limit: 14)) }
        if up.count > 1 { return .on("\(up.count) on") }
        if services.contains(where: { $0.state == .connecting }) { return .value("Connecting") }
        return services.isEmpty ? .value("None") : .off()
    }

    nonisolated static func tailscaleState(_ status: VPNTools.TailscaleStatus) -> SystemToolState {
        switch status.backend {
        case .running: return .on(status.ipv4 ?? "On")
        case .stopped: return .off()
        case .needsLogin: return .value("Log In")
        case .starting: return .value("Starting")
        default: return .value(status.backend.title)
        }
    }

    /// Helper-process states read with the other slow ones (off the main
    /// thread): the Metal HUD variable and the VPN list. Tailscale's CLI is
    /// asked at most every 20 s.
    nonisolated static func slow340States() -> [SystemToolID: SystemToolState] {
        var slow: [SystemToolID: SystemToolState] = [:]
        if let output = try? SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments) {
            slow[.metalHUD] = SystemToolState(MetalHUD.isOn(getenvOutput: output.stdout))
        }
        return slow
    }

    // MARK: - Metal HUD

    func toggleMetalHUD() {
        let wasOn = states[.metalHUD] == .on()
        runInBackground(.metalHUD, { () -> Bool in
            try SystemToolsCommand.runChecked(MetalHUD.launchctl.path, MetalHUD.writeArguments(on: !wasOn))
            let check = try SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments)
            return MetalHUD.isOn(getenvOutput: check.stdout)
        }) { isOn in
            self.slowStates[.metalHUD] = SystemToolState(isOn)
            guard isOn != wasOn else {
                self.fail(.metalHUD, "Metal HUD Not Changed", "launchctl ran, but MTL_HUD_ENABLED is still \(wasOn ? "set" : "unset").")
                return
            }
            self.succeed(.metalHUD, isOn ? "Metal HUD on for apps you open from now on (apps already open don't change)"
                                         : "Metal HUD off for apps you open from now on")
        }
    }

    // MARK: - VPN

    func tailscaleMenu() {
        let vpn = VPNModel.shared
        let menu = NSMenu()
        let status = vpn.tailscale
        if let status {
            menu.addItem(headerItem("Tailscale: \(status.backend.title)" + (status.tailnet.map { " · \($0)" } ?? "")))
            switch status.backend {
            case .running:
                menu.addItem(SystemToolMenuItem(title: "Disconnect") { vpn.setTailscale(up: false) })
            case .stopped:
                menu.addItem(SystemToolMenuItem(title: "Connect") { vpn.setTailscale(up: true) })
            default:
                menu.addItem(SystemToolMenuItem(title: "Log In with the Tailscale App…") { vpn.openTailscaleApp() })
            }
            if let ip = status.ipv4 {
                menu.addItem(SystemToolMenuItem(title: "Copy \(ip)") { self.copy(.tailscale, ip, message: "Copied \(ip)") })
            }
            menu.addItem(headerItem("Exit node: " + (status.exitNode ?? "None")))
        } else {
            menu.addItem(headerItem("Reading Tailscale…"))
        }
        menu.addItem(.separator())
        menu.addItem(SystemToolMenuItem(title: "Open Tailscale") { vpn.openTailscaleApp() })
        menu.addItem(SystemToolMenuItem(title: "VPN Connections…") { vpn.present() })
        popUp(menu)
        vpn.refreshTailscale(force: true)
    }

    func openOpenVPNConnect() {
        guard let url = VPNTools.openVPNConnectURL() else {
            fail(.openVPN, "OpenVPN Connect Isn't Installed", "Install OpenVPN Connect, then open it from here.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if app != nil { self.lastResult = ToolResult(tool: .openVPN, message: "Opened OpenVPN Connect", succeeded: true, date: Date()) }
                else { self.fail(.openVPN, "OpenVPN Connect Didn't Open", message ?? "macOS didn't open it.") }
            }
        }
    }

    func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - PDF page tools

    private func pickPDF(_ message: String) -> URL? {
        pickFiles(types: [UTType.pdf], multiple: false, message: message)?.first
    }

    private func pageCount(_ url: URL, tool: SystemToolID) -> Int? {
        do { return try PDFTools.open(url).pageCount }
        catch { fail(tool, error); return nil }
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
            fail(.pdfSplit, "Original Not Replaced", "Choose another name; the PDF tools never overwrite the original.")
            return nil
        }
        return url
    }

    private func pickOutputFolder(near source: URL, message: String) -> URL? {
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

    func splitPDF() {
        guard let url = pickPDF("Choose the PDF to split."), let count = pageCount(url, tool: .pdfSplit) else { return }
        let menu = NSMenu()
        menu.addItem(headerItem("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        menu.addItem(SystemToolMenuItem(title: "Every Page as Its Own PDF…") {
            guard let folder = self.pickOutputFolder(near: url, message: "Choose where the \(count) single-page PDFs go.") else { return }
            self.runInBackground(.pdfSplit, { try PDFTools.splitIntoPages(url, into: folder) }) { outputs in
                self.succeed(.pdfSplit, "Saved \(outputs.count) PDF\(outputs.count == 1 ? "" : "s") in \(folder.lastPathComponent)")
            }
        })
        menu.addItem(SystemToolMenuItem(title: "By Ranges…") {
            guard let ranges = self.promptText("Split PDF", "One PDF per range, separated by commas (\(count) pages), for example 1-3, 4-6, 7-",
                                               placeholder: "1-3, 4-6, 7-"), !ranges.isEmpty else { return }
            do { _ = try PageRanges.groups(ranges, pageCount: count) } catch { self.fail(.pdfSplit, "Ranges Not Understood", error.localizedDescription); return }
            guard let folder = self.pickOutputFolder(near: url, message: "Choose where the PDFs go.") else { return }
            self.runInBackground(.pdfSplit, { try PDFTools.split(url, ranges: ranges, into: folder) }) { outputs in
                self.succeed(.pdfSplit, "Saved \(outputs.count) PDF\(outputs.count == 1 ? "" : "s") in \(folder.lastPathComponent)")
            }
        })
        popUp(menu)
    }

    /// Extract, Remove and Reorder: pick a PDF, type pages, save a copy.
    func pagesTool(_ id: SystemToolID) {
        let (verb, prompt, placeholder, suffix): (String, String, String, String)
        switch id {
        case .pdfExtract: (verb, prompt, placeholder, suffix) = ("Extract Pages", "Pages to keep, in the order you want them", "1-3, 5", "pages")
        case .pdfRemovePages: (verb, prompt, placeholder, suffix) = ("Remove Pages", "Pages to leave out", "2, 4-5", "pages removed")
        default: (verb, prompt, placeholder, suffix) = ("Reorder Pages", "The new order; pages you leave out follow in their old order", "3, 1-2", "reordered")
        }
        guard let url = pickPDF("Choose the PDF."), let count = pageCount(url, tool: id) else { return }
        guard let text = promptText(verb, "\(prompt). The PDF has \(count) page\(count == 1 ? "" : "s"); 8- means 8 to the end.",
                                    placeholder: placeholder), !text.isEmpty else { return }
        do {
            switch id {
            case .pdfRemovePages:
                let removed = try PageRanges.set(text, pageCount: count)
                guard removed.count < count else {
                    fail(id, "Nothing Would Be Left", "Those are all \(count) pages; at least one has to stay."); return
                }
            case .pdfReorder: _ = try PageRanges.reorder(text, pageCount: count)
            default: _ = try PageRanges.pages(text, pageCount: count)
            }
        } catch { fail(id, "Pages Not Understood", error.localizedDescription); return }
        let label = id == .pdfExtract ? "pages \(PageRanges.describe((try? PageRanges.pages(text, pageCount: count)) ?? []))" : suffix
        guard let output = saveURL(for: url, suffix: label) else { return }
        runInBackground(id, { () -> String in
            switch id {
            case .pdfExtract:
                let pages = try PDFTools.extract(url, pages: text, to: output)
                return "Saved \(pages) page\(pages == 1 ? "" : "s") as \(output.lastPathComponent)"
            case .pdfRemovePages:
                let left = try PDFTools.remove(url, pages: text, to: output)
                return "Saved \(output.lastPathComponent) with \(left) of \(count) pages"
            default:
                let order = try PDFTools.reorder(url, order: text, to: output)
                return "Saved \(output.lastPathComponent) in the order \(PageRanges.describe(Array(order.prefix(8))))\(order.count > 8 ? "…" : "")"
            }
        }) { message in self.succeed(id, message) }
    }

    func rotatePDF() {
        guard let url = pickPDF("Choose the PDF to rotate."), let count = pageCount(url, tool: .pdfRotate) else { return }
        let menu = NSMenu()
        menu.addItem(headerItem("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for (title, degrees) in [("90° Right…", 90), ("90° Left…", -90), ("180°…", 180)] {
            menu.addItem(SystemToolMenuItem(title: title) {
                guard let text = self.promptText("Rotate Pages \(title.replacingOccurrences(of: "…", with: ""))",
                                                 "Pages to rotate; leave empty for every page (\(count)).", placeholder: "all") else { return }
                let trimmed = text.lowercased() == "all" ? "" : text
                if !trimmed.isEmpty {
                    do { _ = try PageRanges.set(trimmed, pageCount: count) }
                    catch { self.fail(.pdfRotate, "Pages Not Understood", error.localizedDescription); return }
                }
                guard let output = self.saveURL(for: url, suffix: "rotated") else { return }
                self.runInBackground(.pdfRotate, { try PDFTools.rotate(url, pages: trimmed, degrees: degrees, to: output) }) { turned in
                    self.succeed(.pdfRotate, "Turned \(turned) page\(turned == 1 ? "" : "s") in \(output.lastPathComponent)")
                }
            })
        }
        popUp(menu)
    }

    func imagesToPDF() {
        guard let images = pickFiles(types: [.image], multiple: true, message: "Choose the images; each becomes one page, in name order."),
              !images.isEmpty else { return }
        let sorted = images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let menu = NSMenu()
        menu.addItem(headerItem("\(sorted.count) image\(sorted.count == 1 ? "" : "s")"))
        for size in PDFTools.PageSize.allCases {
            menu.addItem(SystemToolMenuItem(title: size.title + "…") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.directoryURL = sorted[0].deletingLastPathComponent()
                panel.nameFieldStringValue = sorted.count == 1 ? sorted[0].deletingPathExtension().lastPathComponent + ".pdf" : "Images.pdf"
                guard panel.runModal() == .OK, let output = panel.url else { return }
                self.runInBackground(.imagesToPDF, { try PDFTools.imagesToPDF(sorted, pageSize: size, to: output) }) { pages in
                    let skipped = sorted.count - pages
                    self.succeed(.imagesToPDF, "Saved \(output.lastPathComponent) with \(pages) page\(pages == 1 ? "" : "s")"
                                 + (skipped > 0 ? " (\(skipped) file\(skipped == 1 ? "" : "s") weren't readable images)" : ""))
                }
            })
        }
        popUp(menu)
    }

    func pdfToImages() {
        guard let url = pickPDF("Choose the PDF; every page becomes an image."), let count = pageCount(url, tool: .pdfToImages) else { return }
        let menu = NSMenu()
        menu.addItem(headerItem("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for format in PDFTools.ImageFormat.allCases {
            for dpi in PDFTools.dpiChoices {
                menu.addItem(SystemToolMenuItem(title: "\(format.title) at \(dpi) dpi…") {
                    guard let folder = self.pickOutputFolder(near: url, message: "Choose where the \(count) images go.") else { return }
                    self.toast = "Rendering \(count) page\(count == 1 ? "" : "s") at \(dpi) dpi…"
                    self.runInBackground(.pdfToImages, { try PDFTools.pdfToImages(url, format: format, dpi: dpi, into: folder) }) { outputs in
                        guard !outputs.isEmpty else { self.fail(.pdfToImages, "No Images Saved", "No page could be rendered."); return }
                        self.succeed(.pdfToImages, "Saved \(outputs.count) \(format.title) image\(outputs.count == 1 ? "" : "s") in \(folder.lastPathComponent)")
                    }
                })
            }
            if format != PDFTools.ImageFormat.allCases.last { menu.addItem(.separator()) }
        }
        popUp(menu)
    }

    func protectPDF() {
        guard let url = pickPDF("Choose the PDF to protect.") else { return }
        guard let document = PDFDocument(url: url) else { fail(.pdfProtect, PDFTools.Failure.unreadable(url.lastPathComponent)); return }
        guard !document.isEncrypted else {
            fail(.pdfProtect, "Already Protected", "“\(url.lastPathComponent)” already has a password. Remove it first to set a new one."); return
        }
        guard let password = promptPassword(title: "Add a Password", message: "People need this password to open the copy. AOM doesn't keep it, so note it somewhere safe.",
                                            confirm: true) else { return }
        guard let output = saveURL(for: url, suffix: "protected") else { return }
        runInBackground(.pdfProtect, { try PDFTools.protect(url, password: password, to: output) }) { _ in
            self.succeed(.pdfProtect, "Saved \(output.lastPathComponent); it asks for the password")
        }
    }

    func unlockPDF() {
        guard let url = pickPDF("Choose the password-protected PDF.") else { return }
        guard let document = PDFDocument(url: url) else { fail(.pdfUnlock, PDFTools.Failure.unreadable(url.lastPathComponent)); return }
        guard document.isEncrypted else { fail(.pdfUnlock, PDFTools.Failure.notEncrypted(url.lastPathComponent)); return }
        guard let password = promptPassword(title: "Remove the Password", message: "Type the password that opens “\(url.lastPathComponent)”.",
                                            confirm: false) else { return }
        guard document.unlock(withPassword: password) else { fail(.pdfUnlock, PDFTools.Failure.wrongPassword); return }
        guard let output = saveURL(for: url, suffix: "unlocked") else { return }
        runInBackground(.pdfUnlock, { try PDFTools.unprotect(url, password: password, to: output) }) { _ in
            self.succeed(.pdfUnlock, "Saved \(output.lastPathComponent) without a password")
        }
    }

    func addPageNumbers() {
        guard let url = pickPDF("Choose the PDF to number."), let count = pageCount(url, tool: .pdfPageNumbers) else { return }
        let menu = NSMenu()
        menu.addItem(headerItem("\(url.lastPathComponent) · \(count) page\(count == 1 ? "" : "s")"))
        for position in PDFTools.NumberPosition.allCases {
            for style in PDFTools.NumberStyle.allCases {
                let sample = style.text(page: 1, total: count)
                menu.addItem(SystemToolMenuItem(title: "\(position.title): \(sample)…") {
                    guard let output = self.saveURL(for: url, suffix: "numbered") else { return }
                    self.runInBackground(.pdfPageNumbers, { try PDFTools.addPageNumbers(url, position: position, style: style, to: output) }) { pages in
                        self.succeed(.pdfPageNumbers, "Numbered \(pages) page\(pages == 1 ? "" : "s") in \(output.lastPathComponent)")
                    }
                })
            }
        }
        popUp(menu)
    }

    /// A secure field (and a second one to confirm). Never logged or kept.
    func promptPassword(title: String, message: String, confirm: Bool) -> String? {
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
        guard !password.isEmpty else { fail(confirm ? .pdfProtect : .pdfUnlock, "No Password", "Type a password, then try again."); return nil }
        if confirm && password != second.stringValue {
            fail(.pdfProtect, "Passwords Don't Match", PDFTools.Failure.passwordsDiffer.localizedDescription); return nil
        }
        return password
    }

    // MARK: - App uninstaller (design-3.4.0 b.16)

    /// Choose an app (or drop one on the tile), quit it after asking if it
    /// is running, then review it with its leftovers grouped by folder.
    func uninstallApp(_ dropped: URL? = nil) {
        let app: URL
        if let dropped {
            app = dropped
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Review"
            panel.message = "Choose an app. You'll see it with its leftovers before anything moves to the Trash."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            app = url
        }
        guard let bundleID = Bundle(url: app)?.bundleIdentifier else {
            fail(.uninstall, CleanupTools.UninstallRefusal.notAnApp); return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard !running.isEmpty else { reviewUninstall(app); return }
        let name = running.first?.localizedName ?? app.deletingPathExtension().lastPathComponent
        guard confirm("Quit \(name) First?", "\(name) is open. AOM asks it to quit the normal way (it can still ask to save), then shows what would move to the Trash.",
                      button: "Quit and Review", destructive: false) else { return }
        running.forEach { $0.terminate() }
        self.running.insert(.uninstall)
        waitForQuit(running, app: app, name: name, triesLeft: 20)
    }

    private func waitForQuit(_ apps: [NSRunningApplication], app: URL, name: String, triesLeft: Int) {
        if apps.allSatisfy(\.isTerminated) {
            running.remove(.uninstall)
            reviewUninstall(app)
        } else if triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForQuit(apps, app: app, name: name, triesLeft: triesLeft - 1) }
        } else {
            running.remove(.uninstall)
            fail(.uninstall, "\(name) Didn't Quit", "\(name) is still open, probably asking about unsaved work. Nothing was moved.")
        }
    }

    private func reviewUninstall(_ app: URL) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.uninstall, { try CleanupTools.uninstallReview(for: app, library: library) }) { review in
            let name = app.deletingPathExtension().lastPathComponent
            let nameOnly = review.items.count - review.preselected.count
            self.cleanupReview = CleanupReview(
                tool: .uninstall, title: "Uninstall \(name)",
                detail: "The app and the files it left in ~/Library, by folder. Files named with its bundle ID are checked"
                    + (nameOnly > 0 ? "; \(nameOnly) that only share its name are not, because other apps may use them" : "")
                    + ". Everything goes to the Trash, so Finder's Put Back works.",
                candidates: review.items, selected: review.preselected, groupsByNote: true, safeDefault: true,
                hints: Dictionary(uniqueKeysWithValues: review.nameOnly.map { ($0, "Matches the app's name only; check it if it's this app's") }))
        }
    }
}
