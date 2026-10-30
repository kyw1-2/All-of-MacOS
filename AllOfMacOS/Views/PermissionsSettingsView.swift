import AppKit
import SwiftUI

/// Native privacy dashboard. A refresh performs only read-only status queries.
/// Authorization changes are always made by the user in macOS System Settings.
struct PermissionsSettingsView: View {
    @State private var statuses: [AOMPermission: AOMPermissionStatus] = [:]
    @State private var refreshDate = Date()
    @State private var settingsError: String?
    @State private var permissionChangeMessage: String?

    private var requiredPermissions: [AOMPermission] { AOMPermission.required }
    private var optionalPermissions: [AOMPermission] { AOMPermission.optional }
    private var requiredGranted: Int {
        requiredPermissions.filter { statuses[$0] == .granted }.count
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                header

                // Notices sit above the lists they are about (e.6).
                if let settingsError {
                    AOMNotice(.warning, settingsError)
                }
                if let permissionChangeMessage {
                    AOMNotice(.info, permissionChangeMessage)
                }

                AOMSection("Core permissions", detail: "\(requiredGranted) of \(requiredPermissions.count)") {
                    ForEach(requiredPermissions) { permission in
                        permissionRow(permission)
                    }
                }

                AOMSection("Optional & per-app permissions",
                           footer: "'Check Manually' means macOS provides no safe general read-only check. A change may require restarting the app.") {
                    ForEach(optionalPermissions) { permission in
                        permissionRow(permission)
                    }
                }
            }
            .frame(maxWidth: AOMSize.readableWidth - AOMSpace.pageMargin * 2, alignment: .leading)
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.top, AOMSpace.x4)
            .padding(.bottom, AOMSpace.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// d.9: one sentence for the state of the required permissions, the
    /// count as context, and Refresh at the trailing edge.
    private var header: some View {
        let missing = requiredPermissions.count - requiredGranted
        return AOMPageHeader(missing == 0 ? "All required permissions are allowed"
                             : "\(missing) required permission\(missing == 1 ? " needs" : "s need") setup",
                             symbol: missing == 0 ? "checkmark.shield.fill" : "shield.lefthalf.filled",
                             subtitle: "\(requiredGranted) of \(requiredPermissions.count) required permissions granted · checked \(refreshDate.formatted(date: .omitted, time: .shortened))",
                             help: "This dashboard checks the permissions of the currently signed All of MacOS application. Return to this tab or press Refresh after changing access; AOM never changes access itself.") {
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func tone(_ status: AOMPermissionStatus) -> AOMTone {
        switch status {
        case .granted: return .success
        case .denied: return .warning
        case .notDetermined, .manualReview: return .neutral
        }
    }

    /// One permission: its symbol, name and what it allows, the state as a
    /// pill, and "Open". The whole row is the button that opens its System
    /// Settings pane, as before.
    private func permissionRow(_ permission: AOMPermission) -> some View {
        let status = statuses[permission] ?? .manualReview
        return Button {
            openSettings(permission)
        } label: {
            AOMSettingRow(permission.title, detail: permission.explanation, symbol: permission.icon) {
                HStack(spacing: AOMSpace.x3) {
                    AOMStatusPill(status.label, tone: tone(status), symbol: status.symbol)
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open \(permission.title) in macOS System Settings")
        .accessibilityLabel("Open \(permission.title) settings")
        .accessibilityIdentifier("AOMPermissionOpen_\(permission.rawValue)")
    }

    private func openSettings(_ permission: AOMPermission) {
        settingsError = nil
        if !permission.openSettings() {
            settingsError = "Could not open \(permission.title). Open System Settings → Privacy & Security manually."
        }
    }

    private func refresh() {
        let updated = Dictionary(uniqueKeysWithValues: AOMPermission.allCases.map { ($0, $0.status) })
        let changes = AOMPermissionTransitions.changed(from: statuses, to: updated)
        if let latest = changes.first {
            let text = "\(latest.permission.title): \(latest.to.label)"
            permissionChangeMessage = latest.restartMayBeNeeded
                ? "\(text). Restart the app if macOS has not applied the change."
                : "\(text). Access is rechecked automatically."
        }
        statuses = updated
        refreshDate = Date()
    }
}
