import AppKit
import Combine

/// What the panel beside a dialog shows.
@MainActor
final class FilesDialogPanelModel: ObservableObject {
    enum FinderState: Equatable {
        case off, loading, ready, notRunning
        case needsPermission(denied: Bool)
        case failed(String)
    }

    enum Status: Equatable {
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published var appName = ""
    @Published var kind: FilesDialogKind = .open
    @Published var finder: [FilesFolderEntry] = []
    @Published var finderState: FinderState = .off
    @Published var favorites: [FilesFolderEntry] = []
    @Published var recents: [FilesFolderEntry] = []
    @Published var showsRecents = true
    @Published var clipboard: FilesFolderEntry?
    @Published var showsClipboard = true
    @Published var status: Status?
    @Published var showsShortcuts = false
    @Published var busy = false

    var jump: (String) -> Void = { _ in }
    var allowFinder: () -> Void = {}
    var excludeApp: () -> Void = {}
    var hideForThisDialog: () -> Void = {}
    var openFilesPage: () -> Void = {}
    var refreshClipboard: () -> Void = {}

    var isEmpty: Bool { finder.isEmpty && favorites.isEmpty && recents.isEmpty && clipboard == nil }
}

/// The Open and Save dialog helper: follows the tracker, decides whether the
/// panel may show (Pause AOM, per-app pause, excluded apps), fills the lists
/// and runs jumps.
@MainActor
final class FilesDialogHelper {
    static let shared = FilesDialogHelper()

    let model = FilesDialogPanelModel()
    private(set) lazy var panel = FilesDialogPanelController(model: model)
    private let tracker = FilesDialogTracker.shared
    private let settings: FilesSettings
    private(set) var attached: FilesDialogState?
    private var latest: FilesDialogState?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var running = false
    private var hiddenDialog: AXUIElement?
    private var loadTask: Task<Void, Never>?
    private var statusReset: DispatchWorkItem?
    private var lastClipboardChange = -1
    /// Tells the module the status board's line may have changed.
    var onChange: (() -> Void)?

    init(settings: FilesSettings? = nil) {
        self.settings = settings ?? .shared
        model.jump = { [weak self] in self?.jump(to: $0) }
        model.allowFinder = { [weak self] in self?.allowFinderAccess() }
        model.excludeApp = { [weak self] in self?.excludeCurrentApp() }
        model.hideForThisDialog = { [weak self] in self?.hideForThisDialog() }
        model.openFilesPage = { FilesModule.openPage() }
        model.refreshClipboard = { [weak self] in self?.loadClipboard() }
    }

    var isRunning: Bool { running }
    /// The helper is on but macOS doesn't allow AOM to use Accessibility.
    var needsAccessibility: Bool { settings.dialogHelper && !AXIsProcessTrusted() }

    /// Starts or stops with the switch, the Accessibility permission and Pause AOM.
    func refresh() {
        let wanted = settings.dialogHelper && AXIsProcessTrusted() && !PresetManager.isUIPreview && !PresetManager.isRunningTests
        if wanted { start() } else { stop() }
        onChange?()
    }

    private func start() {
        guard !running else { apply(); return }
        running = true
        tracker.publish = { [weak self] state in self?.receive(state) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { FilesDialogHelper.shared.frontmostChanged(app) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: PermissionWatchdog.accessibilityLost, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FilesDialogHelper.shared.refresh() }
        })
        TriggerSuppression.shared.$pause
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { FilesDialogHelper.shared.apply() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { FilesDialogHelper.shared.apply() } }
            .store(in: &cancellables)
        tracker.setEnabled(true)
        if let front = NSWorkspace.shared.frontmostApplication { frontmostChanged(front) }
    }

    private func stop() {
        guard running else { return }
        running = false
        tracker.setEnabled(false)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        cancellables.removeAll()
        latest = nil
        apply()
    }

