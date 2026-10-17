import SwiftUI

// Touch Viz — hand wiggles on hover
struct TouchVizToolbarButton: View {
    var isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var wiggle: Double = 0

    var body: some View {
        Button(action: action) {
            Label("Touch Viz", systemImage: "hand.point.up.braille.fill")
                .foregroundStyle(isActive || isHovering ? Color.cyan : .secondary)
                .rotationEffect(.degrees(wiggle), anchor: .bottom)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true)) {
                    wiggle = 12
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    wiggle = 0
                }
            }
        }
    }
}

// Console — cursor blink pulse on hover
struct ConsoleToolbarButton: View {
    var isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var opacity: Double = 1

    var body: some View {
        Button(action: action) {
            Label("Console", systemImage: "terminal.fill")
                .foregroundStyle(isActive || isHovering ? Color.green : .secondary)
                .opacity(isHovering ? opacity : 1)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                    opacity = 0.3
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    opacity = 1
                }
            }
        }
    }
}

// Appearance — sun/moon spins + bounces on hover
struct AppearanceToolbarButton: View {
    var isDark: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var rotation: Double = 0
    @State private var bounce: CGFloat = 0

    var body: some View {
        Button(action: action) {
            Label("Appearance", systemImage: isDark ? "moon.fill" : "sun.max.fill")
                .foregroundStyle(isDark ? Color.indigo : .yellow)
                .rotationEffect(.degrees(rotation))
                .offset(y: bounce)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
                withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                    bounce = -3
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    rotation = 0
                    bounce = 0
                }
            }
        }
    }
}

// Settings — gear spins on hover
struct SettingsToolbarButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @State private var rotation: Double = 0

    var body: some View {
        Button(action: action) {
            Label("Settings", systemImage: "gearshape.fill")
                .foregroundStyle(isHovering ? Color.primary : .secondary)
                .rotationEffect(.degrees(rotation))
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    rotation = 0
                }
            }
        }
    }
}

