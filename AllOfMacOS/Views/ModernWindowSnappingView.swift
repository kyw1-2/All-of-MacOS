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

    /// Page padding and spacing around the sheet (the header is measured).
    static let chromeHeight: CGFloat = 0
    /// Everything in the sheet's left column except the stage: paddings, the
    /// gap and the five rows of layout chips with their heading (≈245 pt, plus
    /// a little slack so text metrics can never push the grid out of the sheet).
    static let tileBlockHeight: CGFloat = 20 + 20 + 256 + 20
    static let minimumStageHeight: CGFloat = 150
    static let maximumStageHeight: CGFloat = 280
    private let headerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820
            // When the window is tall enough the sheet fills it exactly and the
            // stage takes whatever height the tile grid leaves; otherwise the
            // stage keeps its minimum and the page scrolls.
            let sheetHeight = geometry.size.height - Self.chromeHeight - headerHeight
            let fits = wide && sheetHeight - Self.tileBlockHeight >= Self.minimumStageHeight
            let stageHeight = fits
                ? min(Self.maximumStageHeight, sheetHeight - Self.tileBlockHeight)
                : Self.minimumStageHeight
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 20) {
                                    stageSection(height: stageHeight)
                                    tileSection
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                AOMDivider(axis: .vertical)
                                controlsColumn
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 14)
                                    .frame(width: 330)
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                            .frame(height: fits ? sheetHeight : nil)
                            .fixedSize(horizontal: false, vertical: !fits)
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                stageSection(height: stageHeight)
                                tileSection
                                AOMDivider()
                                controlsColumn
                            }
                            .padding(20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollDisabled(fits)
            .suppressScrollerReservation()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aomPane()
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

    // MARK: - Controls column

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Snap Layouts").font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("\(appState.effectiveSnapZones.filter(\.isEnabled).count) zones active")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)

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
                    .frame(minWidth: 170)
                    .fixedSize()
                }
                settingRow("Hold ⌥ Option while dragging") {
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
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.23, blue: 0.28), Color(red: 0.12, green: 0.14, blue: 0.18)],
                                     startPoint: .top, endPoint: .bottom))
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
                .background(Color.white.opacity(0.08))
                GeometryReader { geo in
                    if let layout = hoveredLayout {
                        let rect = snapRect(for: layout, in: geo.size).insetBy(dx: 5, dy: 5)
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AOMTheme.blue.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                            .overlay(Label(layout.rawValue, systemImage: layout.symbol)
                                .font(AOMType.bodyEmphasis)
                                .foregroundStyle(.white))
                            .frame(width: max(0, rect.width), height: max(0, rect.height))
                            .position(x: rect.midX, y: rect.midY)
                            .animation(AOMDesign.animation(.spring(response: 0.3, dampingFraction: 0.85)), value: hoveredLayout)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "cursorarrow.and.square.on.square.dashed").font(.system(size: 26))
                            Text(requiresOption ? "Hold ⌥ and drag a window to an edge or corner" : "Drag a window to an edge or corner")
                                .font(AOMType.body.weight(.medium))
                            Text("Point at a layout below to preview it")
                                .font(AOMType.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hoveredLayout.map { "Preview: \($0.rawValue)" } ?? "Layout preview")
    }

    // MARK: - Tile the front window

    private var tileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Tile the Front Window").font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Click a layout to move the frontmost window now")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(layoutGroups) { group in
                    GridRow {
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AOMTheme.textTertiary)
                            .frame(width: 84, alignment: .leading)
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
            .background(isHovered ? AOMTheme.blue.opacity(0.12) : AOMTheme.cardAlt, in: shape)
            .overlay(shape.strokeBorder(isHovered ? AOMTheme.blue.opacity(0.45) : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { onHover($0) }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: isHovered)
        .help("Move the front window: \(layout.rawValue)")
        .accessibilityLabel("Tile front window: \(layout.rawValue)")
    }
}
