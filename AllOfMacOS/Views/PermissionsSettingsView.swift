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
            VStack(spacing: 18) {
                summaryCard

                AppleSettingsGroup("Core Permissions") {
                    ForEach(Array(requiredPermissions.enumerated()), id: \.element.id) { index, permission in
                        permissionRow(permission, showDivider: index < requiredPermissions.count - 1)
                    }
                }

                AppleSettingsGroup("Optional & Per-App Permissions") {
                    ForEach(Array(optionalPermissions.enumerated()), id: \.element.id) { index, permission in
                        permissionRow(permission, showDivider: index < optionalPermissions.count - 1)
                    }
                }

                if let permissionChangeMessage {
                    Label(permissionChangeMessage, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let settingsError {
                    Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("This dashboard checks the permissions of the currently signed All of MacOS application. 'Check Manually' means macOS provides no safe general read-only check. A change may require restarting the app. Return to this tab or press Refresh after changing access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: requiredGranted == requiredPermissions.count
                  ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 25))
                .foregroundStyle(requiredGranted == requiredPermissions.count ? Color.green : Color.orange)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("Privacy & Permissions")
                    .font(.headline)
                Text("\(requiredGranted) of \(requiredPermissions.count) required permissions granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionRow(_ permission: AOMPermission, showDivider: Bool) -> some View {
        let status = statuses[permission] ?? .manualReview
        return Button {
            openSettings(permission)
        } label: {
            AppleSettingsRow(
                icon: permission.icon,
                iconColor: permission.essential ? .blue : .indigo,
                title: permission.title,
                subtitle: permission.explanation,
                showDivider: showDivider
            ) {
                HStack(spacing: 9) {
                    Label(status.label, systemImage: status.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(status.tint)
                        .fixedSize()
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
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
