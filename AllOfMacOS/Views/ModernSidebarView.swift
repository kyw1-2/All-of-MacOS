import AppKit
import SwiftUI

/// Modern Apple-Native Sidebar for All of MacOS.
/// Completely eliminates the legacy BTT/GTT multi-level activation group clutter,
/// replacing it with clean, dedicated Super-App Hubs and sleek App Profiles.
struct ModernSidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    @Binding var showingCommandPalette: Bool
    @Binding var isCollapsed: Bool
    @State private var showingAppPicker = false
    @AppStorage("AOMAppearance") private var appearance: String = "dark"
    @Environment(\.openSettings) private var openSettingsAction

    private var isDark: Bool { appearance == "dark" }

    var body: some View {
        VStack(spacing: 0) {
            // App Branding Header
            sidebarHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. Super App Hubs
                    hubsSection

                    Divider()
                        .padding(.horizontal, 4)

                    // 2. App Scope Profiles
                    appProfilesSection
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .suppressScrollerReservation()

            Divider()

            // Footer: Engine Switch & Quick Launcher
            sidebarFooter
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
        .background(.regularMaterial)
        .popover(isPresented: $showingAppPicker) {
            AppPickerView { app in
                appState.addAppTarget(app)
                showingAppPicker = false
            }
            .frame(width: 320, height: 380)
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
            }

            Text("All of MacOS")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            UpdateBadgeView(updateChecker: appState.updateChecker)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Collapse Sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    // MARK: - Hubs Section

    private var hubsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HUBS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            ForEach(AOMMainTab.allCases) { tab in
                let isSelected = appState.selectedMainTab == tab

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.selectedMainTab = tab
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab.accentColor.opacity(isSelected ? 0.9 : 0.15))
                                .frame(width: 24, height: 24)

                            Image(systemName: tab.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white : tab.accentColor)
                        }

                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

                        Spacer()

                        if isSelected {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(tab.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? tab.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - App Profiles Section

    private var appProfilesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("APP PROFILES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    showingAppPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add an application profile")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            // Global Scope
            appScopeRow(
                app: .allApps,
                isSelected: appState.selectedActivationGroupID == nil && appState.selectedAppTarget.isGlobal
            )

            // User Defined Apps
            ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { app in
                appScopeRow(
                    app: app,
                    isSelected: appState.selectedActivationGroupID == nil && appState.selectedAppTarget.id == app.id
                )
            }
        }
    }

    private func appScopeRow(app: AppTarget, isSelected: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                appState.selectedActivationGroupID = nil
                appState.selectedAppTarget = app
                appState.selectedTrigger = nil
                appState.selectedAction = nil
                // If on another tab, clicking an app profile focuses gestures
                if appState.selectedMainTab != .gestures {
                    appState.selectedMainTab = .gestures
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: app.isGlobal ? "globe" : "app.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                }

                Text(app.name)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !app.isGlobal {
                Button("Remove Application Profile", role: .destructive) {
                    appState.removeAppTarget(app)
                }
            }
        }
    }

    // MARK: - Footer

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.toggleGlobalEnabled()
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(appState.globalEnabled ? Color.green : Color.red)
                        .frame(width: 7, height: 7)

                    Text(appState.globalEnabled ? "Active" : "Paused")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appState.globalEnabled ? .green : .red)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill((appState.globalEnabled ? Color.green : Color.red).opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help(appState.globalEnabled ? "Disable gestures" : "Enable gestures")

            Spacer(minLength: 4)

            // Utility Quick Access Buttons (Command Palette, Touch Visualizer, Console, Theme, Settings)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        showingCommandPalette.toggle()
                    }
                } label: {
                    Image(systemName: "command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Command Palette (⌘K)")

                Button {
                    withAnimation { showTouchVisualizer.toggle() }
                } label: {
                    Image(systemName: "hand.point.up.braille")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(showTouchVisualizer ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Touch Visualizer")

                Button {
                    withAnimation { showLog.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(showLog ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Console Diagnostics")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appearance = isDark ? "light" : "dark"
                    }
                } label: {
                    Image(systemName: isDark ? "sun.max" : "moon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Dark/Light Appearance")

                Button {
                    openSettingsAction()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("App Settings (⌘,)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.35))
    }
}
