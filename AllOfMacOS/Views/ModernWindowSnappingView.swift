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

    /// Layouts grouped the way the Window menu groups them, with short labels
    /// (the full name stays in help and VoiceOver).
    private struct LayoutGroup: Identifiable {
        let title: String
        let layouts: [(layout: CustomSnapZone.Layout, label: String)]
        var id: String { title }
    }

    private let layoutGroups: [LayoutGroup] = [
        LayoutGroup(title: "Halves", layouts: [(.leftHalf, "Left"), (.rightHalf, "Right"), (.topHalf, "Top"), (.bottomHalf, "Bottom")]),
        LayoutGroup(title: "Quarters", layouts: [(.topLeft, "Top Left"), (.topRight, "Top Right"),
                                                 (.bottomLeft, "Bottom Left"), (.bottomRight, "Bottom Right")]),
        LayoutGroup(title: "Thirds", layouts: [(.leftThird, "Left"), (.centerThird, "Center"), (.rightThird, "Right")]),
        LayoutGroup(title: "Two Thirds", layouts: [(.leftTwoThirds, "Left"), (.rightTwoThirds, "Right")]),
        LayoutGroup(title: "Fill", layouts: [(.maximize, "Maximize"), (.center, "Center"), (.nextDisplay, "Next Display")])
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
            let wide = geometry.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Arrange your space")
                            .font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                            .accessibilityAddTraits(.isHeader)
                        Text("A place for every window. A little more room to focus.")
                            .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            layoutWorkspace
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            controlsColumn
                                .aomCardStyle(.paper, padding: 16, elevated: false)
                                .frame(width: 300)
                        }
                    } else {
                        layoutWorkspace
                        controlsColumn
                            .aomCardStyle(.paper, padding: 16, elevated: false)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMTheme.workspace)
        .navigationTitle("Window Tiling")
        .navigationSubtitle(appState.snapStatus)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    Text("Drag to Snap").font(AOMType.body)
                    Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                         set: { appState.setSnappingEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .help("Snap windows when you drag them to an edge, corner or zone")
            }
        }
        .aomToast(toast.message)
        .sheet(isPresented: $showingSnapZones) {
            CustomSnapZonesEditor(preset: appState.currentPreset, profile: appState.activeSnapProfile)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingProfiles) { SnapProfilesEditor().environmentObject(appState) }
        .sheet(isPresented: $showingWindowLayouts) { WindowLayoutsEditor() }
    }

    private var layoutWorkspace: some View {
        VStack(alignment: .leading, spacing: 24) {
            stageSection(height: 210)
            tileSection
        }
    }

    // MARK: - Controls column

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Snap Layouts").font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("\(appState.effectiveSnapZones.count) zones saved")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)

            Label(appState.currentPreset.snappingEnabled ? "Drag to Snap is on" : "Drag to Snap is off",
                  systemImage: appState.currentPreset.snappingEnabled ? "checkmark.circle.fill" : "pause.circle")
                .font(AOMType.caption)
                .foregroundStyle(appState.currentPreset.snappingEnabled ? AOMTheme.positive : AOMTheme.textSecondary)
                .padding(.horizontal, 8).padding(.bottom, 12)

            VStack(spacing: 0) {
                settingRow("Collection") {
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
                    .labelsHidden()
                    .frame(minWidth: 135)
                    .fixedSize()
                }
                settingRow("Require ⌥ Option") {
                    Toggle("Hold ⌥ Option while dragging", isOn: Binding(
                        get: { requiresOption },
                        set: { updateBehavior(requiresOption: $0, showsPreview: showsPreview) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                settingRow("Show snap preview", showsDivider: false) {
                    Toggle("Show snap preview", isOn: Binding(
                        get: { showsPreview },
                        set: { updateBehavior(requiresOption: requiresOption, showsPreview: $0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            AOMDivider().padding(.horizontal, 8).padding(.vertical, 8)

            VStack(spacing: 2) {
                navigationRow("Edit Snap Zones", detail: "Draw custom zones and targets",
                              symbol: "rectangle.split.3x3", tint: AOMTheme.blue) { showingSnapZones = true }
                navigationRow("Display Profiles", detail: appState.activeSnapProfile?.name ?? "Per-monitor layouts",
                              symbol: "display.2", tint: .teal) { showingProfiles = true }
                navigationRow("Saved Windows", detail: "Window layouts and undo",
                              symbol: "macwindow.on.rectangle", tint: AOMTheme.purple) { showingWindowLayouts = true }
            }
        }
    }

    private func settingRow<Control: View>(_ title: String, showsDivider: Bool = true,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(AOMType.body).foregroundStyle(AOMTheme.text).lineLimit(1)
                Spacer(minLength: 8)
                control()
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            Rectangle().fill(showsDivider ? AOMTheme.divider : .clear).frame(height: 1).padding(.horizontal, 8)
        }
    }

    private func navigationRow(_ title: String, detail: String, symbol: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: symbol, tint: tint, size: 32, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AOMType.rowTitle).foregroundStyle(AOMTheme.text).lineLimit(1)
                    Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 52)
        }
        .buttonStyle(AOMRowButtonStyle())
        .accessibilityLabel("\(title), \(detail)")
    }

    // MARK: - Interactive Desktop Stage

    private func stageSection(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack {
                Label("Layout preview", systemImage: "display")
                    .font(AOMType.caption.weight(.medium))
                Spacer()
                Text(hoveredLayout?.rawValue ?? "Side by side")
                    .font(AOMType.caption)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(AOMTheme.textSecondary)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AOMTheme.paper.opacity(0.7))
                        .frame(width: geo.size.width * 0.46, height: geo.size.height - 16)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle().fill(AOMTheme.textTertiary.opacity(0.4)).frame(width: 4, height: 4)
                                }
                            }
                            .padding(10)
                        }
                        .position(x: geo.size.width * 0.25, y: geo.size.height / 2)
                    let rect = snapRect(for: hoveredLayout ?? .rightHalf, in: geo.size).insetBy(dx: 7, dy: 8)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AOMTheme.blue.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AOMTheme.blue.opacity(0.45), lineWidth: 1)
                        }
                        .overlay {
                            Image(systemName: hoveredLayout?.symbol ?? "macwindow")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(AOMTheme.blue)
                        }
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .animation(AOMMotion.panel, value: hoveredLayout)
                }
            }
        }
        .padding(18)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AOMTheme.blue.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AOMTheme.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hoveredLayout.map { "Preview: \($0.rawValue)" } ?? "Layout preview: side by side")
    }

    // MARK: - Tile the front window

    private var tileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tile the Front Window").font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Click a layout to move the frontmost window now")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(layoutGroups) { group in
                    GridRow {
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AOMTheme.textSecondary)
                            .frame(width: 72, alignment: .leading)
                        ForEach(0..<4, id: \.self) { index in
                            if index < group.layouts.count {
                                let entry = group.layouts[index]
                                SnapLayoutChip(
                                    layout: entry.layout,
                                    title: entry.label,
                                    isHovered: hoveredLayout == entry.layout,
                                    onHover: { hovering in
                                        if hovering { hoveredLayout = entry.layout }
                                        else if hoveredLayout == entry.layout { hoveredLayout = nil }
                                    },
                                    onExecute: { executeSnap(entry.layout) }
                                )
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
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

/// One layout in the tile grid: a grey well with the layout glyph and a short
/// label; pointing at it previews the layout on the stage, clicking applies it.
private struct SnapLayoutChip: View {
    let layout: CustomSnapZone.Layout
    let title: String
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExecute: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: onExecute) {
            HStack(spacing: 8) {
                Image(systemName: layout.symbol)
                    .font(AOMType.bodyEmphasis)
                    .foregroundStyle(AOMTheme.blue)
                    .frame(width: 20)
                Text(title)
                    .font(AOMType.body.weight(.medium))
                    .foregroundStyle(isHovered ? AOMTheme.blue : AOMTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(isHovered ? AOMTheme.blue.opacity(0.12) : AOMTheme.paper, in: shape)
            .overlay(shape.strokeBorder(isHovered ? AOMTheme.blue.opacity(0.45) : AOMTheme.hairline, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { onHover($0) }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: isHovered)
        .help("Move the front window: \(layout.rawValue)")
        .accessibilityLabel("Tile front window: \(layout.rawValue)")
    }
}
