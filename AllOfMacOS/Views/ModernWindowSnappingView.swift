import AppKit
import SwiftUI

/// Window Tiling (3.3.3 layout, ux-refs §d.9, e.1–e.4).
///
/// One page header (status sentence, the Drag to Snap master switch, ⓘ), then
/// sections of at most a handful of rows each: Title-bar snap, Gestures, Grid
/// & layout, Keyboard, Dock & menu bar, Advanced and Readiness on the left;
/// Drag to Snap, Tile the front window, Always on Top and Zones & layouts on
/// the right. The long explanations live in ⓘ popovers and in each row's
/// tooltip instead of caption walls. Every row, key and binding of 3.3.2 is
/// kept.
struct ModernWindowSnappingView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredLayout: CustomSnapZone.Layout?
    @StateObject private var toast = AOMToastModel()
    @State private var showingSnapZones = false
    @State private var showingProfiles = false
    @State private var showingWindowLayouts = false
    @State private var showsAdvanced = false
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
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    header
                    if wide {
                        HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                                titleBarSection
                                gesturesSection
                                gridSection
                                keyboardSection
                                dockSection
                                advancedSection
                                readinessSection
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                                dragSection
                                gallerySection(compact: true)
                                WindowPinningCard()
                                zonesSection
                            }
                            // Grows a little on wide windows so rows wrap less;
                            // never below 300 pt.
                            .frame(width: min(370, max(300, geometry.size.width * 0.32)))
                        }
                    } else {
                        dragSection
                        titleBarSection
                        gesturesSection
                        gridSection
                        keyboardSection
                        dockSection
                        gallerySection(compact: false)
                        WindowPinningCard()
                        zonesSection
                        advancedSection
                        readinessSection
                    }
                }
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.x4)
                .padding(.bottom, AOMSpace.x8)
                .frame(maxWidth: AOMSize.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
            .aomScrollEdge()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMColor.canvas)
        .navigationTitle("Window Tiling")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    WindowSwitcherController.shared.show()
                } label: {
                    Label("Switch Windows", systemImage: "rectangle.stack")
                }
                .help("Thumbnail switcher for every open window (bind it in Settings ▸ Shortcuts)")
            }
        }
        .aomToast(toast.message)
        .sheet(isPresented: $showingSnapZones) {
            CustomSnapZonesEditor(preset: appState.currentPreset, profile: appState.activeSnapProfile)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingProfiles) { SnapProfilesEditor().environmentObject(appState) }
        .sheet(isPresented: $showingWindowLayouts) { WindowLayoutsEditor() }
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

    // MARK: - Header

    private var header: some View {
        let drag = appState.currentPreset.snappingEnabled
        let on = drag || trackpadSnapOn
        let paused = !appState.globalEnabled
        let title = paused ? "Window Tiling is paused" : (on ? "Window Tiling is on" : "Window Tiling is off")
        let parts = [appState.snapStatus, trackpadSnapOn ? "title-bar swipes on" : "title-bar swipes off"]
        return AOMPageHeader(title, module: .tiling, subtitle: parts.joined(separator: " · "),
                             status: paused ? AOMStatus("Paused", tone: .neutral) : nil,
                             help: "Drag a window to a screen edge, corner or snap zone to fill that part of the screen, or swipe two fingers on its title bar. The layouts on the right tile the front window right away.",
                             active: on && !paused) {
            HStack(spacing: AOMSpace.x2) {
                Text("Drag to Snap").font(AOMFont.body)
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                     set: { appState.setSnappingEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .help("Snap windows when you drag them to an edge, corner or zone")
        }
    }

    // MARK: - Title-bar snap

    private var swipeHelp: String {
        "Swipe two fingers on a title bar or toolbar: left or right for a half, up to maximize, down to \(trackpadSnapDownAction == SwishSnap.DownAction.center.rawValue ? "center" : "minimize"), diagonally for that quarter. Swipes chain from where the window is: a half swiped up or down becomes a quarter, a top quarter swiped down moves to the bottom, a diagonal swipe reaches any quarter from anywhere (a maximized or top-half window swiped ↙ goes to the bottom-left), and swiping toward an edge grows the window along it; swipe down on a maximized or bottom-edge window to put it back. Lift to apply. To cancel, add a third finger or rest your fingers without moving (2 s by default)."
    }

    private var titleBarSection: some View {
        AOMSection("Title-bar snap", detail: trackpadSnapOn ? "On" : "Off", help: swipeHelp) {
            AOMToggleRow("Title-bar snap", detail: "Swipe two fingers on a title bar to snap the window",
                         isOn: Binding(get: { trackpadSnapOn },
                                       set: { trackpadSnapOn = $0; TitleBarWindowSnap.shared.refreshEnabled() }))
            Group {
                AOMToggleRow("Haptic feedback", indent: true, isOn: $trackpadSnapHaptic)
                AOMSettingRow("Swipe sensitivity", indent: true,
                              help: "How little travel starts a swipe: Quick (default) engages after about 4 % of the trackpad, Instant after 3 %, Standard after 5 % as in 3.3.1. A quick two-finger tap never snaps at any setting; a quick flick that engaged always does.") {
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
                    .pickerStyle(.menu)
                }
                .help("How little travel starts a swipe: Quick (default) engages after about 4 % of the trackpad, Instant after 3 %, Standard after 5 % as in 3.3.1. A quick two-finger tap never snaps at any setting; a quick flick that engaged always does.")
                AOMSettingRow("Swipe down on a free window", indent: true,
                              help: "A short swipe down on a window that is not snapped. A longer swipe down still snaps it to the bottom half; a snapped window keeps moving between cells.") {
                    Picker("Swipe down on a free window", selection: $trackpadSnapDownAction) {
                        Text("Minimize (Swish)").tag(SwishSnap.DownAction.minimize.rawValue)
                        Text("Center").tag(SwishSnap.DownAction.center.rawValue)
                    }
                    .pickerStyle(.menu)
                }
                .help("A short swipe down on a window that is not snapped. A longer swipe down still snaps it to the bottom half; a snapped window keeps moving between cells.")
            }
            .disabled(!trackpadSnapOn)
            .opacity(trackpadSnapOn ? 1 : 0.55)
        }
    }

    // MARK: - Gestures

    private var gesturesHelp: String {
        "Pinch in to close the window, twice to quit the app; pinch out for full screen. Double tap to unsnap or center. Rest your fingers, then swipe: up for full screen, down to minimize, sideways to the next Space. ⌥ Option: swipe sideways for a Space, down to close; ⌥ or ⇧ Shift double tap hides the app or the other apps. ⌘ Command: swipe to move the window to the display that way."
    }

    private var gesturesSection: some View {
        AOMSection("Gestures", help: gesturesHelp,
                   footer: trackpadSnapOn ? nil : "Turn on Title-bar snap to use these gestures.") {
            Group {
                AOMSettingRow("Double tap",
                              help: "Double tap two fingers on a title bar: put a window AOM snapped back where it was, or center it. With ⌥ Option it hides the app, with ⇧ Shift every other app.") {
                    Picker("Double tap", selection: $trackpadSnapDoubleTap) {
                        Text("Unsnap or Center").tag(SwishSnap.DoubleTap.restoreOrCenter.rawValue)
                        Text("Center").tag(SwishSnap.DoubleTap.center.rawValue)
                        Text("Off").tag(SwishSnap.DoubleTap.off.rawValue)
                    }
                    .pickerStyle(.menu)
                }
                .help("Double tap two fingers on a title bar: put a window AOM snapped back where it was, or center it. With ⌥ Option it hides the app, with ⇧ Shift every other app.")
                AOMSettingRow("Pinch gestures", detail: "Pinch to close, quit or go full screen",
                              help: "Pinch in on a title bar to close the window, twice to quit the app (it may ask to save). Pinch out to enter or leave full screen; with two displays, pinch out twice or hold ⌘ for full screen on the other display.") {
                    Toggle("Pinch to close, quit or go full screen", isOn: $trackpadSnapPinch)
                }
                .help("Pinch in on a title bar to close the window, twice to quit the app (it may ask to save). Pinch out to enter or leave full screen; with two displays, pinch out twice or hold ⌘ for full screen on the other display.")
                AOMSettingRow("Tap and hold gestures", detail: "Tap and hold, then swipe",
                              help: "Rest two fingers on a title bar for half a second, then swipe: up for full screen, down to minimize (also in full screen), left or right to move the window to the next Space.") {
                    Toggle("Tap and hold, then swipe", isOn: $trackpadSnapHold)
                }
                .help("Rest two fingers on a title bar for half a second, then swipe: up for full screen, down to minimize (also in full screen), left or right to move the window to the next Space.")
                AOMSettingRow("Modifier gestures", detail: "⌥, ⇧ and ⌘ change what a gesture does",
                              help: "⌥ Option: swipe sideways to move the window a Space, down to close it (rest first, or swipe down twice, to quit the app). ⌥ or ⇧ Shift double tap hides the app or the other apps. ⌘ Command: swipe to move the window to the display in that direction.") {
                    Toggle("Modifier gestures", isOn: $trackpadSnapModifiers)
                }
                .help("⌥ Option: swipe sideways to move the window a Space, down to close it (rest first, or swipe down twice, to quit the app). ⌥ or ⇧ Shift double tap hides the app or the other apps. ⌘ Command: swipe to move the window to the display in that direction.")
            }
            .disabled(!trackpadSnapOn)
            .opacity(trackpadSnapOn ? 1 : 0.55)
            // Swish's cancel: rest the fingers without moving. Shared by the
            // title-bar snap and every menu-bar and Dock gesture.
            AOMSettingRow("Hold still to cancel",
                          help: "Rest two fingers without moving for this long to cancel a title-bar gesture (snap, display or Space move, pinch, tap and hold), a top-bar Space swipe, or a menu-bar or Dock gesture: the touch then does nothing until you lift. The snap preview fades just before it goes.") {
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
                .pickerStyle(.menu)
            }
            .help("Rest two fingers without moving for this long to cancel a title-bar gesture (snap, display or Space move, pinch, tap and hold), a top-bar Space swipe, or a menu-bar or Dock gesture: the touch then does nothing until you lift. The snap preview fades just before it goes.")
        }
    }

    // MARK: - Grid & layout

    private var gridHelp: String {
        "Grid 3 × 2 adds thirds and their upper and lower halves, 3 × 3 ninths (swipe toward an edge to grow a cell). Drag a snapped window by its title bar to get its old size back; resize one of two snapped windows and the other follows; snapped windows re-snap after a display change."
    }

    /// Where swipes and hotkeys put windows (3.3.2: Swish's grid, almost
    /// maximize, margin and Stage Manager offset).
    private var gridSection: some View {
        // Only the rows dim while title-bar snap is off; the section title
        // stays readable and the footer says why.
        AOMSection("Grid & layout", help: gridHelp,
                   footer: trackpadSnapOn ? nil : "Turn on Title-bar snap to use the grid.") {
            Group {
                AOMSettingRow("Grid",
                              help: "2 × 2: halves and quarters only, never a third. 3 × 2: a longer swipe or a swipe toward an edge reaches thirds and two thirds, and a third swiped up or down takes its upper or lower half. 3 × 3: a third swiped up or down becomes a ninth; swipe a ninth toward an edge it touches to grow it to two-ninths, then toward its other edge to four-ninths.") {
                    Picker("Grid", selection: trackpadSnapGrid) {
                        Text("2 × 2 · halves, quarters, no thirds").tag(SwishSnap.Grid.twoByTwo.rawValue)
                        Text("3 × 2 · thirds, sixths").tag(SwishSnap.Grid.threeByTwo.rawValue)
                        Text("3 × 3 · ninths").tag(SwishSnap.Grid.threeByThree.rawValue)
                    }
                    .pickerStyle(.menu)
                }
                .help("2 × 2: halves and quarters only, never a third. 3 × 2: a longer swipe or a swipe toward an edge reaches thirds and two thirds, and a third swiped up or down takes its upper or lower half. 3 × 3: a third swiped up or down becomes a ninth; swipe a ninth toward an edge it touches to grow it to two-ninths, then toward its other edge to four-ninths.")
                AOMSettingRow("Almost maximize",
                              help: "Swipe up to fill almost the whole screen, leaving a small gap all round; swipe up again to maximize.") {
                    Toggle("Almost maximize", isOn: $trackpadSnapAlmost)
                }
                .help("Swipe up to fill almost the whole screen, leaving a small gap all round; swipe up again to maximize.")
                AOMSettingRow("Margin", help: "The gap kept around every snapped window, in points.") {
                    pointSlider(value: $trackpadSnapMargin, range: TitleBarWindowSnap.marginRange, step: 1, label: "Margin")
                }
                .help("The gap kept around every snapped window, in points.")
                AOMSettingRow("Stage Manager offset",
                              help: "While Stage Manager is on, snapped windows leave this much room on the left for its strip of recent apps.") {
                    pointSlider(value: $stageManagerOffset, range: TitleBarWindowSnap.stageManagerOffsetRange, step: 10,
                                label: "Stage Manager offset")
                }
                .help("While Stage Manager is on, snapped windows leave this much room on the left for its strip of recent apps.")
            }
            .disabled(!trackpadSnapOn)
            .opacity(trackpadSnapOn ? 1 : 0.55)
        }
    }

    // MARK: - Keyboard

    private var keyboardSection: some View {
        AOMSection("Keyboard", footer: trackpadSnapOn ? nil : "Turn on Title-bar snap to use the keyboard shortcuts.") {
            AOMSettingRow("Keyboard shortcuts", detail: "⌃⌥ and a key swipes the front window",
                          help: "⌃⌥ and one of four keys acts like a swipe that way on the front window, chaining from where it is. A shortcut you bound to the same keys wins; paused, the keys go to the app.") {
                Picker("Keyboard shortcuts", selection: $trackpadSnapHotkeys) {
                    Text("Off").tag(SwishSnap.HotkeyScheme.off.rawValue)
                    Text("⌃⌥ Arrows").tag(SwishSnap.HotkeyScheme.arrows.rawValue)
                    Text("⌃⌥ WASD").tag(SwishSnap.HotkeyScheme.wasd.rawValue)
                    Text("⌃⌥ IJKL").tag(SwishSnap.HotkeyScheme.ijkl.rawValue)
                    Text("⌃⌥ HJKL").tag(SwishSnap.HotkeyScheme.hjkl.rawValue)
                }
                .pickerStyle(.menu)
            }
            .help("⌃⌥ and one of four keys acts like a swipe that way on the front window, chaining from where it is. A shortcut you bound to the same keys wins; paused, the keys go to the app.")
            .disabled(!trackpadSnapOn)
            .opacity(trackpadSnapOn ? 1 : 0.55)
        }
    }

    // MARK: - Dock & menu bar

    private var dockSection: some View {
        AOMSection("Dock & menu bar") {
            AOMSettingRow("Top-bar Space swipe", detail: "Two fingers on the menu bar switch Spaces") {
                Toggle("Top-bar Space swipe", isOn: $topBarSpaceSwipe)
            }
            .help("Two fingers on the menu bar switch Spaces")
            AOMSettingRow("Dock pinch to quit", detail: "Pinch in on a Dock icon to quit that app") {
                Toggle("Dock pinch to quit", isOn: $dockPinchQuit)
            }
            .help("Pinch in on a Dock icon to quit that app")
            AOMSettingRow("Dock gestures",
                          help: "Two fingers on a Dock icon: tap and hold to activate the app, swipe sideways through its windows, down to minimize, up to unminimize (⇧ all), double tap to hide (⇧ the others), pinch out for ⌘N. With Tap to click on, a two-finger tap is also a right-click, so the Dock menu may open.") {
                Toggle("Dock gestures", isOn: $dockGestures)
            }
            .help("Two fingers on a Dock icon: tap and hold to activate the app, swipe sideways through its windows, down to minimize, up to unminimize (⇧ all), double tap to hide (⇧ the others), pinch out for ⌘N. With Tap to click on, a two-finger tap is also a right-click, so the Dock menu may open.")
            AOMSettingRow("Menu-bar gestures",
                          help: "Two fingers on the menu bar: tap and hold, then swipe for the previous or next app, or lift for the window switcher; double tap to unsnap (⇧ every display); swipe down to minimize all, up to bring them back (twice or ⇧ every display); ⌘ swipe moves snapped windows to the next display.") {
                Toggle("Menu-bar gestures", isOn: $menuBarGestures)
            }
            .help("Two fingers on the menu bar: tap and hold, then swipe for the previous or next app, or lift for the window switcher; double tap to unsnap (⇧ every display); swipe down to minimize all, up to bring them back (twice or ⇧ every display); ⌘ swipe moves snapped windows to the next display.")
        }
    }

    // MARK: - Advanced

    /// What happens around a snap (3.3.2: the preview animation, drag to
    /// unsnap, resizing neighbours and re-snapping).
    private var advancedSection: some View {
        AOMSection(footer: showsAdvanced && !trackpadSnapOn ? "These apply to title-bar snap, which is off." : nil) {
            AOMDisclosureRows("Advanced", detail: "Preview, focus, unsnap and re-snap", isExpanded: $showsAdvanced) {
                Group {
                    AOMSettingRow("Show preview",
                                  help: "The translucent frame for a snap and the name of any other action, while your fingers are down") {
                        Toggle("Show the snap preview while swiping", isOn: $trackpadSnapPreview)
                    }
                    .help("The translucent frame for a snap and the name of any other action, while your fingers are down")
                    AOMSettingRow("Preview animation",
                                  help: "How quickly the preview appears, moves and fades. Off shows and hides it at once; Reduce Motion always keeps it from sliding.") {
                        Picker("Preview animation", selection: $trackpadSnapAnimation) {
                            Text("Fast").tag(SwishSnap.AnimationSpeed.fast.rawValue)
                            Text("Normal").tag(SwishSnap.AnimationSpeed.normal.rawValue)
                            Text("Off").tag(SwishSnap.AnimationSpeed.off.rawValue)
                        }
                        .pickerStyle(.menu)
                    }
                    .help("How quickly the preview appears, moves and fades. Off shows and hides it at once; Reduce Motion always keeps it from sliding.")
                    AOMSettingRow("Bring window forward") {
                        Toggle("Bring window forward after snapping", isOn: $trackpadSnapActivate)
                    }
                    AOMSettingRow("Keep pointer on title bar") {
                        Toggle("Keep pointer on the title bar after snapping", isOn: $trackpadSnapKeepPointer)
                    }
                    AOMSettingRow("Drag to unsnap",
                                  help: "Drag a window AOM snapped by its title bar and it gets back its size from before the snap, under the pointer.") {
                        Toggle("Drag to unsnap", isOn: $trackpadSnapDragUnsnap)
                    }
                    .help("Drag a window AOM snapped by its title bar and it gets back its size from before the snap, under the pointer.")
                    AOMSettingRow("Resize neighbours together",
                                  help: "Resize a snapped window along an edge it shares with another snapped window, and when you let go that window follows the edge.") {
                        Toggle("Resize neighbours together", isOn: $trackpadSnapResizeAdjacent)
                    }
                    .help("Resize a snapped window along an edge it shares with another snapped window, and when you let go that window follows the edge.")
                    AOMSettingRow("Re-snap after display changes",
                                  help: "When a display is connected, disconnected or rearranged, windows still where AOM snapped them take their place again on the display they end up on.") {
                        Toggle("Re-snap after display changes", isOn: $trackpadSnapResnap)
                    }
                    .help("When a display is connected, disconnected or rearranged, windows still where AOM snapped them take their place again on the display they end up on.")
                }
                .disabled(!trackpadSnapOn)
                .opacity(trackpadSnapOn ? 1 : 0.55)
            }
        }
    }

    // MARK: - Readiness

    /// Status shown passively next to each prerequisite, with a shape as well
    /// as a colour, and a direct route to the setting that fixes it.
    private var readinessSection: some View {
        AOMSection("Readiness", detail: readiness.allSatisfy(\.ready) ? "Ready" : nil) {
            ForEach(readiness) { item in
                HStack(alignment: .center, spacing: AOMSpace.x2) {
                    Image(systemName: item.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(item.ready ? AOMColor.success : AOMColor.warning)
                        .frame(width: AOMIcon.row)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(AOMFont.body).foregroundStyle(AOMColor.text)
                        Text(item.detail)
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.title), \(item.ready ? "ready" : "needs attention"). \(item.detail)")
                    Spacer(minLength: AOMSpace.x2)
                    if let fix = item.fix {
                        Button("Open…") { TrackpadReadiness.open(fix) }
                            .buttonStyle(.bordered)
                            .help("Open the System Settings pane that fixes this")
                            .accessibilityLabel("Open settings for \(item.title)")
                    }
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .frame(minHeight: AOMSize.rowDetail)
                .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
            }
        }
    }

    // MARK: - Drag to Snap

    private var dragSection: some View {
        let on = appState.currentPreset.snappingEnabled
        return AOMSection("Drag to Snap", detail: on ? "On" : "Off",
                          footer: on ? "Drag a window to a screen edge, corner or snap zone and it fills that part of the screen."
                                     : "Turn on Drag to Snap at the top of the page to place windows by dragging them to an edge, corner or zone.") {
            Group {
                AOMSettingRow("Zones") {
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
                }
                AOMSettingRow("Require ⌥ Option") {
                    Toggle("Hold ⌥ Option while dragging", isOn: Binding(
                        get: { requiresOption },
                        set: { updateBehavior(requiresOption: $0, showsPreview: showsPreview) }
                    ))
                }
                AOMSettingRow("Show snap preview") {
                    Toggle("Show snap preview", isOn: Binding(
                        get: { showsPreview },
                        set: { updateBehavior(requiresOption: requiresOption, showsPreview: $0) }
                    ))
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.55)
        }
    }

    // MARK: - Tile the front window

    /// A miniature of the screen above the layout gallery: the layout under
    /// the pointer fills its region, so a layout is seen before it is used
    /// (Loop, Moom, Swish). Clicking a layout moves the front window.
    private func gallerySection(compact: Bool) -> some View {
        AOMSection("Tile the front window",
                   help: "Point at a layout to preview it, click to move the frontmost window there right away.",
                   padding: AOMSpace.cardPadding) {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                layoutPreview
                    .frame(height: compact ? 104 : 140)
                Grid(alignment: .leading, horizontalSpacing: AOMSpace.x1, verticalSpacing: AOMSpace.x1) {
                    ForEach(layoutGroups) { group in
                        GridRow {
                            Text(group.title)
                                .font(AOMFont.caption.weight(.medium))
                                .foregroundStyle(AOMColor.textSecondary)
                                .lineLimit(1)
                                .frame(width: compact ? 64 : 80, alignment: .leading)
                            ForEach(0..<4, id: \.self) { index in
                                if index < group.layouts.count {
                                    let entry = group.layouts[index]
                                    SnapLayoutChip(
                                        layout: entry.layout,
                                        title: entry.label,
                                        compact: compact,
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
    }

    private var layoutPreview: some View {
        let layout = hoveredLayout ?? .leftHalf
        return GeometryReader { geometry in
            let size = geometry.size
            let screen = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
            let inset: CGFloat = AOMSpace.x2
            let bar: CGFloat = AOMSpace.x2
            let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2 - bar)
            let region = AOMTilingGeometry.rect(for: layout, in: inner).insetBy(dx: 3, dy: 3)
            ZStack(alignment: .topLeading) {
                screen.fill(AOMColor.sunken)
                // The menu bar strip, so the miniature reads as a screen.
                UnevenRoundedRectangle(topLeadingRadius: AOMRadius.well, topTrailingRadius: AOMRadius.well, style: .continuous)
                    .fill(AOMColor.track)
                    .frame(height: bar)
                RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                    .fill(Color.accentColor.opacity(hoveredLayout == nil ? 0.10 : 0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(hoveredLayout == nil ? 0.30 : 0.6), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: layout == .nextDisplay ? "display.2" : "macwindow")
                            .font(AOMFont.title.weight(.light))
                            .foregroundStyle(Color.accentColor.opacity(hoveredLayout == nil ? 0.5 : 1))
                    }
                    .frame(width: max(0, region.width), height: max(0, region.height))
                    .offset(x: inset + region.minX, y: inset + bar + region.minY)
                    .animation(AOMMotion.panel, value: hoveredLayout)
                Text(hoveredLayout.map { $0 == .nextDisplay ? "Moves to the next display" : "Click to apply · \($0.rawValue)" }
                     ?? "Point at a layout to see it")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x0_5)
                    .background(AOMColor.surface.opacity(0.9), in: Capsule())
                    .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                    .padding(.trailing, AOMSpace.x2)
                    .padding(.bottom, AOMSpace.x2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hoveredLayout.map { "Preview: \($0.rawValue)" } ?? "Layout preview")
    }

    // MARK: - Zones & layouts

    private var zonesSection: some View {
        AOMSection("Zones & layouts", detail: "\(appState.effectiveSnapZones.count) saved") {
            navigationRow("Edit Snap Zones", detail: "Draw custom zones and targets",
                          symbol: "rectangle.split.3x3") { showingSnapZones = true }
            navigationRow("Display Profiles", detail: appState.activeSnapProfile?.name ?? "Per-monitor layouts",
                          symbol: "display.2") { showingProfiles = true }
            navigationRow("Saved Windows", detail: "Window layouts and undo",
                          symbol: "macwindow.on.rectangle") { showingWindowLayouts = true }
        }
    }

    private func navigationRow(_ title: String, detail: String, symbol: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                    Text(detail).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                }
                Spacer(minLength: AOMSpace.x2)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(AOMColor.textTertiary)
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(minHeight: AOMSize.rowDetail)
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMRowButtonStyle(radius: 0))
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .accessibilityLabel("\(title), \(detail)")
    }

    // MARK: - Presets

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

    private func pointSlider(value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                             label: String) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Slider(value: value, in: range, step: step)
                .frame(width: 120)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Text("\(Int(value.wrappedValue.rounded())) pt")
                .font(AOMFont.caption.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Helpers

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

    private func updateBehavior(requiresOption: Bool, showsPreview: Bool) {
        appState.updateSnapSettings(zones: appState.effectiveSnapZones,
                                    enabled: appState.currentPreset.snappingEnabled,
                                    requiresOption: requiresOption, showsPreview: showsPreview,
                                    profileID: appState.activeSnapProfile?.id)
    }

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

/// One layout in the gallery: its miniature and a short label (diagram only
/// in the narrow side column; the name stays in help and VoiceOver). Pointing
/// at it previews the layout, clicking applies it.
private struct SnapLayoutChip: View {
    let layout: CustomSnapZone.Layout
    let title: String
    var compact = false
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExecute: () -> Void

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: AOMSpace.x2) {
                AOMLayoutDiagram(layout: layout, highlighted: isHovered)
                    .frame(width: compact ? 40 : 34)
                if !compact {
                    Text(title)
                        .font(AOMFont.caption.weight(.medium))
                        .foregroundStyle(isHovered ? Color.accentColor : AOMColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? AOMSpace.x1 : AOMSpace.x2)
            .frame(maxWidth: .infinity, minHeight: compact ? 32 : 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.well))
        .onHover { onHover($0) }
        .help("Move the front window: \(layout.rawValue)")
        .accessibilityLabel("Tile front window: \(layout.rawValue)")
    }
}
