import AppKit
import Combine
import SwiftUI

/// The small panel attached beside an Open or Save dialog. It follows the
/// dialog, hides when it closes and never takes focus, so the keys a jump
/// sends still reach the dialog.
@MainActor
final class FilesDialogPanelController {
    static let width: CGFloat = 248

    private let model: FilesDialogPanelModel
    private var panel: FilesFloatingPanel?
    private var dialogFrame: CGRect?
    private var hideWork: DispatchWorkItem?
    private var changes: AnyCancellable?

    init(model: FilesDialogPanelModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func attach(to axFrame: CGRect) {
        hideWork?.cancel()
        dialogFrame = axFrame
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AOMMotion.systemReduceMotion ? 0.08 : 0.14
                panel.animator().alphaValue = 1
            }
        }
        changes = model.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
    }

    func move(to axFrame: CGRect) {
        guard dialogFrame != axFrame else { return }
        dialogFrame = axFrame
        layout()
    }

    /// Hides after a moment, so the brief focus change while Go to Folder
    /// opens and closes doesn't flicker the panel.
    func detach() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.changes = nil
                self.dialogFrame = nil
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = AOMMotion.systemReduceMotion ? 0.06 : 0.12
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if self.dialogFrame == nil { panel.orderOut(nil) }
                    }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func makePanel() -> FilesFloatingPanel {
        let panel = FilesFloatingPanel(size: CGSize(width: Self.width, height: 320), label: "Files: folders for this dialog")
        let hosting = FilesHostingView(rootView: FilesDialogPanelView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func layout() {
        guard let panel, let dialogFrame else { return }
        let dialog = FilesScreenGeometry.cocoaRect(fromAX: dialogFrame)
        let size = CGSize(width: Self.width, height: Self.contentHeight(for: model))
        let frame = FilesScreenGeometry.frame(beside: dialog, size: size, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The panel's height from what it lists (rows are a fixed height), so it
    /// grows with the lists instead of measuring a scroll view.
    static func contentHeight(for model: FilesDialogPanelModel) -> CGFloat {
        let row = FilesDialogPanelView.rowHeight
        var height: CGFloat = 44 + 8
        func section(_ rows: Int) { height += 26 + CGFloat(max(rows, 1)) * row }
        if model.finderState != .off { section(model.finder.count) }
        section(model.favorites.count)
        if model.showsRecents && !model.recents.isEmpty { section(model.recents.count) }
        if model.showsClipboard && model.clipboard != nil { section(1) }
        if model.status != nil { height += 52 }
        return min(height, 620)
    }
}

/// The dialog panel's content: Finder windows, favourites, recent folders and
/// the clipboard's path; a click goes there in the dialog.
struct FilesDialogPanelView: View {
    static let rowHeight: CGFloat = 36
    @ObservedObject var model: FilesDialogPanelModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AOMDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.finderState != .off { finderSection }
                    favoritesSection
                    if model.showsRecents && !model.recents.isEmpty {
                        section("Recent") { ForEach(model.recents) { row($0) } }
                    }
                    if model.showsClipboard, let clipboard = model.clipboard {
                        section("Clipboard") { row(clipboard) }
                    }
                }
                .padding(.horizontal, AOMSpace.x1 + AOMSpace.x0_5)
                .padding(.bottom, AOMSpace.x2)
            }
            .scrollIndicators(.automatic)
            if let status = model.status { statusRow(status) }
        }
        .frame(width: FilesDialogPanelController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .aomFloatingSurface(.panel, radius: AOMRadius.card)
        .onHover { inside in if inside { model.refreshClipboard() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders for \(model.appName)'s \(model.kind == .save ? "Save" : "Open") dialog")
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x2) {
            AOMModuleBadge(.files, size: AOMIcon.row + AOMSpace.x0_5)
            VStack(alignment: .leading, spacing: 0) {
                Text("Go to Folder").font(AOMFont.headline).foregroundStyle(AOMColor.text).lineLimit(1)
                Text(model.appName.isEmpty ? (model.kind == .save ? "Save dialog" : "Open dialog") : model.appName)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x1)
            Menu {
                Button("Open Files Settings…") { model.openFilesPage() }
                Divider()
                Button("Hide for This Dialog") { model.hideForThisDialog() }
                if !model.appName.isEmpty {
                    Button("Never Show in \(model.appName)") { model.excludeApp() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Files options")
            .accessibilityLabel("Files options")
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: 44)
    }

    @ViewBuilder private var finderSection: some View {
        section("Finder windows") {
            switch model.finderState {
            case .loading:
                note("Asking the Finder…", symbol: nil, progress: true)
            case .ready where model.finder.isEmpty:
                note("No Finder windows are open", symbol: "macwindow")
            case .ready:
                ForEach(model.finder) { row($0) }
            case .notRunning:
                note("The Finder isn't running", symbol: "macwindow")
            case .needsPermission(let denied):
                Button {
                    model.allowFinder()
                } label: {
                    HStack(spacing: AOMSpace.x2) {
                        Image(systemName: "lock.open").frame(width: AOMIcon.row).foregroundStyle(AOMColor.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(denied ? "Allow in System Settings…" : "Allow Finder Access…").font(AOMFont.body).foregroundStyle(AOMColor.accent)
                            Text("To list the Finder's open folders").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FilesRowButtonStyle())
                .help(denied ? "Opens Privacy & Security › Automation, where All of MacOS can be allowed to control Finder"
                             : "Asks macOS to let All of MacOS read which folders the Finder windows show")
            case .failed(let message):
                note(message, symbol: "exclamationmark.triangle")
            case .off:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        section("Favorites") {
            if model.favorites.isEmpty {
                note("No favorites yet", symbol: "star")
            } else {
                ForEach(Array(model.favorites.enumerated()), id: \.element.id) { index, entry in
                    row(entry, shortcut: model.showsShortcuts && index < 9 ? "⌘⌥\(index + 1)" : nil)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AOMFont.caption.weight(.semibold))
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2)
                .frame(height: 26, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ entry: FilesFolderEntry, shortcut: String? = nil) -> some View {
        let detail = entry.detail ?? FilesPath.abbreviated(entry.path)
        return Button {
            model.jump(entry.path)
        } label: {
            HStack(spacing: AOMSpace.x2) {
                Image(nsImage: FilesIcons.icon(entry.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name)
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AOMSpace.x1)
                if let shortcut {
                    Text(shortcut)
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(FilesRowButtonStyle())
        .disabled(model.busy)
        .help(entry.path)
        .contextMenu {
            Button("Show in Finder") { FilesFileActions.reveal([URL(fileURLWithPath: entry.path)]) }
            Button("Copy Path") { FilesFileActions.copyPaths([URL(fileURLWithPath: entry.path)]) }
            if entry.source == .favorite {
                Button("Remove from Favorites") { FilesSettings.shared.removeFavorite(entry.path) }
            } else if !FilesSettings.shared.isFavorite(entry.path) {
                Button("Add to Favorites") { FilesSettings.shared.addFavorite(URL(fileURLWithPath: entry.path)) }
            }
        }
        .accessibilityLabel("Go to \(entry.name)")
        .accessibilityHint(FilesPath.abbreviated(entry.path))
        .accessibilityValue(shortcut ?? "")
    }

    private func note(_ text: String, symbol: String?, progress: Bool = false) -> some View {
        HStack(spacing: AOMSpace.x2) {
            if progress {
                ProgressView().controlSize(.small).frame(width: AOMIcon.row)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(AOMColor.textTertiary).frame(width: AOMIcon.row)
            }
            Text(text)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.x2)
        .frame(minHeight: Self.rowHeight)
        .accessibilityElement(children: .combine)
    }

    private func statusRow(_ status: FilesDialogPanelModel.Status) -> some View {
        let tone: AOMTone
        let text: String
        switch status {
        case .working(let message): tone = .info; text = message
        case .done(let message): tone = .success; text = message
        case .failed(let message): tone = .danger; text = message
        }
        return VStack(spacing: 0) {
            AOMDivider()
            HStack(alignment: .center, spacing: AOMSpace.x2) {
                if case .working = status {
                    ProgressView().controlSize(.small).frame(width: AOMIcon.row)
                } else {
                    Image(systemName: tone.symbol)
                        .foregroundStyle(tone.color)
                        .frame(width: AOMIcon.row)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(AOMFont.callout)
                    .foregroundStyle(tone == .danger ? AOMColor.dangerText : AOMColor.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x3)
            .padding(.vertical, AOMSpace.x2)
            .frame(minHeight: 51)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
