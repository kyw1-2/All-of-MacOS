import AppKit
import SwiftUI

/// VPN state for the System Tools tiles and the VPN sheet. The VPN list
/// comes from `scutil --nc list` (fast, local); Tailscale's CLI is asked at
/// most every 20 s for the tiles and every 4 s while the sheet is open.
/// Nothing runs while neither is on screen.
@MainActor
final class VPNModel: ObservableObject {
    static let shared = VPNModel()

    @Published var isPresented = false
    @Published private(set) var services: [VPNTools.Service] = []
    /// The list as last read; nil until the first read.
    @Published private(set) var lastServices: [VPNTools.Service]?
    @Published private(set) var tailscale: VPNTools.TailscaleStatus?
    @Published private(set) var tailscaleMessage: String?
    @Published private(set) var busy: Set<String> = []
    let toasts = AOMToastModel()

    private var reading = false
    private var readingTailscale = false
    private var lastTailscaleRead: TimeInterval = -.infinity
    private var timer: Timer?

    var hasTailscale: Bool { VPNTools.tailscaleExecutable() != nil }
    var openVPNURL: URL? { VPNTools.openVPNConnectURL() }

    func present() {
        isPresented = true
        refresh()
        refreshTailscale(force: true)
    }

    /// The sheet's live state, every 2 s while it is open.
    func startLive() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshTailscale(force: false, interval: 4)
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopLive() {
        timer?.invalidate()
        timer = nil
    }

