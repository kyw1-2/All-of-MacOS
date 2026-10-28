import SwiftUI
import UniformTypeIdentifiers

/// The System Tools page — MacMagic's toolbox as a grid of tool cards,
/// grouped by category: Finder & Network, PDF & Media, Cleanup.
/// Sidebar-only (the menu bar stays lean); every tool is one click and
/// collects its own inputs via panels.
struct SystemToolsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showGroups = false
    @State private var showActionLibrary = false
    private let service = MacMagicSystemToolService.shared
    @State private var toast: String?
    @State private var query = ""

    private struct Tool: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let run: () -> Void
    }

    /// The groups filtered by the toolbar search (title or group name), empty
    /// groups dropped so a narrow search reads as one short list.
    private var visibleGroups: [(name: String, symbol: String, tools: [Tool])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group -> (name: String, symbol: String, tools: [Tool])? in
            if group.name.localizedCaseInsensitiveContains(needle) { return group }
            let tools = group.tools.filter { $0.title.localizedCaseInsensitiveContains(needle) }
            return tools.isEmpty ? nil : (name: group.name, symbol: group.symbol, tools: tools)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.m) {
                if showActionLibrary {
                    AOMSectionCard("All Actions", symbol: "square.grid.3x3", accessory: {
                        Button("Hide") { showActionLibrary = false }.controlSize(.small)
                    }) {
                        ActionLibraryView().environmentObject(appState)
                    }
                }
                let shown = visibleGroups
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("No Tools Match “\(query)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try another word, or browse every action AOM can run.")
                    } actions: {
                        Button("Clear Search") { query = "" }
                        Button("All Actions") { query = ""; showActionLibrary = true }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(shown, id: \.name) { group in
                    AOMSectionCard(group.name, symbol: group.symbol, detail: "\(group.tools.count)") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: AOMSpace.s)],
                                  spacing: AOMSpace.s) {
                            ForEach(group.tools) { tool in
                                ToolCard(title: tool.title, symbol: tool.symbol, tint: tool.tint, run: tool.run)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: AOMSize.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, AOMSpace.l)
            .padding(.vertical, AOMSpace.m)
            .frame(maxWidth: .infinity)
        }
        .aomScrollEdge()
        .aomPage("System Tools", subtitle: "Finder, network, PDF, media and file utilities")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Tools")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showActionLibrary.toggle() } label: {
                    Label(showActionLibrary ? "Hide All Actions" : "All Actions", systemImage: "square.grid.3x3")
                }
                .help("Browse every action AOM can run")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Floating Menus & Widgets…", systemImage: "menubar.dock.rectangle") { FloatingMenuController.shared.edit() }
                    Button("Conditional Activation Groups…", systemImage: "square.stack.3d.up") { showGroups = true }
                } label: { Label("Automation Tools", systemImage: "wand.and.stars") }
                .help("Floating menus and activation groups")
            }
        }
        .aomToast(toast)
        .sheet(isPresented: $showGroups) { ActivationGroupsEditor().environmentObject(appState) }
        .onChange(of: toast) { _, message in
            guard message != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                toast = nil
            }
        }
    }

    // MARK: - Tool groups

    private var groups: [(name: String, symbol: String, tools: [Tool])] {
        [
            // One section for the four quick system switches: a "Network"
            // card holding a single tool cost a whole section of height.
            ("Finder & Network", "folder", [
                Tool(id: "hidden", title: "Hidden Files", symbol: "eye.trianglebadge.exclamationmark", tint: .blue) {
                    Task {
                        do { let next = try await service.toggleHiddenFiles(); toast = next ? "Hidden files shown" : "Hidden files hidden" }
                        catch { reportFailure("Hidden Files Not Changed", error.localizedDescription) }
                    }
                },
                Tool(id: "desktop", title: "Desktop Icons", symbol: "menubar.rectangle", tint: .blue) {
                    Task {
                        do { let next = try await service.toggleDesktopIcons(); toast = next ? "Desktop icons shown" : "Desktop icons hidden" }
                        catch { reportFailure("Desktop Icons Not Changed", error.localizedDescription) }
                    }
                },
                Tool(id: "finder", title: "Restart Finder", symbol: "arrow.clockwise", tint: .blue) {
                    Task { await service.restartFinder(); toast = "Finder restarted" }
                },
                Tool(id: "dns", title: "Flush DNS", symbol: "network", tint: .indigo) { flushDNS() }
            ]),
            ("PDF & Media", "doc.richtext", [
                Tool(id: "pdfmerge", title: "Merge PDFs", symbol: "doc.badge.plus", tint: .orange) { mergePDFs() },
                Tool(id: "pdfcompress", title: "Compress PDF", symbol: "doc.badge.gearshape", tint: .orange) { compressPDF() },
                Tool(id: "imageconvert", title: "Convert Image", symbol: "photo.badge.arrow.down", tint: .orange) { convertImage() },
                Tool(id: "videoconvert", title: "Convert Video", symbol: "film", tint: .orange) { convertVideo() },
                Tool(id: "qr", title: "QR Code", symbol: "qrcode", tint: .orange) { makeQR() }
            ]),
            ("Cleanup", "sparkles", [
                Tool(id: "cache", title: "Clear Caches", symbol: "paintbrush", tint: .teal) {
                    Task {
                        do {
                            let freed = try await Task.detached { try MacMagicSystemToolService.shared.clearDiskCache() }.value
                            toast = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
                        } catch { toast = error.localizedDescription }
                    }
                },
                Tool(id: "dsstore", title: "Erase .DS_Store", symbol: "trash.slash", tint: .teal) { eraseDSStore() },
                Tool(id: "trash", title: "Empty Trash", symbol: "trash.fill", tint: .red) { confirmEmptyTrash() }
            ])
        ]
    }

    // MARK: - Tool flows

    private func mergePDFs() {
        guard let urls = pickFiles(types: [UTType.pdf], multiple: true), urls.count >= 2 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try service.combinePDFs(urls: urls, to: destination)
            toast = "Merged \(urls.count) PDFs"
        } catch { toast = error.localizedDescription }
    }

    private func compressPDF() {
        guard let url = pickFiles(types: [UTType.pdf], multiple: false)?.first else { return }
        let destination = url.deletingPathExtension().appendingPathExtension("compressed.pdf")
        do {
            try service.compressPDF(url: url, to: destination)
            let original = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let compressed = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            toast = "Compressed: \(ByteCountFormatter.string(fromByteCount: original, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: compressed, countStyle: .file))"
        } catch { toast = error.localizedDescription }
    }

    private func convertImage() {
        guard let url = pickFiles(types: [UTType.image], multiple: false)?.first else { return }
        let menu = NSMenu()
        for format in MacMagicSystemToolService.ImageFormat.allCases {
            menu.addItem(ClosureMenuItem(title: "→ \(format.rawValue.uppercased())") {
                do {
                    let output = try service.convertImage(url: url, to: format)
                    toast = "Saved \(output.lastPathComponent)"
                } catch { toast = error.localizedDescription }
            })
        }
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func makeQR() {
        let alert = NSAlert()
        alert.messageText = "QR Code"
        alert.informativeText = "Text or URL to encode:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let image = service.generateQRCode(text: field.stringValue) else { toast = "Could not generate"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "QR.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            do { try png.write(to: url); toast = "QR saved" }
            catch { toast = error.localizedDescription }
        }
    }

    private func convertVideo() {
        guard let url = pickFiles(types: [UTType.movie, UTType.mpeg4Movie], multiple: false)?.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-converted.mp4"
        guard panel.runModal() == .OK, let destination = panel.url,
              destination.standardizedFileURL != url.standardizedFileURL else { return }
        Task {
            do {
                try await service.convertVideo(url: url, to: destination)
                await MainActor.run { toast = "Video converted" }
            } catch {
                await MainActor.run { toast = error.localizedDescription }
            }
        }
    }

    private func eraseDSStore() {
        guard let folder = pickFolder() else { return }
        Task {
            do { let count = try await service.eraseDSStoreFiles(in: folder); toast = "\(count) .DS_Store removed" }
            catch { toast = error.localizedDescription }
        }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Items in your Trash will be permanently deleted."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let result = try await service.forceEmptyTrash()
                if result.succeeded { toast = result.summary } else { reportFailure("Trash Not Fully Emptied", result.summary) }
            } catch { reportFailure("Trash Not Emptied", error.localizedDescription) }
        }
    }

    /// Success only when every step exited 0. A standard user cannot restart
    /// the DNS resolver; that is said, with the administrator prompt as the
    /// way forward, instead of a "flushed" toast for a flush that did not
    /// happen (audit 2026-10-28 F09).
    private func flushDNS() {
        Task {
            do {
                try await service.flushDNSCache()
                toast = "DNS cache flushed"
            } catch let error as SystemToolError where error.needsAdministrator {
                offerAdministratorFlush(error)
            } catch {
                reportFailure("DNS Cache Not Flushed", error.localizedDescription)
            }
        }
    }

    private func offerAdministratorFlush(_ error: SystemToolError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Flush DNS Needs an Administrator"
        alert.informativeText = "macOS refused part of the flush (\(error.localizedDescription)), so the DNS cache is not fully flushed. Flush it with an administrator password?"
        alert.addButton(withTitle: "Use Administrator Password…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { toast = "DNS cache not flushed"; return }
        switch service.flushDNSCacheAsAdministrator() {
        case .done: toast = "DNS cache flushed"
        case .cancelled: toast = "DNS cache not flushed"
        case .failed(let message): reportFailure("DNS Cache Not Flushed", message)
        }
    }

    /// Failures that need reading stay on screen until dismissed.
    private func reportFailure(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Pickers

    private func pickFiles(types: [UTType], multiple: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// One tool tile: the glyph carries the group's hue (no decorative gradient
/// squircle — colour stays for meaning, as with `AOMIconBadge` elsewhere).
private struct ToolCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 8) {
                AOMIconBadge(systemImage: symbol, tint: tint, size: 34, filled: true)
                Text(title)
                    .font(AOMType.caption.weight(.medium))
                    .foregroundStyle(AOMTheme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(hovering ? AOMTheme.track : AOMTheme.cardAlt.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: AOMRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// An NSMenuItem that runs a closure — the AppKit bridge for SwiftUI-
/// triggered choice menus.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is created in code only")
    }

    @objc private func runHandler() { handler() }
}
