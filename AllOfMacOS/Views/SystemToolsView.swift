import SwiftUI
import UniformTypeIdentifiers

/// The System Tools page — MacMagic's toolbox as a grid of tool cards,
/// grouped by category: Finder, Network & System, PDF & Media, Files.
/// Sidebar-only (the menu bar stays lean); every tool is one click and
/// collects its own inputs via panels.
struct SystemToolsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showGroups = false
    @State private var showActionLibrary = false
    private let service = MacMagicSystemToolService.shared
    @State private var toast: String?

    private struct Tool: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let run: () -> Void
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.l) {
                HStack(spacing: 12) {
                    Button("Floating Menus & Widgets…") { FloatingMenuController.shared.edit() }
                    Button("Conditional Activation Groups…") { showGroups = true }
                    Button(showActionLibrary ? "Hide All Actions" : "Browse All Actions") { showActionLibrary.toggle() }
                }
                if showActionLibrary { ActionLibraryView().environmentObject(appState) }
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: AOMSpace.s) {
                        Text(group.name.uppercased())
                            .font(AOMType.caption.weight(.semibold))
                            .foregroundStyle(AOMTheme.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AOMSpace.m)],
                                  spacing: AOMSpace.m) {
                            ForEach(group.tools) { tool in
                                ToolCard(title: tool.title, symbol: tool.symbol, tint: tool.tint, run: tool.run)
                            }
                        }
                    }
                }
            }
            .padding(AOMSpace.xl)
        }
        .background(AOMTheme.workspace)
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

    private var groups: [(name: String, tools: [Tool])] {
        [
            ("Finder", [
                Tool(id: "hidden", title: "Hidden Files", symbol: "eye.trianglebadge.exclamationmark", tint: .blue) {
                    Task { let next = await service.toggleHiddenFiles(); toast = next ? "Hidden files shown" : "Hidden files hidden" }
                },
                Tool(id: "desktop", title: "Desktop Icons", symbol: "menubar.rectangle", tint: .blue) {
                    Task { let next = await service.toggleDesktopIcons(); toast = next ? "Desktop icons shown" : "Desktop icons hidden" }
                },
                Tool(id: "finder", title: "Restart Finder", symbol: "arrow.clockwise", tint: .blue) {
                    Task { await service.restartFinder(); toast = "Finder restarted" }
                }
            ]),
            ("Network & System", [
                Tool(id: "dns", title: "Flush DNS", symbol: "network", tint: .indigo) {
                    Task { do { try await service.flushDNSCache(); toast = "DNS cache flushed" } catch { toast = error.localizedDescription } }
                },
                Tool(id: "wifi", title: "Wi-Fi Off", symbol: "wifi.slash", tint: .indigo) {
                    Task { do { try await service.disconnectWiFi(); toast = "Wi-Fi turned off" } catch { toast = error.localizedDescription } }
                },
                Tool(id: "cache", title: "Clear Caches", symbol: "paintbrush", tint: .indigo) {
                    Task {
                        do {
                            let freed = try await Task.detached { try MacMagicSystemToolService.shared.clearDiskCache() }.value
                            toast = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
                        } catch { toast = error.localizedDescription }
                    }
                }
            ]),
            ("PDF & Media", [
                Tool(id: "pdfmerge", title: "Merge PDFs", symbol: "doc.badge.plus", tint: .orange) {
                    mergePDFs()
                },
                Tool(id: "pdfcompress", title: "Compress PDF", symbol: "doc.badge.gearshape", tint: .orange) {
                    compressPDF()
                },
                Tool(id: "imageconvert", title: "Convert Image", symbol: "photo.badge.arrow.down", tint: .orange) {
                    convertImage()
                },
                Tool(id: "qr", title: "QR Code", symbol: "qrcode", tint: .orange) {
                    makeQR()
                },
                Tool(id: "videoconvert", title: "Convert Video", symbol: "film", tint: .orange) {
                    convertVideo()
                }
            ]),
            ("Files", [
                Tool(id: "dsstore", title: "Erase .DS_Store", symbol: "trash.slash", tint: .teal) {
                    eraseDSStore()
                },
                Tool(id: "lock", title: "Lock / Hide Flags", symbol: "lock.doc", tint: .teal) {
                    fileAttributes()
                },
                Tool(id: "lsof", title: "Who's Using It?", symbol: "person.2", tint: .teal) {
                    whoIsUsing()
                },
                Tool(id: "rename", title: "Batch Rename", symbol: "textformat.abc", tint: .teal) {
                    batchRename()
                },
                Tool(id: "forcedelete", title: "Force Delete", symbol: "xmark.bin", tint: .red) {
                    forceDelete()
                },
                Tool(id: "trash", title: "Empty Trash", symbol: "trash.fill", tint: .red) {
                    confirmEmptyTrash()
                }
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

    private func fileAttributes() {
        guard let url = pickFiles(types: [UTType.data], multiple: false)?.first else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Lock") {
            do { try service.setFileLocked(url: url, locked: true); toast = "Locked" } catch { toast = error.localizedDescription }
        })
        menu.addItem(ClosureMenuItem(title: "Unlock") {
            do { try service.setFileLocked(url: url, locked: false); toast = "Unlocked" } catch { toast = error.localizedDescription }
        })
        menu.addItem(ClosureMenuItem(title: "Hide") {
            do { try service.setFileHidden(url: url, hidden: true); toast = "Hidden" } catch { toast = error.localizedDescription }
        })
        menu.addItem(ClosureMenuItem(title: "Unhide") {
            do { try service.setFileHidden(url: url, hidden: false); toast = "Unhidden" } catch { toast = error.localizedDescription }
        })
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func whoIsUsing() {
        guard let url = pickFiles(types: [UTType.data], multiple: false)?.first else { return }
        Task {
            do {
                let lockers = try await service.findProcessesLockingFile(at: url)
                toast = lockers.isEmpty ? "No process holds this file open" : lockers.map { "\($0.command) (\($0.pid))" }.joined(separator: ", ")
            } catch { toast = error.localizedDescription }
        }
    }

    private func batchRename() {
        guard let urls = pickFiles(types: [UTType.data], multiple: true), !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Batch Rename"
        alert.informativeText = "Find what:  Replacement may use {n} for numbering."
        let find = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        let replace = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        replace.stringValue = "{n}"
        let stack = NSStackView(views: [find, replace])
        stack.orientation = .vertical
        alert.accessoryView = stack
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !find.stringValue.isEmpty else { return }
        do {
            let renamed = try service.batchRename(urls: urls, pattern: find.stringValue, replacement: replace.stringValue)
            toast = "Renamed \(renamed.count) files"
        } catch { toast = error.localizedDescription }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Items in your Trash will be permanently deleted."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await service.forceEmptyTrash(); toast = "Trash emptied" } catch { toast = error.localizedDescription } }
    }

    private func forceDelete() {
        guard let url = pickFiles(types: [UTType.data], multiple: false)?.first else { return }
        let alert = NSAlert()
        alert.messageText = "Force delete “\(url.lastPathComponent)”?"
        alert.informativeText = "Clears the lock flag and removes the file immediately."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try service.forceDelete(url: url)
            toast = "Deleted"
        } catch { toast = error.localizedDescription }
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

/// One MacMagic-style tile: symbol in a tinted squircle, title below.
private struct ToolCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.22 : 0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(AOMType.caption.weight(.medium))
                    .foregroundStyle(AOMTheme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hovering ? AOMTheme.pane : AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
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