    /// Called with the page's slow refresh (every 4 s while it is visible).
    func refreshForTiles() {
        refresh()
        refreshTailscale(force: false, interval: 20)
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let output = try? SystemToolsCommand.run(VPNTools.scutil.path, VPNTools.listArguments())
            let list = output.map { VPNTools.parseServiceList($0.stdout) }
            await MainActor.run {
                self.reading = false
                guard let list else { return }
                if list != self.services { self.services = list }
                if self.lastServices != list { self.lastServices = list }
            }
        }
    }

    func refreshTailscale(force: Bool, interval: TimeInterval = 20) {
        guard let cli = VPNTools.tailscaleExecutable(), !readingTailscale else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastTailscaleRead >= interval else { return }
        lastTailscaleRead = now
        readingTailscale = true
        Task { @MainActor in
            let command = StreamingCommand(cli, ["status", "--json"], timeout: 8)
            let result = try? await command.run()
            self.readingTailscale = false
            guard let result else { self.tailscaleMessage = "Tailscale's command didn't run."; return }
            if let status = try? VPNTools.parseTailscaleStatus(Data(result.stdout.utf8)) {
                if self.tailscale != status { self.tailscale = status }
                self.tailscaleMessage = nil
            } else if VPNTools.tailscaleNotRunning(result.stdout + result.stderr) {
                self.tailscale = nil
                self.tailscaleMessage = "The Tailscale app isn't running. Open it to connect."
            } else {
                self.tailscaleMessage = result.failureDetail.isEmpty ? "Tailscale didn't answer." : result.failureDetail
            }
        }
    }

    /// Connect or Disconnect; the state follows within a few seconds.
    func toggle(_ service: VPNTools.Service) {
        guard !busy.contains(service.id) else { return }
        busy.insert(service.id)
        let connecting = !service.state.isUp
        Task { @MainActor in
            let command = StreamingCommand(VPNTools.scutil, VPNTools.toggleArguments(for: service), timeout: 20)
            let result = try? await command.run()
            if let result, result.succeeded {
                // scutil returns at once; wait (up to 15 s) for the new state.
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    self.refresh()
                    if let now = self.services.first(where: { $0.id == service.id }), now.state.isUp == connecting,
                       now.state != .connecting, now.state != .disconnecting { break }
                }
                let now = self.services.first(where: { $0.id == service.id })?.state
                if connecting && now != .connected {
                    self.toasts.show("Couldn't connect \(service.name): it stayed \(now?.title.lowercased() ?? "disconnected"). Check its settings or password in System Settings › VPN.",
                                     tone: .danger, seconds: 8)
                } else {
                    self.toasts.show(connecting ? "Connected \(service.name)" : "Disconnected \(service.name)", tone: .success)
                }
            } else {
                let reason = result?.failureDetail ?? "scutil didn't run"
                self.toasts.show("Couldn't \(connecting ? "connect" : "disconnect") \(service.name): \(reason)", tone: .danger, seconds: 8)
            }
            self.busy.remove(service.id)
            self.refresh()
        }
    }

    /// `Tailscale up` with no flags keeps the saved settings (exit node,
    /// routes); `down` disconnects without logging out.
    func setTailscale(up: Bool) {
        guard let cli = VPNTools.tailscaleExecutable(), !busy.contains("tailscale") else { return }
        if up, tailscale?.backend == .needsLogin {
            openTailscaleApp()
            toasts.show("Log in with the Tailscale app first", tone: .info)
            return
        }
        busy.insert("tailscale")
        Task { @MainActor in
            let command = StreamingCommand(cli, [up ? "up" : "down"], timeout: 30)
            let result = try? await command.run()
            self.busy.remove("tailscale")
            let output = (result?.stdout ?? "") + (result?.stderr ?? "")
            if let result, result.succeeded {
                self.toasts.show(up ? "Tailscale connected" : "Tailscale disconnected", tone: .success)
            } else if output.contains("login.tailscale.com") {
                command.cancel()
                self.openTailscaleApp()
                self.toasts.show("Tailscale needs you to log in; the Tailscale app is open", tone: .warning, seconds: 6)
            } else if VPNTools.tailscaleNotRunning(output) {
                self.toasts.show("Couldn't \(up ? "connect" : "disconnect"): the Tailscale app isn't running", tone: .danger, seconds: 6)
            } else {
                let reason = result?.timedOut == true ? "it didn't finish in 30 s" : (result?.failureDetail ?? "the command didn't run")
                self.toasts.show("Couldn't \(up ? "connect" : "disconnect") Tailscale: \(reason)", tone: .danger, seconds: 8)
            }
            self.refreshTailscale(force: true)
        }
    }

    func openTailscaleApp() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: VPNTools.tailscaleBundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: VPNTools.tailscaleAppStoreBundleID)
            ?? URL(fileURLWithPath: "/Applications/Tailscale.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openOpenVPN() {
        guard let url = openVPNURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openVPNSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Isolated UI previews only.
    func loadPreviewSample() {
        guard PresetManager.isUIPreview else { return }
        services = [
            .init(id: "11111111-2222-3333-4444-555555555555", name: "Campus VPN", type: "IPSec", state: .disconnected, enabled: true),
            .init(id: "FB2D4BFB-7674-4BF8-8B57-98D4E7E5C8FA", name: "Tailscale", type: "VPN (io.tailscale.ipn.macsys)", state: .connected, enabled: true)
        ]
        lastServices = services
        tailscale = .init(backend: .running, version: "1.98.10", addresses: ["100.101.102.103"], hostName: "MacBook-Air",
                          dnsName: "macbook-air.tail1234.ts.net", tailnet: "example.com", exitNode: nil, exitNodeOptions: 1,
                          onlinePeers: 3, health: [])
    }
}

