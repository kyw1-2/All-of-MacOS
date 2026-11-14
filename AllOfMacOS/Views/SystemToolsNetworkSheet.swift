import AppKit
import SwiftUI

/// The Network Info sheet: local address, public address (fetched only when
/// the sheet opens or the user refreshes), Wi-Fi details and DNS servers,
/// each one line that copies itself.
struct NetworkInfoSheet: View {
    @ObservedObject var model: SystemToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var publicIP: String?
    @State private var publicIPError: String?
    @State private var fetchingPublicIP = false
    @State private var dnsServers: [String] = []

    private var localAddress: SystemStatus.InterfaceAddress? {
        SystemStatus.preferredAddress(SystemStatus.ipv4Addresses())
    }

    private var wifi: NetworkTools.WiFiDetails? { NetworkTools.wifiDetails() }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: "network", hue: .green, size: AOMIcon.headerBadge)
                Text("Network Info").font(AOMFont.pageStatus)
                Spacer()
                Button("Refresh") { refresh() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    AOMSection("This Mac") {
                        AOMSettingRow("Local address", detail: localAddress.map { "\($0.address) · \($0.interface)" } ?? "No IPv4 address") {
                            Button("Copy") { copy(localAddress?.address) }
                                .disabled(localAddress == nil)
                        }
                        AOMSettingRow("Public address", detail: fetchingPublicIP ? "Asking api64.ipify.org…"
                                      : (publicIP ?? publicIPError ?? "Not checked")) {
                            Button("Copy") { copy(publicIP) }.disabled(publicIP == nil)
                        }
                    }
                    AOMSection("Wi-Fi", footer: "macOS shows the network name only with Location permission.") {
                        ForEach(wifi?.lines ?? ["This Mac has no Wi-Fi interface."], id: \.self) { line in
                            AOMSettingRow(line, showsDivider: line != wifi?.lines.first) { EmptyView() }
                        }
                    }
                    AOMSection("DNS servers", detail: dnsServers.isEmpty ? nil : "\(dnsServers.count)") {
                        if dnsServers.isEmpty {
                            AOMSettingRow("No DNS servers reported", detail: "The Mac may be offline") { EmptyView() }
                        } else {
                            ForEach(Array(dnsServers.enumerated()), id: \.element) { index, server in
                                AOMSettingRow(server, showsDivider: index > 0) { EmptyView() }
                            }
                            AOMSettingRow("Copy All", showsDivider: true) {
                                Button("Copy") { copy(dnsServers.joined(separator: "\n")) }
                            }
                        }
                    }
                }
            }
        }
        .padding(AOMSpace.x4)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 480)
        .background(AOMColor.canvas)
        .aomToast(model.toasts)
        .onAppear(perform: refresh)
        .onExitCommand { dismiss() }
    }

    private func refresh() {
        dnsServers = NetworkTools.dnsServers()
        guard !fetchingPublicIP else { return }
        fetchingPublicIP = true
        publicIPError = nil
        Task {
            defer { fetchingPublicIP = false }
            do { publicIP = try await NetworkTools.publicIP() }
            catch { publicIPError = error.localizedDescription }
        }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.toasts.show("Copied \(text)", tone: .success)
    }
}
