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
    @AppStorage(TitleBarWindowSnap.thirdsKey) private var trackpadSnapThirds = false
    @AppStorage(TitleBarWindowSnap.previewKey) private var trackpadSnapPreview = true
    @AppStorage(TitleBarWindowSnap.holdCancelKey) private var holdCancelSeconds = TitleBarWindowSnap.holdCancelDefault
    @AppStorage(TitleBarWindowSnap.pinchKey) private var trackpadSnapPinch = true
    @AppStorage(TitleBarWindowSnap.doubleTapKey) private var trackpadSnapDoubleTap = SwishSnap.DoubleTap.restoreOrCenter.rawValue
    @AppStorage(TitleBarWindowSnap.holdKey) private var trackpadSnapHold = true
    @AppStorage(TitleBarWindowSnap.downActionKey) private var trackpadSnapDownAction = SwishSnap.DownAction.minimize.rawValue
    @AppStorage(TitleBarWindowSnap.modifiersKey) private var trackpadSnapModifiers = true
    @AppStorage(TitleBarWindowSnap.sensitivityKey) private var trackpadSnapSensitivity = TitleBarWindowSnap.sensitivityDefault
    // 3.3.2 Swish snapping options. The grid is empty until chosen, and then
    // follows the 3.3.2 Thirds switch (`trackpadSnapGrid`).
    @AppStorage(TitleBarWindowSnap.gridKey) private var trackpadSnapGridRaw = ""
    @AppStorage(TitleBarWindowSnap.almostKey) private var trackpadSnapAlmost = false
    @AppStorage(TitleBarWindowSnap.hotkeysKey) private var trackpadSnapHotkeys = SwishSnap.HotkeyScheme.off.rawValue
    @AppStorage(TitleBarWindowSnap.dragUnsnapKey) private var trackpadSnapDragUnsnap = true
    @AppStorage(TitleBarWindowSnap.resizeAdjacentKey) private var trackpadSnapResizeAdjacent = true
    @AppStorage(TitleBarWindowSnap.resnapKey) private var trackpadSnapResnap = true
    @AppStorage(TitleBarWindowSnap.animationKey) private var trackpadSnapAnimation = SwishSnap.AnimationSpeed.normal.rawValue
    @AppStorage(TitleBarWindowSnap.marginKey) private var trackpadSnapMargin = 0.0
    @AppStorage(TitleBarWindowSnap.stageManagerOffsetKey) private var stageManagerOffset = 0.0
    @AppStorage(TrackpadUtilityGestures.spacesEnabledKey) private var topBarSpaceSwipe = true
    @AppStorage(TrackpadUtilityGestures.dockQuitEnabledKey) private var dockPinchQuit = true
    @AppStorage(TrackpadUtilityGestures.dockGesturesKey) private var dockGestures = true
    @AppStorage(TrackpadUtilityGestures.menuBarGesturesKey) private var menuBarGestures = true
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
                                // The switches people come here for go first;
                                // the large preview and the static gallery
                                // used to push them below the fold.
                                trackpadSnapCard
                                previewCard
                                galleryCard
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
                            snappingCard
                            trackpadSnapCard
                            previewCard
                            galleryCard
                            WindowPinningCard()
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
                VStack(alignment: .leading, spacing: AOMSpace.xxs) {
                    Text("Swipe two fingers on a title bar or toolbar: left or right for a half, up to maximize, down to \(trackpadSnapDownAction == SwishSnap.DownAction.center.rawValue ? "center" : "minimize"), diagonally for that quarter. Swipes chain from where the window is: a half swiped up or down becomes a quarter, a top quarter swiped down moves to the bottom, a diagonal swipe reaches any quarter from anywhere (a maximized or top-half window swiped ↙ goes to the bottom-left), and swiping toward an edge grows the window along it; swipe down on a maximized or bottom-edge window to put it back. Lift to apply. To cancel, add a third finger or rest your fingers without moving (2 s by default).")
                    Text("Pinch in to close the window, twice to quit the app; pinch out for full screen. Double tap to unsnap or center. Rest your fingers, then swipe: up for full screen, down to minimize, sideways to the next Space. ⌥ Option: swipe sideways for a Space, down to close; ⌥ or ⇧ Shift double tap hides the app or the other apps. ⌘ Command: swipe to move the window to the display that way.")
                    Text("Grid 3 × 2 adds thirds and their upper and lower halves, 3 × 3 ninths (swipe toward an edge to grow a cell). Drag a snapped window by its title bar to get its old size back; resize one of two snapped windows and the other follows; snapped windows re-snap after a display change. ⌃⌥ with the chosen keys swipes the front window from the keyboard.")
                }
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
                // Every snap option stays in view (3.3.2): the options used to
                // sit in a collapsed "Snap Options" group that was easy to miss.
                VStack(spacing: 0) {
                    settingRow("Swipe sensitivity") {
                        Picker("Swipe sensitivity", selection: sensitivitySelection) {
                            ForEach(Self.sensitivityPresets, id: \.value) { preset in
                                Text(preset.title).tag(preset.value)
                            }
                            // The Settings Hub slider writes any value in 0.5…2;
                            // one between the presets still shows here.
                            if Self.preset(trackpadSnapSensitivity, in: Self.sensitivityPresets) == nil {
                                Text("Custom (\(String(format: "%.2f", trackpadSnapSensitivity))×)")
                                    .tag(trackpadSnapSensitivity)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    }
                    .help("How little travel starts a swipe: Quick (default) engages after about 4 % of the trackpad, Instant after 3 %, Standard after 5 % as in 3.3.1. A quick two-finger tap never snaps at any setting; a quick flick that engaged always does.")
                    snapLayoutRows
                    settingRow("Swipe down on a free window") {
                        Picker("Swipe down on a free window", selection: $trackpadSnapDownAction) {
                            Text("Minimize (Swish)").tag(SwishSnap.DownAction.minimize.rawValue)
                            Text("Center").tag(SwishSnap.DownAction.center.rawValue)
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    }
                    .help("A short swipe down on a window that is not snapped. A longer swipe down still snaps it to the bottom half; a snapped window keeps moving between cells.")
                    settingRow("Double tap") {
                        Picker("Double tap", selection: $trackpadSnapDoubleTap) {
                            Text("Unsnap or Center").tag(SwishSnap.DoubleTap.restoreOrCenter.rawValue)
                            Text("Center").tag(SwishSnap.DoubleTap.center.rawValue)
                            Text("Off").tag(SwishSnap.DoubleTap.off.rawValue)
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    }
                    .help("Double tap two fingers on a title bar: put a window AOM snapped back where it was, or center it. With ⌥ Option it hides the app, with ⇧ Shift every other app.")
                    settingRow("Pinch gestures") {
                        Toggle("Pinch to close, quit or go full screen", isOn: $trackpadSnapPinch)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .help("Pinch in on a title bar to close the window, twice to quit the app (it may ask to save). Pinch out to enter or leave full screen; with two displays, pinch out twice or hold ⌘ for full screen on the other display.")
                    settingRow("Tap and hold gestures") {
                        Toggle("Tap and hold, then swipe", isOn: $trackpadSnapHold)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .help("Rest two fingers on a title bar for half a second, then swipe: up for full screen, down to minimize (also in full screen), left or right to move the window to the next Space.")
                    settingRow("Modifier gestures") {
                        Toggle("Modifier gestures", isOn: $trackpadSnapModifiers)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .help("⌥ Option: swipe sideways to move the window a Space, down to close it (rest first, or swipe down twice, to quit the app). ⌥ or ⇧ Shift double tap hides the app or the other apps. ⌘ Command: swipe to move the window to the display in that direction.")
                    snapBehaviourRows
                }
                .disabled(!trackpadSnapOn)
                .opacity(trackpadSnapOn ? 1 : 0.6)
                settingRow("Top-bar Space swipe") {
                    Toggle("Top-bar Space swipe", isOn: $topBarSpaceSwipe)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Two fingers on the menu bar switch Spaces")
                settingRow("Dock pinch to quit") {
                    Toggle("Dock pinch to quit", isOn: $dockPinchQuit)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Pinch in on a Dock icon to quit that app")
                settingRow("Dock gestures") {
                    Toggle("Dock gestures", isOn: $dockGestures)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Two fingers on a Dock icon: tap and hold to activate the app, swipe sideways through its windows, down to minimize, up to unminimize (⇧ all), double tap to hide (⇧ the others), pinch out for ⌘N. With Tap to click on, a two-finger tap is also a right-click, so the Dock menu may open.")
                settingRow("Menu-bar gestures") {
                    Toggle("Menu-bar gestures", isOn: $menuBarGestures)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Two fingers on the menu bar: tap and hold, then swipe for the previous or next app, or lift for the window switcher; double tap to unsnap (⇧ every display); swipe down to minimize all, up to bring them back (twice or ⇧ every display); ⌘ swipe moves snapped windows to the next display.")
                // Swish's cancel: rest the fingers without moving. Shared by
                // the title-bar snap and every menu-bar and Dock gesture.
                settingRow("Hold still to cancel", showsDivider: false) {
                    Picker("Hold still to cancel", selection: holdCancelSelection) {
                        ForEach(Self.holdCancelPresets, id: \.value) { preset in
                            Text(preset.title).tag(preset.value)
                        }
                        // The Settings Hub slider writes 0…3 s in 0.5 s steps
                        // (all presets here); any other value still shows.
                        if Self.preset(holdCancelSeconds, in: Self.holdCancelPresets) == nil {
                            Text("Custom (\(String(format: "%.1f", holdCancelSeconds)) s)").tag(holdCancelSeconds)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                }
                .help("Rest two fingers without moving for this long to cancel a title-bar gesture (snap, display or Space move, pinch, tap and hold), a top-bar Space swipe, or a menu-bar or Dock gesture: the touch then does nothing until you lift. The snap preview fades just before it goes.")
                readinessList
                    .padding(.top, AOMSpace.xs)
            }
        }
        .onAppear(perform: refreshReadiness)
        .onChange(of: trackpadSnapOn) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapHaptic) { _, _ in refreshReadiness() }
        .onChange(of: topBarSpaceSwipe) { _, _ in gestureSettingChanged() }
        .onChange(of: dockPinchQuit) { _, _ in gestureSettingChanged() }
        .onChange(of: dockGestures) { _, _ in gestureSettingChanged() }
        .onChange(of: menuBarGestures) { _, _ in gestureSettingChanged() }
        .onChange(of: holdCancelSeconds) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapHold) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapSensitivity) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapModifiers) { _, _ in refreshReadiness() }
        // The hotkeys and the mouse handlers start or stop with these.
        .onChange(of: trackpadSnapHotkeys) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapDragUnsnap) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapResizeAdjacent) { _, _ in gestureSettingChanged() }
        .onChange(of: trackpadSnapResnap) { _, _ in gestureSettingChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }

    /// The pickers' named values (3.3.2 review: the Settings Hub sliders
    /// write values these pickers did not offer, which left them blank).
    struct PickerPreset { let title: String; let value: Double }
    static let sensitivityPresets = [PickerPreset(title: "Relaxed", value: 0.8), PickerPreset(title: "Standard", value: 1.0),
                                     PickerPreset(title: "Quick", value: 1.25), PickerPreset(title: "Instant", value: 1.6)]
    static let holdCancelPresets = [PickerPreset(title: "Off", value: 0), PickerPreset(title: "0.5 s", value: 0.5),
                                    PickerPreset(title: "1 s", value: 1), PickerPreset(title: "1.5 s", value: 1.5),
                                    PickerPreset(title: "2 s", value: 2), PickerPreset(title: "2.5 s", value: 2.5),
                                    PickerPreset(title: "3 s", value: 3)]

    /// The preset a stored value stands for (a slider's 1.2500000000000002
    /// is Quick), or nil for a value between them.
    static func preset(_ value: Double, in presets: [PickerPreset]) -> PickerPreset? {
        presets.first { abs($0.value - value) < 0.001 }
    }

    private var sensitivitySelection: Binding<Double> {
        Binding(get: { Self.preset(trackpadSnapSensitivity, in: Self.sensitivityPresets)?.value ?? trackpadSnapSensitivity },
                set: { trackpadSnapSensitivity = $0 })
    }

    private var holdCancelSelection: Binding<Double> {
        Binding(get: { Self.preset(holdCancelSeconds, in: Self.holdCancelPresets)?.value ?? holdCancelSeconds },
                set: { holdCancelSeconds = $0 })
    }

    /// The grid as chosen, or, never chosen, what the 3.3.2 Thirds switch
    /// meant (3 × 2 when it was on). Choosing keeps that switch in step.
    private var trackpadSnapGrid: Binding<String> {
        Binding(get: {
            SwishSnap.Grid(rawValue: trackpadSnapGridRaw)?.rawValue
                ?? (trackpadSnapThirds ? SwishSnap.Grid.threeByTwo : .twoByTwo).rawValue
        }, set: { value in
            trackpadSnapGridRaw = value
            trackpadSnapThirds = (SwishSnap.Grid(rawValue: value) ?? .twoByTwo).thirds
        })
    }

    /// Where swipes and hotkeys put windows (3.3.2: Swish's grid, almost
    /// maximize, margin, Stage Manager offset and keyboard hotkeys).
    private var snapLayoutRows: some View {
        VStack(spacing: 0) {
            settingRow("Grid") {
                Picker("Grid", selection: trackpadSnapGrid) {
                    Text("2 × 2 · halves, quarters, no thirds").tag(SwishSnap.Grid.twoByTwo.rawValue)
                    Text("3 × 2 · thirds, sixths").tag(SwishSnap.Grid.threeByTwo.rawValue)
                    Text("3 × 3 · ninths").tag(SwishSnap.Grid.threeByThree.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            .help("2 × 2: halves and quarters only, never a third. 3 × 2: a longer swipe or a swipe toward an edge reaches thirds and two thirds, and a third swiped up or down takes its upper or lower half. 3 × 3: a third swiped up or down becomes a ninth; swipe a ninth toward an edge it touches to grow it to two-ninths, then toward its other edge to four-ninths.")
            settingRow("Almost maximize") {
                Toggle("Almost maximize", isOn: $trackpadSnapAlmost)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("Swipe up to fill almost the whole screen, leaving a small gap all round; swipe up again to maximize.")
            settingRow("Margin") {
                pointSlider(value: $trackpadSnapMargin, range: TitleBarWindowSnap.marginRange, step: 1, label: "Margin")
            }
            .help("The gap kept around every snapped window, in points.")
            settingRow("Stage Manager offset") {
                pointSlider(value: $stageManagerOffset, range: TitleBarWindowSnap.stageManagerOffsetRange, step: 10,
                            label: "Stage Manager offset")
            }
            .help("While Stage Manager is on, snapped windows leave this much room on the left for its strip of recent apps.")
            settingRow("Keyboard shortcuts") {
                Picker("Keyboard shortcuts", selection: $trackpadSnapHotkeys) {
                    Text("Off").tag(SwishSnap.HotkeyScheme.off.rawValue)
                    Text("⌃⌥ Arrows").tag(SwishSnap.HotkeyScheme.arrows.rawValue)
                    Text("⌃⌥ WASD").tag(SwishSnap.HotkeyScheme.wasd.rawValue)
                    Text("⌃⌥ IJKL").tag(SwishSnap.HotkeyScheme.ijkl.rawValue)
                    Text("⌃⌥ HJKL").tag(SwishSnap.HotkeyScheme.hjkl.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            .help("⌃⌥ and one of four keys acts like a swipe that way on the front window, chaining from where it is. A shortcut you bound to the same keys wins; paused, the keys go to the app.")
        }
    }

    /// What happens around a snap (3.3.2: the preview animation, drag to
    /// unsnap, resizing neighbours and re-snapping).
    private var snapBehaviourRows: some View {
        VStack(spacing: 0) {
            settingRow("Show preview") {
                Toggle("Show the snap preview while swiping", isOn: $trackpadSnapPreview)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("The translucent frame for a snap and the name of any other action, while your fingers are down")
            settingRow("Preview animation") {
                Picker("Preview animation", selection: $trackpadSnapAnimation) {
                    Text("Fast").tag(SwishSnap.AnimationSpeed.fast.rawValue)
                    Text("Normal").tag(SwishSnap.AnimationSpeed.normal.rawValue)
                    Text("Off").tag(SwishSnap.AnimationSpeed.off.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            .help("How quickly the preview appears, moves and fades. Off shows and hides it at once; Reduce Motion always keeps it from sliding.")
            settingRow("Bring window forward") {
                Toggle("Bring window forward after snapping", isOn: $trackpadSnapActivate)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            settingRow("Keep pointer on title bar") {
                Toggle("Keep pointer on the title bar after snapping", isOn: $trackpadSnapKeepPointer)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            settingRow("Drag to unsnap") {
                Toggle("Drag to unsnap", isOn: $trackpadSnapDragUnsnap)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("Drag a window AOM snapped by its title bar and it gets back its size from before the snap, under the pointer.")
            settingRow("Resize neighbours together") {
                Toggle("Resize neighbours together", isOn: $trackpadSnapResizeAdjacent)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("Resize a snapped window along an edge it shares with another snapped window, and when you let go that window follows the edge.")
            settingRow("Re-snap after display changes") {
                Toggle("Re-snap after display changes", isOn: $trackpadSnapResnap)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("When a display is connected, disconnected or rearranged, windows still where AOM snapped them take their place again on the display they end up on.")
        }
    }

    private func pointSlider(value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                             label: String) -> some View {
        HStack(spacing: AOMSpace.xs) {
            Slider(value: value, in: range, step: step)
                .frame(width: 120)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Text("\(Int(value.wrappedValue.rounded())) pt")
                .font(AOMType.caption.monospacedDigit())
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 44, alignment: .trailing)
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
        // The title-bar Space moves (tap and hold or ⌥, then sideways) post
        // the same Mission Control shortcuts as the top-bar Space swipe.
        let titleBarSpaces = trackpadSnapOn && (trackpadSnapHold || trackpadSnapModifiers)
        readiness = TrackpadReadiness.current(hapticsWanted: trackpadSnapOn && trackpadSnapHaptic,
                                              spaceSwipeOn: topBarSpaceSwipe || titleBarSpaces)
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
