import SwiftUI

/// The System Tools page — MacMagic's maintenance suite, in the main window
/// where the rest of AOM lives (the menu bar stays lean). Three groups:
/// Finder tweaks, network, and file maintenance.
struct SystemToolsView: View {
    private let service = MacMagicSystemToolService.shared
    @State private var toast: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AOMSpace.l) {
                AOMSectionCard("Finder", symbol: "macwindow.on.rectangle",
                               detail: "Tweaks apply instantly — Finder restarts itself") {
                    FinderTweaksRow(service: service, toast: $toast)
                }
                AOMSectionCard("Network", symbol: "network",
                               detail: "Flush the local DNS resolver cache") {
                    HStack {
                        Button("Flush DNS Cache") {
                            Task {
                                try? await service.flushDNSCache()
                                toast = "DNS cache flushed"
                            }
                        }
                        Spacer()
                    }
                }
                AOMSectionCard("File Maintenance", symbol: "folder.badge.gearshape",
                               detail: "Cleanup, locks and stubborn files") {
                    FileMaintenanceCard(service: service, toast: $toast)
                }
            }
            .padding(AOMSpace.xl)
        }
        .background(AOMTheme.workspace)
        .aomToast(toast)
        .onChange(of: toast) { _, message in
            guard message != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.2))
                toast = nil
            }
        }
    }
}

private struct FinderTweaksRow: View {
    let service: MacMagicSystemToolService
    @Binding var toast: String?
    @AppStorage("AppleShowAllFiles") private var hiddenFiles = false
    @State private var desktopIcons = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "CreateDesktop") ?? true

    var body: some View {
        VStack(spacing: AOMSpace.s) {
            HStack {
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false },
                    set: { newValue in
                        Task {
                            let next = await service.toggleHiddenFiles()
                            await MainActor.run { toast = next ? "Hidden files shown" : "Hidden files hidden" }
                        }
                    }))
                Spacer()
                Text("AppleShowAllFiles").font(AOMType.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Show Desktop Icons", isOn: Binding(
                    get: { desktopIcons },
                    set: { newValue in
                        desktopIcons = newValue
                        Task {
                            let next = await service.toggleDesktopIcons()
                            await MainActor.run { desktopIcons = next; toast = next ? "Desktop icons shown" : "Desktop icons hidden" }
                        }
                    }))
                Spacer()
                Text("CreateDesktop").font(AOMType.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restart Finder") {
                    Task { await service.restartFinder(); toast = "Finder restarted" }
                }
                Spacer()
            }
        }
    }
}

private struct FileMaintenanceCard: View {
    let service: MacMagicSystemToolService
    @Binding var toast: String?
    @State private var targetFolder: URL?
    @State private var targetFile: URL?
    @State private var lockers: [MacMagicSystemToolService.LockingProcess] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.m) {
            HStack {
                Button("Erase .DS_Store…") {
                    guard let folder = pick(open: false, directory: true) else { return }
                    targetFolder = folder
                    working = true
                    Task {
                        let count = (try? await service.eraseDSStoreFiles(in: folder)) ?? 0
                        await MainActor.run { working = false; toast = "\(count) .DS_Store removed from \(folder.lastPathComponent)" }
                    }
                }
                if let targetFolder { Text(targetFolder.lastPathComponent).font(AOMType.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }
            AOMDivider(axis: .horizontal)
            HStack {
                Button("Pick File…") {
                    targetFile = pick(open: true, directory: false)
                    lockers = []
                }
                if let targetFile {
                    Text(targetFile.lastPathComponent).font(AOMType.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Lock") { apply { try service.setFileLocked(url: $0, locked: true) } }
                    Button("Unlock") { apply { try service.setFileLocked(url: $0, locked: false) } }
                    Button("Hide") { apply { try service.setFileHidden(url: $0, hidden: true) } }
                    Button("Unhide") { apply { try service.setFileHidden(url: $0, hidden: false) } }
                } else { Spacer() }
            }
            if let targetFile {
                HStack {
                    Button("Who's Using It?") {
                        Task {
                            lockers = (try? await service.findProcessesLockingFile(at: targetFile)) ?? []
                            if lockers.isEmpty { toast = "No process holds this file open" }
                        }
                    }
                    Spacer()
                }
                if !lockers.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lockers) { locker in
                            Text("\(locker.command) (pid \(locker.pid)) — fd \(locker.fileDescriptor)")
                                .font(AOMType.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            AOMDivider(axis: .horizontal)
            HStack {
                Button("Empty Trash", role: .destructive) {
                    Task {
                        try? await service.forceEmptyTrash()
                        toast = "Trash emptied"
                    }
                }
                Spacer()
                Text("Bypasses locked-file prompts").font(AOMType.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(working)
    }

    private func apply(_ run: (URL) throws -> Void) {
        guard let targetFile else { return }
        do {
            try run(targetFile)
            toast = "Attribute updated"
        } catch {
            toast = error.localizedDescription
        }
    }

    private func pick(open: Bool, directory: Bool) -> URL? {
        let panel = open ? NSOpenPanel() : NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