    private func frontmostChanged(_ app: NSRunningApplication) {
        tracker.frontmostChanged(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
    }

    private func receive(_ state: FilesDialogState?) {
        latest = state
        apply()
    }

    /// Shows, moves or hides the panel for the latest dialog.
    func apply() {
        var state = running ? latest : nil
        if let candidate = state {
            let blocked = !AutomationGate.allows(.system)
                || TriggerSuppression.shared.isPaused(forApp: candidate.bundleID)
                || settings.isExcluded(candidate.bundleID)
                || (hiddenDialog.map { CFEqual($0, candidate.element) } ?? false)
            if blocked { state = nil }
        }
        if hiddenDialog != nil, latest == nil { hiddenDialog = nil }
        guard let state else {
            if attached != nil {
                attached = nil
                panel.detach()
                FilesDialogHotKeys.shared.unregister()
                loadTask?.cancel()
                model.status = nil
                onChange?()
            }
            return
        }
        if state.isSameDialog(as: attached) {
            attached = state
            panel.move(to: state.frame)
            return
        }
        attached = state
        model.appName = state.appName
        model.kind = state.classification.kind
        model.status = nil
        model.busy = false
        load()
        panel.attach(to: state.frame)
        registerHotKeys()
        onChange?()
    }

    // MARK: Lists

    private func load() {
        loadTask?.cancel()
        model.favorites = settings.favorites.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FilesFolderEntry(path: FilesPath.key(path), source: .favorite)
        }
        model.showsShortcuts = settings.favoriteShortcuts
        model.showsRecents = settings.showsRecentFolders
        model.showsClipboard = settings.showsClipboardPath
        model.finder = []
        model.recents = []
        model.finderState = settings.showsFinderWindows ? .loading : .off
        loadClipboard()
        let wantsFinder = settings.showsFinderWindows
        let wantsRecents = settings.showsRecentFolders
        let wantsNewest = settings.includesNewestFiles
        let jumps = FilesRecentFolderStore.shared.jumps
        loadTask = Task { [weak self] in
            async let finderResult = Self.finderFolders(wanted: wantsFinder)
            async let newest = Self.newestFiles(wanted: wantsRecents && wantsNewest)
            let finder = await finderResult
            let files = await newest
            guard let self, !Task.isCancelled else { return }
            self.applyFinder(finder)
            if wantsRecents { self.applyRecents(jumps: jumps, newest: files) }
        }
    }

    /// Off the main actor: the Finder answers through osascript (≤ 2 s).
    nonisolated private static func finderFolders(wanted: Bool) async -> Result<[String], FilesFinder.Failure>? {
        guard wanted else { return nil }
        return FilesFinder.windowFolders()
    }

    nonisolated private static func newestFiles(wanted: Bool) async -> [FilesNewestFile] {
        wanted ? newestFiles() : []
    }

    private func applyFinder(_ result: Result<[String], FilesFinder.Failure>?) {
        guard let result else { model.finderState = .off; return }
        switch result {
        case .success(let paths):
            let folders = FilesFolderLists.finderFolders(paths)
            model.finder = folders.enumerated().map { index, path in
                FilesFolderEntry(path: path, source: .finder, date: nil, detail: index == 0 ? "Front Finder window" : nil)
            }
            model.finderState = .ready
        case .failure(.permission(.notAsked)): model.finderState = .needsPermission(denied: false)
        case .failure(.permission(.denied)): model.finderState = .needsPermission(denied: true)
        case .failure(.permission(.finderNotRunning)): model.finderState = .notRunning
        case .failure(.permission): model.finderState = .failed("Finder didn't answer")
        case .failure(.timedOut): model.finderState = .failed("Finder didn't answer in time")
        case .failure(.failed(let message)): model.finderState = .failed(message.isEmpty ? "Finder didn't answer" : message)
        }
    }

