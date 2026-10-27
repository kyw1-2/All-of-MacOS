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
    @AppStorage(TitleBarWindowSnap.enabledKey) private var trackpadSnapOn = false
    @AppStorage(TitleBarWindowSnap.hapticKey) private var trackpadSnapHaptic = true
    @AppStorage(TitleBarWindowSnap.activateKey) private var trackpadSnapActivate = true
    @AppStorage(TitleBarWindowSnap.keepPointerKey) private var trackpadSnapKeepPointer = false
    @AppStorage(TrackpadUtilityGestures.spacesEnabledKey) private var topBarSpaceSwipe = true
    @AppStorage(TrackpadUtilityGestures.dockQuitEnabledKey) private var dockPinchQuit = true
    @State private var showingSnapOptions = false
    @State private var readiness: [TrackpadReadiness.Item] = []

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
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: AOMSpace.m) {
                            VStack(alignment: .leading, spacing: AOMSpace.m) {
                                previewCard
                                galleryCard
                                // The wide column gives the gesture legend and
                                // readiness rows room, and balances the page.
                                trackpadSnapCard
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: AOMSpace.m) {
                                WindowPinningCard()
                                snappingCard
                                zonesCard
                            }
                            // Grows a little on wide windows so rows wrap less;
                            // never below 300 pt.
                            .frame(width: min(360, max(300, geometry.size.width * 0.3)))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: AOMSpace.m) {
                            previewCard
                            galleryCard
                            WindowPinningCard()
                            snappingCard
                            trackpadSnapCard
                            zonesCard
                        }
                    }
                }
                .padding(.horizontal, wide ? AOMSpace.l : AOMSpace.m)
                .padding(.top, AOMSpace.m)
                .padding(.bottom, AOMSpace.l)
                .frame(maxWidth: AOMSize.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Window Tiling")
        .navigationSubtitle(appState.snapStatus)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    WindowSwitcherController.shared.show()
                } label: {
                    Label("Switch Windows", systemImage: "rectangle.stack")
                }
                .help("Thumbnail switcher for every open window (bind it in Settings ▸ Shortcuts)")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    Text("Drag to Snap").font(AOMType.body)
                    Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                         set: { appState.setSnappingEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.leading, 6)
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

    // MARK: - Preview

    /// A miniature of the screen: the layout under the pointer fills its
    /// region, so a layout is seen before it is used (Loop, Moom, Swish).
    private var previewCard: some View {
        let layout = hoveredLayout ?? .leftHalf
        return AOMSectionCard("Preview", symbol: "display", detail: hoveredLayout?.rawValue ?? "Point at a layout to see it") {
            if let hoveredLayout {
                Text(hoveredLayout == .nextDisplay ? "Moves to the next display" : "Click to apply")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
            }
        } content: {
            GeometryReader { geometry in
                let size = geometry.size
                let screen = RoundedRectangle(cornerRadius: 10, style: .continuous)
                let inset: CGFloat = 8
                let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2 - 10)
                let region = AOMTilingGeometry.rect(for: layout, in: inner).insetBy(dx: 3, dy: 3)
                ZStack(alignment: .topLeading) {
                    screen.fill(AOMTheme.cardAlt)
                    // The menu bar strip, so the miniature reads as a screen.
                    UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
                        .fill(AOMTheme.track)
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(hoveredLayout == nil ? 0.10 : 0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(hoveredLayout == nil ? 0.30 : 0.6), lineWidth: 1)
                        }
                        .overlay {
                            Image(systemName: layout == .nextDisplay ? "display.2" : "macwindow")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(Color.accentColor.opacity(hoveredLayout == nil ? 0.5 : 1))
                        }
                        .frame(width: max(0, region.width), height: max(0, region.height))
                        .offset(x: inset + region.minX, y: inset + 10 + region.minY)
                        .animation(AOMMotion.panel, value: hoveredLayout)
                }
            }
            .frame(height: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hoveredLayout.map { "Preview: \($0.rawValue)" } ?? "Layout preview")
    }

    // MARK: - Layout gallery

    private var galleryCard: some View {
        AOMSectionCard("Tile the Front Window", symbol: "rectangle.split.2x2",
                       detail: "Moves the frontmost window right away") {
            EmptyView()
        } content: {
            Grid(alignment: .leading, horizontalSpacing: AOMSpace.xs, verticalSpacing: AOMSpace.s) {
                ForEach(layoutGroups) { group in
                    GridRow {
                        Text(group.title)
                            .font(AOMType.caption.weight(.medium))
                            .foregroundStyle(AOMTheme.textSecondary)
                            .frame(width: 76, alignment: .leading)
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

    // MARK: - Snapping behaviour

    private var snappingCard: some View {
        let on = appState.currentPreset.snappingEnabled
        return AOMSectionCard("Drag to Snap", symbol: on ? "checkmark.circle.fill" : "pause.circle",
                              tint: on ? AOMTheme.positive : AOMTheme.textSecondary,
                              detail: on ? "On" : "Off") {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                Text(on ? "Drag a window to a screen edge, corner or snap zone and it fills that part of the screen."
                     : "Turn on Drag to Snap in the toolbar to place windows by dragging them to an edge, corner or zone.")
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, AOMSpace.xs)
                settingRow("Zones") {
                    Picker("Zones", selection: Binding<CustomSnapZone.Collection?>(
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
            .disabled(!on)
            .opacity(on ? 1 : 0.6)
        }
    }

    // MARK: - Trackpad gestures (Swish-style)

    /// Swish groups its trackpad gestures in one place and explains each
    /// prerequisite next to it; this card does the same for AOM's title-bar
    /// snap, top-bar Space swipe and Dock pinch.
    private var trackpadSnapCard: some View {
        AOMSectionCard("Trackpad Gestures", symbol: trackpadSnapOn ? "hand.draw.fill" : "hand.draw",
                       tint: trackpadSnapOn ? AOMTheme.positive : AOMTheme.textSecondary,
                       detail: trackpadSnapOn ? "Snap On" : "Snap Off") {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                Text("Swipe two fingers on a title bar: left or right for a half (further for a third), up to maximize, down to center. Add a leg along the other axis for a quarter, and swipe down on a snapped window to put it back.")
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, AOMSpace.xs)
                settingRow("Title-bar snap") {
                    Toggle("Title-bar snap", isOn: Binding(get: { trackpadSnapOn },
                                                           set: { trackpadSnapOn = $0; TitleBarWindowSnap.shared.refreshEnabled() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                settingRow("Haptic feedback") {
                    Toggle("Haptic feedback", isOn: $trackpadSnapHaptic)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!trackpadSnapOn)
                }
                DisclosureGroup(isExpanded: $showingSnapOptions) {
                    VStack(spacing: 0) {
                        settingRow("Bring window forward") {
                            Toggle("Bring window forward after snapping", isOn: $trackpadSnapActivate)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        settingRow("Keep pointer on title bar", showsDivider: false) {
                            Toggle("Keep pointer on the title bar after snapping", isOn: $trackpadSnapKeepPointer)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    .disabled(!trackpadSnapOn)
                } label: {
                    Text("Snap Options").font(AOMType.body).foregroundStyle(AOMTheme.text)
                }
                .frame(minHeight: 38)
                AOMDivider()
                settingRow("Top-bar Space swipe") {
                    Toggle("Top-bar Space swipe", isOn: $topBarSpaceSwipe)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Two fingers on the menu bar switch Spaces")
                settingRow("Dock pinch to quit", showsDivider: false) {
                    Toggle("Dock pinch to quit", isOn: $dockPinchQuit)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Pinch in on a Dock icon to quit that app")
                readinessList
                    .padding(.top, AOMSpace.xs)
            }
        }
        .onAppear(perform: refreshReadiness)
        .onChange(of: trackpadSnapOn) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapHaptic) { _, _ in refreshReadiness() }
        .onChange(of: topBarSpaceSwipe) { _, _ in gestureSettingChanged() }
        .onChange(of: dockPinchQuit) { _, _ in gestureSettingChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }

    /// Status shown passively next to each prerequisite, with a shape as well
    /// as a colour, and a direct route to the setting that fixes it.
    private var readinessList: some View {
        VStack(alignment: .leading, spacing: AOMSpace.xxs) {
            Text("Readiness")
                .font(AOMType.sectionCaps)
                .foregroundStyle(AOMTheme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(readiness) { item in
                HStack(alignment: .top, spacing: AOMSpace.xs) {
                    Image(systemName: item.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(AOMType.caption)
                        .foregroundStyle(item.ready ? AOMTheme.positive : AOMTheme.warning)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(AOMType.caption).foregroundStyle(AOMTheme.text)
                        Text(item.detail)
                            .font(AOMType.micro)
                            .foregroundStyle(AOMTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.title), \(item.ready ? "ready" : "needs attention"). \(item.detail)")
                    Spacer(minLength: AOMSpace.xxs)
                    if let fix = item.fix {
                        Button("Open…") { TrackpadReadiness.open(fix) }
                            .controlSize(.small)
                            .help("Open the System Settings pane that fixes this")
                            .accessibilityLabel("Open settings for \(item.title)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshReadiness() {
        // Returning from System Settings may have granted Accessibility.
        TitleBarWindowSnap.shared.refreshEnabled()
        readiness = TrackpadReadiness.current(hapticsWanted: trackpadSnapOn && trackpadSnapHaptic,
                                              spaceSwipeOn: topBarSpaceSwipe)
    }

    /// The same notification Settings rows post: the trackpad stream starts or
    /// stops when these gestures are its only consumers (AppState), and the
    /// title-bar snap picks up its switch.
    private func gestureSettingChanged() {
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        refreshReadiness()
    }

    private var zonesCard: some View {
        AOMSectionCard("Zones & Layouts", symbol: "square.grid.3x3",
                       detail: "\(appState.effectiveSnapZones.count) saved", contentPadding: AOMSpace.xs) {
            EmptyView()
        } content: {
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
            .frame(minHeight: 38)
            if showsDivider { AOMDivider() }
        }
    }

    private func navigationRow(_ title: String, detail: String, symbol: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(AOMType.rowTitle).foregroundStyle(AOMTheme.text).lineLimit(1)
                    Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, AOMSpace.xs)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.tile))
        .accessibilityLabel("\(title), \(detail)")
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
        AOMTilingGeometry.apply(layout) { success in
            if layout == .center {
                showToast(success ? "Centered window" : "Could not center window")
            } else {
                showToast("Tiled window to “\(layout.rawValue)”")
            }
        }
    }

    private func showToast(_ message: String) { toast.show(message) }
}

/// One layout in the gallery: its miniature and a short label. Pointing at it
/// previews the layout above, clicking applies it.
private struct SnapLayoutChip: View {
    let layout: CustomSnapZone.Layout
    let title: String
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExecute: () -> Void

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: AOMSpace.xs) {
                AOMLayoutDiagram(layout: layout, highlighted: isHovered)
                    .frame(width: 34)
                Text(title)
                    .font(AOMType.caption.weight(.medium))
                    .foregroundStyle(isHovered ? Color.accentColor : AOMTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.xs)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.tile))
        .onHover { onHover($0) }
        .help("Move the front window: \(layout.rawValue)")
        .accessibilityLabel("Tile front window: \(layout.rawValue)")
    }
}
