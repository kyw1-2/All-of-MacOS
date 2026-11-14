import AppKit
import SwiftUI

/// Homebrew on the System Tools page (design-3.4.0 b.16): every brew run is
/// started by a click, one at a time, with a live log and Cancel. Lists are
/// kept from the last run; nothing polls in the background.
@MainActor
final class HomebrewModel: ObservableObject {
    static let shared = HomebrewModel()

    enum Tab: String, CaseIterable, Identifiable {
        case outdated, installed, services, search
        var id: String { rawValue }
        var title: String {
            switch self {
            case .outdated: return "Outdated"
            case .installed: return "Installed"
            case .services: return "Services"
            case .search: return "Search"
            }
        }
    }

    struct Job: Equatable {
        let command: Homebrew.Command
        let started: Date
    }

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    @Published var isPresented = false
    @Published var tab: Tab = .outdated
    @Published private(set) var brew: URL? = Homebrew.locate()
    @Published private(set) var version: String?
    @Published private(set) var outdated: [Homebrew.OutdatedPackage]?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var installed: [Homebrew.InstalledPackage]?
    @Published private(set) var services: [Homebrew.Service]?
    @Published private(set) var searchResults: [Homebrew.Package]?
    @Published var searchText = ""
    @Published private(set) var job: Job?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var logTitle: String?
    @Published private(set) var activity: [AOMLogEntry] = []
    let toasts = AOMToastModel()

    static let logLimit = 600
    private var command: StreamingCommand?
    private var nextLine = 0
    private var pendingLines: [LogLine] = []
    private var flushScheduled = false
    private var upgradeAllAfterCheck = false
    private var idleQueue: [() -> Void] = []

    var isBusy: Bool { job != nil }

    /// Opens the sheet on `tab`; `refresh` loads that tab's list the first
    /// time (or again, for Outdated) unless a job is running.
    func present(_ tab: Tab, refresh: Bool) {
        self.tab = tab
        isPresented = true
        brew = Homebrew.locate()
        guard brew != nil else { return }
        if version == nil, !isBusy { readVersion { [weak self] in if refresh { self?.load(tab, force: tab == .outdated) } } }
        else if refresh { load(tab, force: tab == .outdated) }
    }

    func load(_ tab: Tab, force: Bool = false) {
        switch tab {
        case .outdated: if force || outdated == nil { checkOutdated() }
        case .installed: if force || installed == nil { loadInstalled() }
        case .services: if force || services == nil { loadServices() }
        case .search: break
        }
    }

    // MARK: - Lists

    private func readVersion(then next: @escaping () -> Void) {
        run(.version, logs: false) { [weak self] result in
            if result.succeeded { self?.version = Homebrew.versionLine(result.stdout) }
            next()
        }
    }

    func checkOutdated() {
        run(.outdated, logs: false) { [weak self] result in
            guard let self else { return }
            guard result.succeeded else { self.failed(.outdated, result); return }
            do {
                self.outdated = try Homebrew.parseOutdated(Data(result.stdout.utf8))
                self.checkedAt = Date()
                if self.upgradeAllAfterCheck { self.upgradeAllAfterCheck = false; self.requestUpgradeAll() }
            } catch { self.report(.outdated, error.localizedDescription, tone: .danger) }
        }
    }

    func loadInstalled() {
        run(.installed, logs: false) { [weak self] result in
            guard let self else { return }
            guard result.succeeded else { self.failed(.installed, result); return }
            do { self.installed = try Homebrew.parseInstalled(Data(result.stdout.utf8)) }
            catch { self.report(.installed, error.localizedDescription, tone: .danger) }
        }
    }

    func loadServices() {
        run(.services, logs: false) { [weak self] result in
            guard let self else { return }
            guard result.succeeded else { self.failed(.services, result); return }
            do { self.services = try Homebrew.parseServices(Data(result.stdout.utf8)) }
            catch { self.report(.services, error.localizedDescription, tone: .danger) }
        }
    }