    private func applyRecents(jumps: [FilesRecentJump], newest: [FilesNewestFile]) {
        let shown = Set(model.favorites.map(\.path) + model.finder.map(\.path))
        model.recents = FilesFolderLists.recents(jumps: jumps, newestFiles: newest, excluding: shown)
    }

    /// The newest items in Downloads and on the Desktop (five each).
    nonisolated static func newestFiles() -> [FilesNewestFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                        ?? home.appendingPathComponent("Downloads"),
                       home.appendingPathComponent("Desktop")]
        return folders.flatMap { folder in
            FilesRecentScanner.newest(in: folder, limit: 5).map { FilesNewestFile(url: $0.url, added: $0.added, isFolder: $0.isFolder) }
        }
    }

    private func loadClipboard() {
        guard settings.showsClipboardPath, !PresetManager.isUIPreview else { model.clipboard = nil; return }
        let change = NSPasteboard.general.changeCount
        guard change != lastClipboardChange || model.clipboard == nil else { return }
        lastClipboardChange = change
        if let folder = FilesClipboardPath.current() {
            model.clipboard = FilesFolderEntry(path: folder.path, source: .clipboard, date: nil,
                                               detail: FilesPath.abbreviated(folder.path))
        } else {
            model.clipboard = nil
        }
    }

    // MARK: Jumps

    func jump(to path: String) {
        guard let dialog = attached, !model.busy else { return }
        guard AutomationGate.allows(.system), !TriggerSuppression.shared.isPaused(forApp: dialog.bundleID) else {
            show(.failed("Couldn't go there because AOM is paused"))
            return
        }
        guard let folder = FilesPath.jumpFolder(for: path) else {
            show(.failed("Couldn't go to “\(FilesPath.displayName(path))” because it no longer exists"))
            return
        }
        let name = FilesPath.displayName(folder.path)
        model.busy = true
        model.status = .working("Going to \(name)…")
        tracker.jump(to: folder, frontmostPID: {
            DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        }) { [weak self] result in
            guard let self else { return }
            self.model.busy = false
            switch result {
            case .success(let folder):
                FilesRecentFolderStore.shared.note(folder)
                self.show(.done("Went to \(name)"))
                self.applyRecents(jumps: FilesRecentFolderStore.shared.jumps, newest: [])
            case .failure(let failure):
                self.show(.failed("Couldn't go to “\(name)” because \(failure.reason)"))
            }
        }
    }

    func jumpToFavorite(_ index: Int) {
        guard model.favorites.indices.contains(index) else { return }
        jump(to: model.favorites[index].path)
    }

    private func show(_ status: FilesDialogPanelModel.Status) {
        statusReset?.cancel()
        model.status = status
        let seconds: Double
        if case .failed = status { seconds = 8 } else { seconds = 2.5 }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.model.status == status { self?.model.status = nil }
            }
        }
        statusReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func registerHotKeys() {
        guard settings.favoriteShortcuts, !model.favorites.isEmpty else { FilesDialogHotKeys.shared.unregister(); return }
        FilesDialogHotKeys.shared.onPress = { index in FilesDialogHelper.shared.jumpToFavorite(index) }
        FilesDialogHotKeys.shared.register(count: model.favorites.count)
    }

    // MARK: Panel menu

    private func allowFinderAccess() {
        model.finderState = .loading
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) { FilesFinder.permission(ask: true) }.value
            guard let self else { return }
            if state == .denied {
                self.model.finderState = .needsPermission(denied: true)
                NSWorkspace.shared.open(FilesFinder.automationSettingsURL)
                return
            }
            let result = await Task.detached(priority: .userInitiated) { FilesFinder.windowFolders() }.value
            self.applyFinder(result)
            self.applyRecents(jumps: FilesRecentFolderStore.shared.jumps, newest: [])
        }
    }

    private func excludeCurrentApp() {
        guard let bundleID = attached?.bundleID else { return }
        settings.exclude(bundleID)
        apply()
    }

    private func hideForThisDialog() {
        hiddenDialog = attached?.element
        apply()
    }
}