struct TopDeviceBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            // Preset Menu (Apple-native popup button aligned with sidebar width)
            Menu {
                Text("Active Preset: \(appState.currentPreset.name)")
                Divider()
                Button("Master Preset") { }
                Divider()
                Button("Export Preset…") { appState.presentPresetExport() }
                Button("Import Preset…") { appState.presentPresetImport() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(PresetManager.presetFilePath, inFileViewerRootedAtPath: "")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.2.square.on.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(appState.currentPreset.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(width: 194, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Switch or manage configuration presets")

            // Divider separating sidebar scope and main content categories
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1, height: 18)

            // Category Bar (Apple-style Segmented Control: strictly fixed height)
            HStack(spacing: 2) {
                ForEach(TriggerCategory.allCases) { category in
                    categoryTab(category)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )

            Spacer(minLength: 8)

            // Scope badge (if app/group is selected)
            if let id = appState.selectedActivationGroupID,
               let group = appState.currentPreset.activationGroups.first(where: { $0.id == id }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Group: \(group.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.quaternary.opacity(0.4), in: Capsule())
            } else if !appState.selectedAppTarget.isGlobal {
                HStack(spacing: 5) {
                    if let icon = appState.selectedAppTarget.icon {
                        Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                    } else {
                        Image(systemName: "app.fill").font(.system(size: 10)).foregroundStyle(.tint)
                    }
                    Text(appState.selectedAppTarget.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.quaternary.opacity(0.4), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(.background.opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
        }
    }

    private func categoryTab(_ category: TriggerCategory) -> some View {
        let isSelected = appState.selectedTriggerCategory == category
        let count = appState.triggers(in: category).count

        return Button {
            appState.selectedTriggerCategory = category
            appState.selectedTrigger = nil
            appState.selectedAction = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: category.iconName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Text(category.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                        )
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: Color.black.opacity(0.10), radius: 2, y: 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("AOMCategory_\(category.rawValue)")
    }
}

private struct AOMTriggerPaneHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var gestureLog = GestureLog.shared
    @AppStorage("AOMShowLog") private var showLog = true
    @AppStorage("AOMShowTouchVisualizer") private var showTouchVisualizer = true
    @State private var showTutorial = !UserDefaults.hasSeenTutorial
    @State private var tutorialFrames: [TutorialRegion: CGRect] = [:]
    @AppStorage("AOMAppearance") private var appearance: String = "dark"
    @Environment(\.openSettings) private var openSettingsAction

    private var isDark: Bool { appearance == "dark" }

    var body: some View {
        VStack(spacing: 0) {
            TopDeviceBar()
                .frame(height: 44)
            Divider()

            GeometryReader { available in
                HStack(spacing: 0) {
                    AppSidebar()
                        .frame(width: 210, height: available.size.height, alignment: .topLeading)
                        .tutorialAnchor(.sidebar)

                    Divider()

                    if appState.showStatistics {
                        StatisticsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HSplitView {
                            TriggerListPanel()
                                .frame(minWidth: 280, idealWidth: 320, maxWidth: 440, maxHeight: .infinity)
                                .background(GeometryReader { pane in
                                    Color.clear.preference(key: AOMTriggerPaneHeightKey.self, value: pane.size.height)
                                })
                                .tutorialAnchor(.triggers)

                            ActionInspectorPanel()
                                .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .tutorialAnchor(.actions)
                                .tutorialAnchor(.config)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: available.size.height)
                    }

                    if showLog || showTouchVisualizer {
                        VStack(spacing: 0) {
                            if showLog {
                                LogSidePanel(entries: gestureLog.entries)
                            }

                            if showTouchVisualizer {
                                if showLog { Divider() }
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("Live Touch")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)

                                    LiveTouchView()
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 8)
                                        .padding(.bottom, 8)
                                }
                                .frame(height: showLog ? 180 : 220)
                                .background(.background.opacity(0.30))
                            }
                        }
                        .frame(width: 260, height: available.size.height)
                        .transition(.move(edge: .trailing))
                    }
                }
                .frame(width: available.size.width, height: available.size.height, alignment: .topLeading)
            }
        }
        // The window is the material; panes on top of it are translucent fills.
        .translucentPane(.sidebar)
        .onPreferenceChange(AOMTriggerPaneHeightKey.self) { paneHeight in
            // Opt-in, single-value layout probe for diagnosing split view regressions.
            if UserDefaults.standard.bool(forKey: "AOMLayoutProbeEnabled") {
                UserDefaults.standard.set(Double(paneHeight), forKey: "AOMMeasuredTriggerPaneHeight")
            }
        }
        .coordinateSpace(name: "tutorialOverlay")
        .onPreferenceChange(TutorialFramePreferenceKey.self) { tutorialFrames = $0 }
        .overlay {
            if showTutorial {
                TutorialOverlayView(isPresented: $showTutorial, frames: tutorialFrames)
                    .environmentObject(appState)
            }
        }
        .onChange(of: appState.showTutorialRequested) { _, requested in
            if requested {
                showTutorial = true
                appState.showTutorialRequested = false
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Text("All of MacOS")
                        .font(.headline)
                    UpdateBadgeView(updateChecker: appState.updateChecker)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.toggleGlobalEnabled()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(appState.globalEnabled ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(appState.globalEnabled ? "ON" : "OFF")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(appState.globalEnabled ? .green : .red)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill((appState.globalEnabled ? Color.green : Color.red).opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(appState.globalEnabled ? "Disable all gestures" : "Enable all gestures")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TouchVizToolbarButton(isActive: showTouchVisualizer) {
                    withAnimation { showTouchVisualizer.toggle() }
                }

                ConsoleToolbarButton(isActive: showLog) {
                    withAnimation { showLog.toggle() }
                }

                AppearanceToolbarButton(isDark: isDark) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appearance = isDark ? "light" : "dark"
                    }
                }

                SettingsToolbarButton { openSettings() }
                    .help("App Settings")
            }
        }
        .preferredColorScheme(appearance == "system" ? nil : (isDark ? .dark : .light))
    }

    private func openSettings() {
        openSettingsAction()
    }
}