    func search() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard Homebrew.isValidSearchText(text) else {
            toasts.show("Type a name of letters, digits and - . _ @ + to search", tone: .warning); return
        }
        run(.search(text, .formula), logs: false) { [weak self] formulae in
            guard let self else { return }
            guard formulae.succeeded || formulae.status == 1 else { self.failed(.search(text, .formula), formulae); return }
            let found = Homebrew.parseSearch(formulae.stdout).map { Homebrew.Package(kind: .formula, name: $0) }
            self.run(.search(text, .cask), logs: false) { casks in
                let more = casks.succeeded ? Homebrew.parseSearch(casks.stdout).map { Homebrew.Package(kind: .cask, name: $0) } : []
                self.searchResults = found + more
            }
        }
    }

    func isInstalled(_ package: Homebrew.Package) -> Bool {
        installed?.contains { $0.package == package } ?? false
    }

    // MARK: - Jobs that change the Mac

    /// Upgrade All… asks first, naming what will change; without a fresh
    /// list it checks, then asks.
    func requestUpgradeAll() {
        guard !isBusy else { whenIdle { [weak self] in self?.requestUpgradeAll() }; return }
        guard let outdated else { upgradeAllAfterCheck = true; checkOutdated(); return }
        let upgradable = outdated.filter { !$0.pinned }
        guard !upgradable.isEmpty else { toasts.show("Everything is up to date", tone: .success); return }
        let names = upgradable.prefix(10).map(\.name).joined(separator: ", ") + (upgradable.count > 10 ? " and \(upgradable.count - 10) more" : "")
        guard confirm("Upgrade \(upgradable.count) Package\(upgradable.count == 1 ? "" : "s")?",
                      "\(names). Homebrew downloads and installs the new versions; it can take a while and you can cancel. Pinned packages stay as they are.",
                      button: "Upgrade All", destructive: false) else { return }
        run(.upgradeAll, logs: true) { [weak self] result in
            self?.finished(.upgradeAll, result, success: "Upgraded \(upgradable.count) package\(upgradable.count == 1 ? "" : "s")")
            self?.checkOutdated()
        }
    }

    func upgrade(_ package: Homebrew.OutdatedPackage) {
        run(.upgrade(package.package), logs: true) { [weak self] result in
            self?.finished(.upgrade(package.package), result, success: "Upgraded \(package.name) to \(package.currentVersion)")
            self?.checkOutdated()
        }
    }

    func update() {
        run(.update, logs: true) { [weak self] result in
            self?.finished(.update, result, success: "Homebrew is up to date")
            if result.succeeded { self?.checkOutdated() }
        }
    }

    /// Measures first (`brew cleanup -n -s`), asks with the size, then cleans.
    func cleanUp() {
        run(.cleanupDryRun, logs: true) { [weak self] dry in
            guard let self else { return }
            guard dry.succeeded else { self.failed(.cleanupDryRun, dry); return }
            let items = Homebrew.cleanupItemCount(dry.stdout)
            guard let size = Homebrew.parseFreedSize(dry.stdout), items > 0 else {
                self.report(.cleanup, "Nothing to clean up", tone: .success); return
            }
            guard self.confirm("Clean Up Homebrew?",
                               "This removes \(items) old version\(items == 1 ? "" : "s"), download\(items == 1 ? "" : "s") and log\(items == 1 ? "" : "s") and frees about \(SystemStatus.size(size.bytes)). Installed packages keep working.",
                               button: "Clean Up", destructive: true) else { return }
            self.run(.cleanup, logs: true) { result in
                let freed = Homebrew.parseFreedSize(result.stdout)
                self.finished(.cleanup, result, success: freed.map { "Freed \(SystemStatus.size($0.bytes))" } ?? "Cleaned up")
            }
        }
    }

    func doctor() {
        run(.doctor, logs: true) { [weak self] result in
            guard let self else { return }
            let warnings = (result.stdout + "\n" + result.stderr).components(separatedBy: "\n").filter { $0.hasPrefix("Warning:") }.count
            if result.succeeded {
                self.report(.doctor, "brew doctor found nothing to fix", tone: .success)
            } else if !result.cancelled && !result.timedOut && warnings > 0 {
                self.report(.doctor, "brew doctor found \(warnings) warning\(warnings == 1 ? "" : "s"); see the output", tone: .warning)
            } else {
                self.failed(.doctor, result)
            }
        }
    }

    func service(_ action: Homebrew.ServiceAction, _ service: Homebrew.Service) {
        run(.service(action, service.name), logs: true) { [weak self] result in
            self?.finished(.service(action, service.name), result,
                           success: "\(action == .stop ? "Stopped" : action == .start ? "Started" : "Restarted") \(service.name)")
            self?.loadServices()
        }
    }

    func uninstall(_ package: Homebrew.Package) {
        guard confirm("Uninstall \(package.name)?",
                      "Homebrew removes the \(package.kind == .cask ? "app" : "formula") \(package.name). Packages that need it may stop working; brew refuses if another installed formula depends on it.",
                      button: "Uninstall", destructive: true) else { return }
        run(.uninstall(package), logs: true) { [weak self] result in
            self?.finished(.uninstall(package), result, success: "Uninstalled \(package.name)")
            self?.loadInstalled()
        }
    }

    func install(_ package: Homebrew.Package) {
        guard Homebrew.isValidPackageName(package.name) else { return }
        guard confirm("Install \(package.name)?",
                      "Homebrew downloads and installs the \(package.kind == .cask ? "app (cask)" : "formula") \(package.name) and anything it needs.",
                      button: "Install", destructive: false) else { return }
        run(.install(package), logs: true) { [weak self] result in
            self?.finished(.install(package), result, success: "Installed \(package.name)")
            if self?.installed != nil { self?.loadInstalled() }
        }
    }

    func cancel() {
        command?.cancel()
    }

    // MARK: - Running brew (one job at a time)

    private func run(_ commandKind: Homebrew.Command, logs: Bool, then done: @escaping (StreamingCommand.Result) -> Void) {
        guard job == nil else {
            toasts.show("Homebrew is busy: \(job?.command.title ?? "a job") is running", tone: .warning)
            return
        }
        guard let brew = Homebrew.locate() else {
            self.brew = nil
            report(commandKind, "Homebrew isn't installed at /opt/homebrew/bin/brew or /usr/local/bin/brew", tone: .danger)
            return
        }
        self.brew = brew
        job = Job(command: commandKind, started: Date())
        if logs {
            log = []
            logTitle = "brew " + commandKind.arguments.joined(separator: " ")
        }
        let environment = Homebrew.environment(base: ProcessInfo.processInfo.environment, brew: brew, autoUpdate: commandKind.autoUpdate)
        let process = StreamingCommand(brew, commandKind.arguments, environment: environment, timeout: commandKind.timeout)
        command = process
        let handler: (@Sendable (StreamingCommand.Stream, String) -> Void)?
        if logs {
            handler = { [weak self] stream, line in self?.receive(line, isError: stream == .stderr) }
        } else {
            handler = nil
        }
        Task<Void, Never> { @MainActor in
            let result: StreamingCommand.Result
            do { result = try await process.run(onLine: handler) }
            catch { result = StreamingCommand.Result(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
            self.flushLog()
            self.job = nil
            self.command = nil
            if result.timedOut { self.append("Stopped after \(Int(commandKind.timeout / 60)) minutes without finishing.", isError: true); self.flushLog() }
            done(result)
            self.drainIdleQueue()
        }
    }

    /// Runs `action` now, or after the running job (and anything it chains)
    /// is done. The tiles use it: a click while Homebrew is busy waits
    /// instead of being refused.
    func whenIdle(_ action: @escaping () -> Void) {
        if isBusy { idleQueue.append(action) } else { action() }
    }

    private func drainIdleQueue() {
        while !isBusy, !idleQueue.isEmpty {
            idleQueue.removeFirst()()
        }
    }

    /// A line from the process's queue, handed to the main actor in order.
    nonisolated private func receive(_ line: String, isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.append(line, isError: isError) }
        }
    }

    private func append(_ text: String, isError: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pendingLines.append(LogLine(id: nextLine, text: text, isError: isError))
        nextLine += 1
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.flushLog() }
        }
    }

    private func flushLog() {
        flushScheduled = false
        guard !pendingLines.isEmpty else { return }
        log.append(contentsOf: pendingLines)
        pendingLines.removeAll()
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func finished(_ command: Homebrew.Command, _ result: StreamingCommand.Result, success: String) {
        if result.succeeded { report(command, success, tone: .success) } else { failed(command, result) }
    }

    private func failed(_ command: Homebrew.Command, _ result: StreamingCommand.Result) {
        let reason: String
        if result.cancelled { reason = "Cancelled" }
        else if result.timedOut { reason = "Stopped: it ran longer than \(Int(command.timeout / 60)) minutes" }
        else if Homebrew.neededTerminalPassword(result.stdout + result.stderr) {
            reason = "It needs an administrator password, which Homebrew can only ask for in Terminal. Run brew \(command.arguments.joined(separator: " ")) there."
        } else {
            let detail = result.failureDetail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            reason = "brew exited with status \(result.status)" + (detail.isEmpty ? "" : ": \(detail)")
        }
        report(command, "Couldn't finish \(command.title.lowercased()). \(reason)", tone: result.cancelled ? .warning : .danger)
    }

    private func report(_ command: Homebrew.Command, _ message: String, tone: AOMTone) {
        activity.insert(AOMLogEntry(tone: tone, message: message, detail: nil, source: "brew " + (command.arguments.first ?? "")), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
        toasts.show(message, tone: tone, seconds: tone == .danger ? 8 : nil)
    }

    func clearActivity() { activity.removeAll() }

    private func confirm(_ title: String, _ message: String, button: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Isolated UI previews only: sample lists, no brew run.
    func loadPreviewSample() {
        guard PresetManager.isUIPreview else { return }
        version = "Homebrew 7.0.9"
        checkedAt = Date().addingTimeInterval(-120)
        outdated = [
            .init(package: .init(kind: .formula, name: "atuin"), installedVersions: ["18.22.0"], currentVersion: "18.24.4", pinned: false),
            .init(package: .init(kind: .formula, name: "brotli"), installedVersions: ["1.2.0"], currentVersion: "1.2.1", pinned: false),
            .init(package: .init(kind: .formula, name: "node"), installedVersions: ["24.10.0"], currentVersion: "24.11.1", pinned: true),
            .init(package: .init(kind: .cask, name: "swish"), installedVersions: ["1.12"], currentVersion: "1.13.3", pinned: false)
        ]
        activity = [AOMLogEntry(date: Date().addingTimeInterval(-600), tone: .success, message: "Freed 43.9 MB", source: "brew cleanup")]
    }
}

// MARK: - Sheet

/// The Homebrew sheet: a header with the version, what's outdated and the
/// four maintenance buttons; tabs for Outdated, Installed, Services and
/// Search; the running job with Cancel; the live output; and the activity.
struct HomebrewSheet: View {
    @ObservedObject var model: HomebrewModel
    @State private var installedFilter = ""
    @State private var showsOutput = true
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(AOMSpace.x4)
            Divider()
            if model.brew == nil {
                AOMEmptyState("Homebrew isn't installed", systemImage: "mug",
                              message: "AOM looks for brew at /opt/homebrew/bin/brew and /usr/local/bin/brew.") {
                    Button("Check Again") { model.present(model.tab, refresh: true) }
                    Button("Open brew.sh") { if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) } }
                }
            } else {
                VStack(alignment: .leading, spacing: AOMSpace.x3) {
                    Picker("List", selection: $model.tab) {
                        ForEach(HomebrewModel.Tab.allCases) { tab in Text(tabTitle(tab)).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: model.tab) { _, tab in
                        model.load(tab)
                        if tab == .search { searchFocused = true }
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let job = model.job {
                        TimelineView(.periodic(from: job.started, by: 1)) { context in
                            AOMProgressRow(title: job.command.title, progress: nil,
                                           detail: elapsed(since: job.started, now: context.date), cancel: { model.cancel() },
                                           showsDivider: false)
                        }
                        .aomCard(padding: 0)
                    }
                    output
                    if !model.activity.isEmpty {
                        AOMLogSection("Activity", entries: model.activity, limit: 3, clear: { model.clearActivity() })
                    }
                }
                .padding(AOMSpace.x4)
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 600, idealHeight: 680)
        .background(AOMColor.canvas)
        .aomToast(model.toasts)
        .onExitCommand { dismiss() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            AOMModuleBadge(symbol: "mug.fill", size: AOMIcon.headerBadge)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(model.version ?? "Homebrew")
                    .font(AOMFont.pageStatus)
                    .lineLimit(1)
                Text(summary)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .help(model.brew.map { "brew at \($0.path)" } ?? "")
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x3)
            Group {
                Button("Check Now") { model.checkOutdated() }
                    .help("Lists outdated packages (brew outdated, without updating Homebrew first)")
                Button("Update") { model.update() }
                    .help("Fetches the newest Homebrew and package lists (brew update)")
                Button("Clean Up…") { model.cleanUp() }
                    .help("Shows how much brew cleanup -s frees, then asks")
                Button("Doctor") { model.doctor() }
                    .help("Runs brew doctor")
            }
            .disabled(model.isBusy || model.brew == nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let outdated = model.outdated {
            parts.append(outdated.isEmpty ? "Everything up to date" : "\(outdated.count) outdated")
        } else {
            parts.append("Not checked yet")
        }
        if let checked = model.checkedAt { parts.append("checked \(AOMRelativeTime.string(checked).lowercased())") }
        return parts.joined(separator: " · ")
    }

    private func tabTitle(_ tab: HomebrewModel.Tab) -> String {
        switch tab {
        case .outdated: return model.outdated.map { "Outdated (\($0.count))" } ?? "Outdated"
        case .installed: return model.installed.map { "Installed (\($0.count))" } ?? "Installed"
        case .services: return model.services.map { "Services (\($0.count))" } ?? "Services"
        case .search: return "Search"
        }
    }

    // MARK: Lists

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .outdated: outdatedList
        case .installed: installedList
        case .services: servicesList
        case .search: searchList
        }
    }

    @ViewBuilder private var outdatedList: some View {
        if let outdated = model.outdated {
            if outdated.isEmpty {
                AOMEmptyState("Everything is up to date", systemImage: "checkmark.circle",
                              message: "Update Homebrew to fetch the newest package lists, then check again.") {
                    Button("Update Homebrew") { model.update() }.disabled(model.isBusy)
                }
            } else {
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    List(outdated) { item in
                        AOMListRow(item.name, detail: item.pinned ? "\(item.change) · pinned, Upgrade All skips it" : item.change) {
                            Image(systemName: item.kind == .cask ? "macwindow" : "shippingbox")
                        } trailing: {
                            if item.kind == .cask { AOMStatusPill("Cask", tone: .neutral) }
                            Button("Upgrade") { model.upgrade(item) }
                                .disabled(model.isBusy)
                                .help("brew upgrade \(item.kind.flag) \(item.name)")
                        }
                        .contextMenu {
                            Button("Upgrade") { model.upgrade(item) }.disabled(model.isBusy)
                            Button("Copy Name") { copy(item.name) }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    HStack {
                        Text("Upgrade All skips pinned packages.").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        Spacer()
                        Button("Upgrade All (\(outdated.filter { !$0.pinned }.count))…") { model.requestUpgradeAll() }
                            .aomPrimaryButton()
                            .disabled(model.isBusy || outdated.allSatisfy(\.pinned))
                    }
                }
            }
        } else {
            placeholder("Not checked yet", symbol: "arrow.up.circle", action: "Check Now") { model.checkOutdated() }
        }
    }

    @ViewBuilder private var installedList: some View {
        if let installed = model.installed {
            let shown = installedFilter.isEmpty ? installed : installed.filter {
                $0.name.localizedCaseInsensitiveContains(installedFilter) || $0.summary.localizedCaseInsensitiveContains(installedFilter)
            }
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                TextField("Filter installed packages", text: $installedFilter)
                    .textFieldStyle(.roundedBorder)
                List(shown) { item in
                    AOMListRow(item.name, detail: [item.version, item.summary].filter { !$0.isEmpty }.joined(separator: " · "),
                               dimmed: !item.onRequest) {
                        Image(systemName: item.kind == .cask ? "macwindow" : "shippingbox")
                    } trailing: {
                        if item.outdated { AOMStatusPill("Update", tone: .info) }
                        if !item.onRequest { Text("dependency").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary) }
                        Button("Uninstall…", role: .destructive) { model.uninstall(item.package) }
                            .disabled(model.isBusy)
                    }
                    .help(item.homepage ?? item.name)
                    .contextMenu {
                        if let page = item.homepage, let url = URL(string: page) {
                            Button("Open Homepage") { NSWorkspace.shared.open(url) }
                        }
                        Button("Copy Name") { copy(item.name) }
                        Divider()
                        Button("Uninstall…", role: .destructive) { model.uninstall(item.package) }.disabled(model.isBusy)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        } else {
            placeholder("Not read yet", symbol: "shippingbox", action: "List Installed") { model.loadInstalled() }
        }
    }

    @ViewBuilder private var servicesList: some View {
        if let services = model.services {
            if services.isEmpty {
                AOMEmptyState("No Homebrew services", systemImage: "gearshape.2",
                              message: "Formulae such as postgresql or redis add services you can start here.")
            } else {
                List(services) { service in
                    AOMListRow(service.name, detail: service.file.map { URL(fileURLWithPath: $0).lastPathComponent }) {
                        Image(systemName: service.status.isRunning ? "play.circle.fill" : "stop.circle")
                    } trailing: {
                        AOMStatusPill(service.status.title, tone: service.status.isRunning ? .success : service.status == .error ? .danger : .neutral)
                        if service.status.isRunning {
                            Button("Restart") { model.service(.restart, service) }.disabled(model.isBusy)
                            Button("Stop") { model.service(.stop, service) }.disabled(model.isBusy)
                        } else {
                            Button("Start") { model.service(.start, service) }.disabled(model.isBusy)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        } else {
            placeholder("Not read yet", symbol: "gearshape.2", action: "List Services") { model.loadServices() }
        }
    }

    private var searchList: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                TextField("Formula or cask name", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .disabled(model.isBusy || model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let results = model.searchResults {
                if results.isEmpty {
                    AOMInlineEmpty(symbol: "magnifyingglass", message: "Nothing matches “\(model.searchText)”.")
                        .aomCard(padding: 0)
                    Spacer(minLength: 0)
                } else {
                    List(results) { package in
                        AOMListRow(package.name, detail: package.kind.title) {
                            Image(systemName: package.kind == .cask ? "macwindow" : "shippingbox")
                        } trailing: {
                            if model.isInstalled(package) {
                                AOMStatusPill("Installed", tone: .success)
                            } else {
                                Button("Install…") { model.install(package) }.disabled(model.isBusy)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else {
                AOMInlineEmpty(symbol: "magnifyingglass", message: "Search formulae and casks by name, then install one.")
                    .aomCard(padding: 0)
                Spacer(minLength: 0)
            }
        }
    }

    private func placeholder(_ message: String, symbol: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack {
            AOMInlineEmpty(symbol: symbol, message: model.isBusy ? "Reading…" : message, actionTitle: model.isBusy ? nil : action,
                           action: perform)
                .aomCard(padding: 0)
            Spacer(minLength: 0)
        }
    }

    // MARK: Output

    @ViewBuilder private var output: some View {
        if let title = model.logTitle {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                HStack(spacing: AOMSpace.x2) {
                    Button { withAnimation(AOMMotion.standard) { showsOutput.toggle() } } label: {
                        Label(title, systemImage: showsOutput ? "chevron.down" : "chevron.right")
                            .font(AOMFont.callout.monospaced())
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsOutput ? "Hide output of \(title)" : "Show output of \(title)")
                    Spacer()
                    Text("\(model.log.count) line\(model.log.count == 1 ? "" : "s")")
                        .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                    AOMIconButton("doc.on.doc", label: "Copy Output") {
                        copy(model.log.map(\.text).joined(separator: "\n"))
                    }
                }
                if showsOutput {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(model.log) { line in
                                    Text(line.text)
                                        .font(AOMFont.mono)
                                        .foregroundStyle(line.isError ? AOMColor.warningText : AOMColor.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                            }
                            .padding(AOMSpace.x2)
                        }
                        .frame(height: 150)
                        .background(AOMColor.field, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous).strokeBorder(AOMColor.hairline))
                        .onChange(of: model.log.last?.id) { _, last in
                            guard let last else { return }
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.toasts.show("Copied", tone: .success)
    }
}
