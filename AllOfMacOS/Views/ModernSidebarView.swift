import AppKit
import SwiftUI

/// System sidebar rows provide keyboard navigation, focus and selection rendering.
struct ModernSidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAppPicker = false
    @Environment(\.openSettings) private var openSettingsAction

    private enum Destination: Hashable {
        case hub(AOMMainTab)
        case profile(UUID)
    }

    private var selection: Binding<Destination?> {
        Binding(get: {
            if appState.selectedMainTab == .gestures && !appState.selectedAppTarget.isGlobal {
                return .profile(appState.selectedAppTarget.id)
            }
            return .hub(appState.selectedMainTab)
        }, set: { destination in
            guard let destination else { return }
            switch destination {
            case .hub(let tab): appState.selectedMainTab = tab
            case .profile(let id):
                guard let app = appState.currentPreset.appTargets.first(where: { $0.id == id }) else { return }
                appState.selectedActivationGroupID = nil
                appState.selectedAppTarget = app
                appState.selectedTrigger = nil
                appState.selectedAction = nil
                appState.selectedMainTab = .gestures
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    ForEach(AOMMainTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.iconName)
                            .tag(Destination.hub(tab))
                    }
                }
                Section("Application Profiles") {
                    Button {
                        appState.selectedActivationGroupID = nil
                        appState.selectedAppTarget = .allApps
                        appState.selectedTrigger = nil
                        appState.selectedAction = nil
                        appState.selectedMainTab = .gestures
                    } label: {
                        Label("All Applications", systemImage: "globe")
                    }
                    .buttonStyle(.plain)
                    ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { app in
                        Label {
                            Text(app.name).lineLimit(1)
                        } icon: {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app")
                            }
                        }
                        .tag(Destination.profile(app.id))
                        .contextMenu {
                            Button("Remove Application Profile", role: .destructive) {
                                appState.removeAppTarget(app)
                            }
                        }
                    }
                    Button { showingAppPicker = true } label: {
                        Label("Add Application…", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .scrollIndicators(.hidden)
            .font(.body)

            HStack(spacing: 6) {
                Circle().fill(appState.globalEnabled ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Button(appState.globalEnabled ? "Active" : "Paused") { appState.toggleGlobalEnabled() }
                    .buttonStyle(.plain)
                    .help(appState.globalEnabled ? "Pause automation" : "Resume automation")
                Spacer()
                Button { openSettingsAction() } label: {
                    Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .popover(isPresented: $showingAppPicker) {
            AppPickerView { app in
                appState.addAppTarget(app)
                showingAppPicker = false
            }
            .frame(width: 320, height: 380)
        }
    }
}
