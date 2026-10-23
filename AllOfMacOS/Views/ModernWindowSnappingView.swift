import AppKit
import SwiftUI

/// Modern Apple-Native Window Snapping & Tiling Hub.
/// Provides an interactive visual desktop preview, drag-to-snap zones,
/// layout preset collections, and edge margin controls.
struct ModernWindowSnappingView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredLayout: CustomSnapZone.Layout?
    @StateObject private var toast = AOMToastModel()
    @State private var showingSnapZones = false
    @State private var showingProfiles = false
    @State private var showingWindowLayouts = false

    private let primaryLayouts: [CustomSnapZone.Layout] = [
        .leftHalf, .rightHalf, .maximize, .center,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird,
        .leftTwoThirds, .rightTwoThirds, .topHalf, .bottomHalf, .nextDisplay
    ]

    private var requiresOption: Bool {
        appState.activeSnapProfile?.requiresOption ?? appState.currentPreset.snappingRequiresOption
    }
    private var showsPreview: Bool {
        appState.activeSnapProfile?.showsPreview ?? appState.currentPreset.snappingShowsPreview
    }

    /// The collection whose layouts exactly match the enabled zones, if any.
    private var currentCollection: CustomSnapZone.Collection? {
        let enabled = appState.effectiveSnapZones.filter(\.isEnabled)
        return CustomSnapZone.Collection.allCases.first { collection in
            collection.replacing(enabled).count == enabled.count
                && collection.layouts.count == enabled.count
                && collection.replacing(enabled).allSatisfy { candidate in enabled.contains { $0.id == candidate.id } }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720
            ScrollView {
                VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                    AOMPageHeader("Window Tiling", subtitle: appState.snapStatus,
                                  systemImage: "rectangle.split.2x2.fill",
                                  tint: appState.currentPreset.snappingEnabled ? .blue : .gray) {
                        Toggle("Drag to Snap", isOn: Binding(
                            get: { appState.currentPreset.snappingEnabled },
                            set: { appState.setSnappingEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: AOMDesign.sectionSpacing) {
                            stageSection.frame(maxWidth: .infinity)
                            controlsColumn.frame(width: min(270, geometry.size.width * 0.36))
                        }
                    } else {
                        stageSection
                        controlsColumn
                    }
                    zonesGridSection
                }
                .padding(AOMDesign.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .suppressScrollerReservation()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMWorkspaceBackground())
        .aomToast(toast.message)
        .sheet(isPresented: $showingSnapZones) {
            CustomSnapZonesEditor(preset: appState.currentPreset, profile: appState.activeSnapProfile)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingProfiles) { SnapProfilesEditor().environmentObject(appState) }
        .sheet(isPresented: $showingWindowLayouts) { WindowLayoutsEditor() }
    }

    // MARK: - Controls column

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Snap Layouts", systemImage: "square.grid.2x2",
                             caption: "\(appState.effectiveSnapZones.filter(\.isEnabled).count) zones active")
            VStack(alignment: .leading, spacing: 10) {
                Picker("Collection", selection: Binding<CustomSnapZone.Collection?>(
                    get: { currentCollection },
                    set: { if let collection = $0 { applyCollection(collection) } }
                )) {
                    ForEach(CustomSnapZone.Collection.allCases) { collection in
                        Text("\(collection.rawValue) (\(collection.layouts.count))").tag(Optional(collection))
                    }
                    if currentCollection == nil {
                        Text("Custom").tag(CustomSnapZone.Collection?.none)
                    }
                }
                .pickerStyle(.menu)
                Divider()
                switchRow("Hold ⌥ Option while dragging", isOn: Binding(
                    get: { requiresOption },
                    set: { updateBehavior(requiresOption: $0, showsPreview: showsPreview) }
                ))
                switchRow("Show snap preview", isOn: Binding(
                    get: { showsPreview },
                    set: { updateBehavior(requiresOption: requiresOption, showsPreview: $0) }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .aomSurface()

            VStack(spacing: 8) {
                AOMActionTile(title: "Edit Snap Zones", systemImage: "rectangle.split.3x3", tint: .blue,
                              subtitle: "Draw custom zones and targets") { showingSnapZones = true }
                AOMActionTile(title: "Display Profiles", systemImage: "display.2", tint: .teal,
                              subtitle: appState.activeSnapProfile?.name ?? "Per-monitor layouts") { showingProfiles = true }
                AOMActionTile(title: "Saved Windows", systemImage: "macwindow.on.rectangle", tint: .indigo,
                              subtitle: "Window layouts and undo") { showingWindowLayouts = true }
            }
        }
    }

    // MARK: - Interactive Desktop Stage

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Preview", systemImage: "display",
                             caption: "Hover a layout below to see where a window lands")
            ZStack {
                RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.22, blue: 0.29), Color(red: 0.10, green: 0.13, blue: 0.19)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo").font(.system(size: 10))
                        Text("Finder").font(.system(size: 10, weight: .semibold))
                        Spacer()
                        TimelineView(.everyMinute) { context in
                            Text(context.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 20)
                    .background(.ultraThinMaterial.opacity(0.6))
                    GeometryReader { geo in
                        if let layout = hoveredLayout {
                            let rect = snapRect(for: layout, in: geo.size).insetBy(dx: 4, dy: 4)
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                                .overlay(Label(layout.rawValue, systemImage: layout.symbol)
                                    .font(.callout.weight(.semibold)))
                                .frame(width: max(0, rect.width), height: max(0, rect.height))
                                .position(x: rect.midX, y: rect.midY)
                                .animation(AOMDesign.animation(.spring(response: 0.3, dampingFraction: 0.85)), value: hoveredLayout)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "cursorarrow.and.square.on.square.dashed").font(.system(size: 26))
                                Text(requiresOption ? "Hold ⌥ and drag a window to an edge or corner" : "Drag a window to an edge or corner")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 218)
            .overlay(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hoveredLayout.map { "Preview: \($0.rawValue)" } ?? "Layout preview")
        }
    }

    // MARK: - Zones Grid Section

    private var zonesGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Tile the Front Window", systemImage: "rectangle.split.3x3",
                             caption: "Click a layout to move the frontmost window now")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: AOMDesign.gridSpacing)],
                      spacing: AOMDesign.gridSpacing) {
                ForEach(primaryLayouts) { layout in
                    SnapLayoutTile(
                        layout: layout,
                        isHovered: hoveredLayout == layout,
                        onHover: { hovering in
                            if hovering { hoveredLayout = layout } else if hoveredLayout == layout { hoveredLayout = nil }
                        },
                        onExecute: { executeSnap(layout) }
                    )
                }
            }
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }

    private func updateBehavior(requiresOption: Bool, showsPreview: Bool) {
        appState.updateSnapSettings(zones: appState.effectiveSnapZones,
                                    enabled: appState.currentPreset.snappingEnabled,
                                    requiresOption: requiresOption, showsPreview: showsPreview,
                                    profileID: appState.activeSnapProfile?.id)
    }

    // MARK: - Helpers

    private func applyCollection(_ collection: CustomSnapZone.Collection) {
        let newZones = collection.replacing(appState.effectiveSnapZones)
        appState.updateSnapSettings(
            zones: newZones,
            enabled: appState.currentPreset.snappingEnabled,
            requiresOption: appState.activeSnapProfile?.requiresOption ?? appState.currentPreset.snappingRequiresOption,
            showsPreview: appState.activeSnapProfile?.showsPreview ?? appState.currentPreset.snappingShowsPreview,
            profileID: appState.activeSnapProfile?.id
        )
        showToast("Applied “\(collection.rawValue)” snap layout set")
    }

    private func executeSnap(_ layout: CustomSnapZone.Layout) {
        let actionType: ActionType
        switch layout {
        case .leftHalf: actionType = .snapWindowLeft
        case .rightHalf: actionType = .snapWindowRight
        case .maximize: actionType = .maximizeWindow
        case .topHalf: actionType = .snapWindowTopHalf
        case .bottomHalf: actionType = .snapWindowBottomHalf
        case .topLeft: actionType = .snapWindowTopLeft
        case .topRight: actionType = .snapWindowTopRight
        case .bottomLeft: actionType = .snapWindowBottomLeft
        case .bottomRight: actionType = .snapWindowBottomRight
        case .center:
            var params = ActionParameters()
            params.snapX = 0.15
            params.snapY = 0.15
            params.snapWidth = 0.70
            params.snapHeight = 0.70
            WindowManager.shared.execute(.customSnapWindow, target: nil, parameters: params) { success in
                if success { showToast("Centered window") }
                else { showToast("Could not center window") }
            }
            return
        case .leftThird: actionType = .snapWindowLeftThird
        case .centerThird: actionType = .snapWindowCenterThird
        case .rightThird: actionType = .snapWindowRightThird
        case .leftTwoThirds: actionType = .snapWindowLeftTwoThirds
        case .rightTwoThirds: actionType = .snapWindowRightTwoThirds
        case .nextDisplay: actionType = .moveWindowNextMonitorAndMaximize
        }
        ActionExecutor.executeAction(TriggerAction(actionType: actionType))
        showToast("Tiled window to “\(layout.rawValue)”")
    }

    private func snapRect(for layout: CustomSnapZone.Layout, in size: CGSize) -> CGRect {
        let w = size.width
        let h = size.height
        let y0: CGFloat = 0

        switch layout {
        case .leftHalf:
            return CGRect(x: 0, y: y0, width: w * 0.5, height: h)
        case .rightHalf:
            return CGRect(x: w * 0.5, y: y0, width: w * 0.5, height: h)
        case .topHalf:
            return CGRect(x: 0, y: y0, width: w, height: h * 0.5)
        case .bottomHalf:
            return CGRect(x: 0, y: y0 + h * 0.5, width: w, height: h * 0.5)
        case .maximize:
            return CGRect(x: 0, y: y0, width: w, height: h)
        case .center:
            let cw = w * 0.70
            let ch = h * 0.70
            return CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        case .topLeft:
            return CGRect(x: 0, y: y0, width: w * 0.5, height: h * 0.5)
        case .topRight:
            return CGRect(x: w * 0.5, y: y0, width: w * 0.5, height: h * 0.5)
        case .bottomLeft:
            return CGRect(x: 0, y: y0 + h * 0.5, width: w * 0.5, height: h * 0.5)
        case .bottomRight:
            return CGRect(x: w * 0.5, y: y0 + h * 0.5, width: w * 0.5, height: h * 0.5)
        case .leftThird:
            return CGRect(x: 0, y: y0, width: w / 3, height: h)
        case .centerThird:
            return CGRect(x: w / 3, y: y0, width: w / 3, height: h)
        case .rightThird:
            return CGRect(x: (w / 3) * 2, y: y0, width: w / 3, height: h)
        case .leftTwoThirds:
            return CGRect(x: 0, y: y0, width: (w / 3) * 2, height: h)
        case .rightTwoThirds:
            return CGRect(x: w / 3, y: y0, width: (w / 3) * 2, height: h)
        case .nextDisplay:
            return CGRect(x: 0, y: y0, width: w, height: h)
        }
    }

    private func showToast(_ message: String) { toast.show(message) }
}

private struct SnapLayoutTile: View {
    let layout: CustomSnapZone.Layout
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExecute: () -> Void

    var body: some View {
        Button(action: onExecute) {
            VStack(spacing: 8) {
                Image(systemName: layout.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isHovered ? Color.white : Color.accentColor)
                    .frame(width: 40, height: 32)
                    .background(isHovered ? Color.accentColor : Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(layout.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .aomSurface(radius: AOMDesign.tileRadius, padding: nil, highlighted: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: isHovered)
        .help("Move the front window: \(layout.rawValue)")
        .accessibilityLabel("Tile front window: \(layout.rawValue)")
    }
}
