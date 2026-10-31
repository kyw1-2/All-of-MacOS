import AppKit
import QuickLook
import SwiftUI

/// Files (3.4): the Open and Save dialog helper, the Drop Shelf and recent
/// downloads and screenshots. Dashboard template (design-3.4.0 b.2).
struct FilesPage: View {
    @ObservedObject private var settings = FilesSettings.shared
    @ObservedObject private var shelf = FilesShelfStore.shared
    @ObservedObject private var recent = FilesRecentModel.shared
    @StateObject private var toast = AOMToastModel()
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var finderPermission: FilesFinder.Permission?
    @State private var quickLookURL: URL?
    @State private var quickLookItems: [URL] = []
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings

    private var isOn: Bool { settings.dialogHelper || settings.shakeOpensShelf || settings.shiftOpensShelf }

    var body: some View {
        AOMPage {
            AOMPageHeader("Files", module: .files, subtitle: AOMMainTab.files.subtitle,
                          status: isOn ? AOMStatus("On", tone: .success) : AOMStatus("Off", tone: .neutral),
                          help: "Files puts folders one click away in every Open and Save dialog, holds dragged files on a shelf while you switch apps, and lists the newest downloads and screenshots.",
                          active: isOn) {
                Button {
                    FilesModule.showShelf()
                } label: {
                    Label("Show Drop Shelf", systemImage: "tray.and.arrow.down")
                }
                .help(shortcutHelp)
            }
            if settings.dialogHelper && !accessibilityTrusted {
                AOMNotice(.warning, "The Open and Save helper needs Accessibility",
                          detail: "Allow All of MacOS in System Settings › Privacy & Security › Accessibility so it can see dialogs and go to folders.") {
                    Button("Open Settings") { _ = AOMPermission.accessibility.openSettings() }
                }
            }
            FilesAdaptiveColumns(minimumColumnWidth: 440) {
                dialogSection
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    favoritesSection
                    excludedSection
                }
            }
            FilesShelfSection(settings: settings, shelf: shelf, toast: toast, openShortcutSettings: openShortcutSettings,
                              quickLook: quickLook)
            FilesRecentSection(recent: recent, toast: toast, quickLook: quickLook)
        }
        .aomPage("Files")
        .aomToast(toast)
        .quickLookPreview($quickLookURL, in: quickLookItems)
        .task {
            if PresetManager.isUIPreview {
                FilesPreviewData.seed()
                AOMFeaturePreview.applyPanelAppearance()
            }
            FilesModule.publishStatus()
            await refreshFinderPermission()
        }
        .onAppear { recent.beginWatching() }
        .onDisappear { recent.endWatching() }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityRecovered)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: PermissionWatchdog.accessibilityLost)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
            Task { await refreshFinderPermission() }
        }
    }

    private var shortcutHelp: String {
        if let shortcut = CaptureShortcuts.shared.shortcut(for: .showDropShelf) {
            return "Opens the Drop Shelf beside the pointer (\(shortcut.displayString))"
        }
        return "Opens the Drop Shelf beside the pointer"
    }

    private func quickLook(_ urls: [URL], _ index: Int) {
        guard urls.indices.contains(index) else { return }
        quickLookItems = urls
        quickLookURL = quickLookURL == urls[index] ? nil : urls[index]
    }

    private func openShortcutSettings() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue)
        }
    }

    private func refreshFinderPermission() async {
        guard settings.dialogHelper, settings.showsFinderWindows, !PresetManager.isUIPreview else {
            finderPermission = PresetManager.isUIPreview ? .granted : nil
            return
        }
        finderPermission = await Task.detached(priority: .utility) { FilesFinder.permission(ask: false) }.value
    }

    // MARK: Open and Save dialogs

    private var dialogSection: some View {
        AOMSection("Open and Save dialogs",
                   help: "When an Open or Save dialog is in front, a panel beside it lists folders. A click presses ⌘⇧G in the dialog, enters the folder's path and presses Return, then checks that the dialog went there.") {
            AOMToggleRow("Show folders beside Open and Save dialogs",
                         detail: "Finder windows, favorites, recent folders and the clipboard's path",
                         symbol: "macwindow.on.rectangle", isOn: $settings.dialogHelper)
            FilesDialogIllustration(active: settings.dialogHelper)
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
            Group {
                AOMToggleRow("Finder windows", detail: "The folders open in the Finder, front to back", indent: true,
                             isOn: $settings.showsFinderWindows)
                if settings.showsFinderWindows, let permission = finderPermission, permission != .granted {
                    AOMSettingRow(permission == .denied ? "Finder access is turned off" : "Finder access",
                                  detail: finderPermissionDetail(permission), indent: true) {
                        Button(permission == .denied ? "Open Settings" : "Allow…") { allowFinder(permission) }
                    }
                }
                AOMToggleRow("Recent folders", detail: "Folders you went to, and where the newest downloads are", indent: true,
                             isOn: $settings.showsRecentFolders)
                AOMToggleRow("The clipboard's path", detail: "When the clipboard holds a file or a path to one", indent: true,
                             isOn: $settings.showsClipboardPath)
                AOMToggleRow("⌘⌥1 to ⌘⌥9 go to favorites", detail: "While a dialog is in front", indent: true,
                             isOn: $settings.favoriteShortcuts)
            }
            .disabled(!settings.dialogHelper)
        }
    }

    private func finderPermissionDetail(_ permission: FilesFinder.Permission) -> String {
        switch permission {
        case .denied: return "Allow All of MacOS to control Finder in Privacy & Security › Automation"
        case .notAsked: return "macOS asks once whether All of MacOS may read the Finder's windows"
        case .finderNotRunning: return "The Finder isn't running"
        case .granted, .unknown: return "macOS hasn't answered yet"
        }
    }

    private func allowFinder(_ permission: FilesFinder.Permission) {
        guard permission != .denied else {
            NSWorkspace.shared.open(FilesFinder.automationSettingsURL)
            return
        }
        Task {
            finderPermission = await Task.detached(priority: .userInitiated) { FilesFinder.permission(ask: true) }.value
            if finderPermission == .granted { toast.show("Finder access allowed") }
        }
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        AOMSection("Favorites", detail: settings.favorites.isEmpty ? nil : "\(settings.favorites.count)",
                   help: "The dialog panel lists these folders in this order. With the shortcut option on, ⌘⌥1 goes to the first, ⌘⌥2 to the second and so on.") {
            if settings.favorites.isEmpty {
                AOMInlineEmpty(symbol: "star", message: "No favorites yet. Drag a folder here.", actionTitle: "Add Folder…") { addFavorite() }
            }
            ForEach(Array(settings.favorites.enumerated()), id: \.element) { index, path in
                FilesFavoriteRow(path: path, index: index, count: settings.favorites.count,
                                 shortcut: settings.favoriteShortcuts && index < 9 ? "⌘⌥\(index + 1)" : nil,
                                 move: { settings.moveFavorite(from: index, to: $0) },
                                 insert: { folders in insertFavorites(folders, at: index) },
                                 remove: { removeFavorite(path) })
            }
            HStack(spacing: AOMSpace.x2) {
                Button("Add Folder…") { addFavorite() }
                Spacer()
                Button("Restore Defaults") {
                    let previous = settings.favorites
                    settings.resetFavorites()
                    toast.show("Favorites restored", action: { settings.favorites = previous })
                }
                .disabled(settings.favorites == FilesPath.defaultFavorites())
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .overlay(alignment: .top) { AOMRowDivider() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            insertFavorites(urls, at: settings.favorites.count)
        }
    }

    /// Adds dropped Finder folders (a file adds its folder) at `index`.
    @discardableResult
    private func insertFavorites(_ urls: [URL], at index: Int) -> Bool {
        let folders = urls.compactMap { FilesPath.jumpFolder(for: $0.path) }
            .filter { !settings.isFavorite($0.path) }
        guard !folders.isEmpty else { return false }
        var list = settings.favorites
        list.insert(contentsOf: FilesFolderLists.unique(folders.map(\.path)), at: min(index, list.count))
        settings.favorites = list
        toast.show(folders.count == 1 ? "Added “\(FilesPath.displayName(folders[0].path))” to favorites" : "Added \(folders.count) favorites")
        return true
    }

    private func addFavorite() {
        guard !PresetManager.isUIPreview else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose folders for the dialog panel's favorites."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { for url in panel.urls { settings.addFavorite(url) } }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    private func removeFavorite(_ path: String) {
        guard let index = settings.favorites.firstIndex(of: path) else { return }
        let restore: @MainActor () -> Void = {
            guard !settings.favorites.contains(path) else { return }
            var list = settings.favorites
            list.insert(path, at: min(index, list.count))
            settings.favorites = list
        }
        AOMUndo.perform("Remove Favorite", undoManager: undoManager, perform: {
            settings.removeFavorite(path)
        }, revert: restore)
        toast.show("Removed “\(FilesPath.displayName(path))” from favorites", action: { [undoManager] in
            if let undoManager, undoManager.canUndo { undoManager.undo() } else { restore() }
        })
    }

    // MARK: Excluded apps

    private var excludedSection: some View {
        AOMSection("Excluded apps", detail: settings.excludedApps.isEmpty ? nil : "\(settings.excludedApps.count)",
                   help: "In these apps the dialog panel never appears and shaking a drag doesn't open the shelf.") {
            if settings.excludedApps.isEmpty {
                AOMInlineEmpty(symbol: "app.dashed", message: "Files works in every app.", actionTitle: "Add App…") { addExcludedApp() }
            } else {
                ForEach(Array(settings.excludedApps.enumerated()), id: \.element) { index, bundleID in
                    FilesAppRow(bundleID: bundleID, showsDivider: index > 0) {
                        settings.excludedApps.removeAll { $0 == bundleID }
                        toast.show("\(FilesAppRow.name(for: bundleID)) is no longer excluded",
                                   action: { settings.exclude(bundleID) })
                    }
                }
                HStack {
                    Button("Add App…") { addExcludedApp() }
                    Spacer()
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .overlay(alignment: .top) { AOMRowDivider() }
            }
        }
    }

    private func addExcludedApp() {
        guard !PresetManager.isUIPreview else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                for url in panel.urls {
                    if let id = Bundle(url: url)?.bundleIdentifier { settings.exclude(id) }
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }
}

/// An app in a list: its icon, its name and its bundle identifier, with Remove.
struct FilesAppRow: View {
    let bundleID: String
    var showsDivider = true
    let remove: () -> Void

    static func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Group {
                if let icon = AppMetadataCache.shared.icon(for: bundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app").foregroundStyle(AOMColor.textTertiary)
                }
            }
            .frame(width: AOMIcon.row + AOMSpace.x1, height: AOMIcon.row + AOMSpace.x1)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.name(for: bundleID)).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                Text(bundleID).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: AOMSpace.x2)
            AOMIconButton("minus.circle", label: "Stop excluding \(Self.name(for: bundleID))", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x1) } }
        .contextMenu { Button("Remove", role: .destructive, action: remove) }
        .accessibilityElement(children: .contain)
    }
}