/// VPN connections in one sheet: macOS's VPN services with Connect and
/// Disconnect, Tailscale with its address and exit node, and OpenVPN
/// Connect (which keeps its profiles to itself, so AOM only opens it).
struct VPNSheet: View {
    @ObservedObject var model: VPNModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: "lock.shield.fill", hue: .green, size: AOMIcon.headerBadge)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("VPN").font(AOMFont.pageStatus)
                    Text(summary).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                }
                Spacer()
                Button("VPN Settings…") { model.openVPNSettings() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    servicesSection
                    if model.hasTailscale { tailscaleSection }
                    openVPNSection
                }
            }
        }
        .padding(AOMSpace.x4)
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .background(AOMColor.canvas)
        .aomToast(model.toasts)
        .onAppear { model.startLive() }
        .onDisappear { model.stopLive() }
        .onExitCommand { dismiss() }
    }

    private var summary: String {
        let up = model.services.filter { $0.state == .connected }
        if up.isEmpty { return model.services.isEmpty ? "No VPN is set up in System Settings" : "Not connected" }
        return "Connected: " + up.map(\.name).joined(separator: ", ")
    }

    private var servicesSection: some View {
        AOMSection("VPN services", detail: model.services.isEmpty ? nil : "\(model.services.count)",
                   footer: "The VPNs set up in System Settings › VPN, with their live state (scutil --nc).") {
            if model.services.isEmpty {
                AOMInlineEmpty(symbol: "lock.shield", message: "No VPN is set up on this Mac.",
                               actionTitle: "VPN Settings…") { model.openVPNSettings() }
            } else {
                ForEach(model.services) { service in
                    AOMSettingRow(service.name, detail: "\(service.kindTitle)\(service.enabled ? "" : " · turned off in Settings")",
                                  symbol: service.state == .connected ? "lock.shield.fill" : "lock.shield") {
                        HStack(spacing: AOMSpace.x2) {
                            AOMStatusPill(service.state.title, tone: service.state == .connected ? .success
                                          : (service.state == .connecting || service.state == .disconnecting) ? .info : .neutral)
                            if model.busy.contains(service.id) {
                                ProgressView().controlSize(.small)
                            }
                            Button(service.state.isUp ? "Disconnect" : "Connect") { model.toggle(service) }
                                .disabled(model.busy.contains(service.id))
                        }
                    }
                    .contextMenu {
                        Button("Copy Service ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(service.id, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private var tailscaleSection: some View {
        AOMSection("Tailscale", detail: model.tailscale?.version.map { "v\($0)" }) {
            if let status = model.tailscale {
                AOMSettingRow(status.backend.title, detail: status.tailnet ?? status.dnsName,
                              symbol: "point.3.filled.connected.trianglepath.dotted") {
                    HStack(spacing: AOMSpace.x2) {
                        if model.busy.contains("tailscale") { ProgressView().controlSize(.small) }
                        switch status.backend {
                        case .running:
                            Button("Disconnect") { model.setTailscale(up: false) }.disabled(model.busy.contains("tailscale"))
                        case .stopped:
                            Button("Connect") { model.setTailscale(up: true) }.disabled(model.busy.contains("tailscale"))
                        default:
                            Button("Open Tailscale") { model.openTailscaleApp() }
                        }
                    }
                }
                AOMSettingRow("This Mac", detail: status.addresses.isEmpty ? "No Tailscale address yet" : status.addresses.joined(separator: "  ")) {
                    if let ip = status.ipv4 {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                            model.toasts.show("Copied \(ip)", tone: .success)
                        }
                    }
                }
                AOMSettingRow("Exit node", detail: status.exitNode ?? (status.exitNodeOptions > 0
                    ? "None · \(status.exitNodeOptions) available in the Tailscale app" : "None")) { EmptyView() }
                if !status.health.isEmpty {
                    AOMSettingRow("Health", detail: status.health.joined(separator: " · ")) { EmptyView() }
                }
            } else {
                AOMInlineEmpty(symbol: "point.3.filled.connected.trianglepath.dotted",
                               message: model.tailscaleMessage ?? "Reading Tailscale…",
                               actionTitle: "Open Tailscale") { model.openTailscaleApp() }
            }
        }
    }

    private var openVPNSection: some View {
        AOMSection("OpenVPN Connect", footer: "OpenVPN Connect keeps its profiles to itself, so connecting happens in the app.") {
            if model.openVPNURL != nil {
                AOMSettingRow("OpenVPN Connect", detail: "Installed", symbol: "shield.lefthalf.filled") {
                    Button("Open OpenVPN Connect") { model.openOpenVPN() }
                }
            } else {
                AOMSettingRow("OpenVPN Connect", detail: "Not installed on this Mac", symbol: "shield.lefthalf.filled") {
                    Button("Open OpenVPN Connect") {}
                        .disabled(true)
                        .help("Install OpenVPN Connect first")
                }
            }
        }
    }
}
