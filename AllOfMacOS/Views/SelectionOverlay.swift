import AppKit
import SwiftUI

extension NSScreen {
    /// The `CGDirectDisplayID` backing this screen.
    ///
    /// AppKit only exposes it inside `deviceDescription`, and the key is not a
    /// public constant, so the lookup lives here rather than being repeated.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// The dimmed full-screen overlay the user drags a capture rectangle on.
///
/// It covers every display at once with one window per screen, so a selection
/// can start on one display and the crosshair still reads correctly. A single
/// window spanning the union of all screens would be simpler, but macOS will not
/// let a window draw across displays with different backing scales without
/// resampling, which makes the dim layer visibly soft on one of them.
@MainActor
final class SelectionOverlayController {
    private(set) static var activeController: SelectionOverlayController?
    static var isActive: Bool { activeController != nil }
    static func cancelActive() {
        activeController?.finish(nil)
    }

    private var windows: [SelectionWindow] = []
    private let state = SelectionState()
    private var localKeyMonitor: Any?
    var selectedMode: IntegratedCaptureMode { state.captureMode }
    var selectedWindowID: CGWindowID? { state.hoveredWindow?.windowID }
    private let completion: (CGRect?) -> Void
    private var didFinish = false
    private var globalKeyMonitor: Any?

    init(integrated: Bool = false, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        state.integrated = integrated
    }

    func present() {
        Self.activeController = self
        let screens = NSScreen.screens
        guard !screens.isEmpty else { finish(nil); return }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated {
                    self?.finish(nil)
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finish(nil); return nil }
            if event.keyCode == 49, !self.state.isDragging {
                self.state.mode = self.state.mode == .area ? .window : .area
                self.state.captureMode = self.state.mode == .window ? .window : .area
                return nil
            }
            return event
        }

        // A frozen backdrop is captured before the dimming goes up, so windows
        // that animate underneath the selection cannot move mid-drag.
        let frozen = CaptureSettings.freezeScreen ? Self.freezeBackdrops(for: screens) : [:]

        for (index, screen) in screens.enumerated() {
            let window = SelectionWindow(screen: screen, frozen: frozen[screen.displayID], state: state)
            window.onCommit = { [weak self] rect in self?.finish(rect) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            windows.append(window)
            window.present(initiallyActive: index == 0)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(_ rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor); localKeyMonitor = nil }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
        // Tear the overlays down before handing the rect back: the capture that
        // follows must not photograph the selection UI itself.
        let toClose = windows
        windows = []
        for window in toClose { window.orderOut(nil) }
        if rect == nil {
            // Cancellation does not start a capture. Notify immediately instead
            // of leaving Escape waiting on an already-busy main queue.
            completion(nil)
        } else {
            // A successful capture requires one runloop turn for the selection
            // windows to disappear before ScreenCaptureKit reads any pixels.
            DispatchQueue.main.async { [completion] in
                completion(rect)
            }
        }
    }

    /// A still image of each display, used as the overlay's backdrop.
    ///
    /// This runs before the dim windows exist, so the image contains the desktop
    /// and not the overlay. A failure here degrades to a live backdrop rather
    /// than blocking the capture.
    private static func freezeBackdrops(for screens: [NSScreen]) -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in screens {
            guard let image = CGDisplayCreateImage(screen.displayID) else { continue }
            result[screen.displayID] = image
        }
        return result
    }
}

/// One display's worth of selection overlay.
private final class SelectionWindow: NSPanel {
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// Named `hostScreen` rather than `screen` because `NSPanel` already has a
    /// `screen` property that means something else.
    private let hostScreen: NSScreen
    private let state: SelectionState

    init(screen: NSScreen, frozen: CGImage?, state: SelectionState) {
        self.state = state
        self.hostScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Presenting over a full-screen app or a game is the common case for a
        // screenshot, so this must not be suppressed by app activation rules.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        let view = SelectionView(state: state, screen: hostScreen, frozen: frozen,
                                 onCommit: { [weak self] rect in self?.onCommit?(rect) },
                                 onCancel: { [weak self] in self?.onCancel?() })
        contentView = NSHostingView(rootView: view)
    }

    // The overlay is a tool, not a document window: it must be able to take key
    // focus to receive Escape and arrow keys.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func present(initiallyActive: Bool) {
        setFrame(hostScreen.frame, display: true)
        orderFrontRegardless()
    }
}

enum IntegratedCaptureMode: String, CaseIterable {
    case area = "Area", window = "Window", fullscreen = "Screen", scrolling = "Scroll", recording = "Record", text = "Text"
    var icon: String {
        switch self {
        case .area: return "viewfinder"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .scrolling: return "scroll"
        case .recording: return "record.circle"
        case .text: return "text.viewfinder"
        }
    }
}

/// CleanShot X style selection modes: drag rectangle area or press Space to select a window.
enum SelectionOverlayMode {
    case area
    case window
}

struct WindowCandidate: Equatable {
    let windowID: CGWindowID
    let sckRect: CGRect      // Global rect in ScreenCaptureKit coordinates
    let localRect: CGRect    // View-local rect on this screen
    let appName: String
    let title: String
}

/// Shared drag state for one overlay window.
private final class SelectionState: ObservableObject {
    @Published var captureMode: IntegratedCaptureMode = .area
    var integrated = false
    @Published var mode: SelectionOverlayMode = .area
    @Published var hoveredWindow: WindowCandidate?
    @Published var anchor: CGPoint?
    @Published var current: CGPoint?
    @Published var isDragging = false

    /// The rectangle the user has drawn so far, normalized so a drag in any
    /// direction produces a positive-size rect.
    var rect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }
}

/// Draws the dim layer, the live selection rectangle, its dimensions, and the
/// crosshair guides, plus CleanShot X-style window highlight when Space is pressed.
private struct SelectionView: View {
    @ObservedObject var state: SelectionState
    let screen: NSScreen
    let frozen: CGImage?
    let onCommit: (CGRect) -> Void
    let onCancel: () -> Void

    /// Tracks the pointer for the crosshair, magnifier, and window detection.
    @State private var pointer: CGPoint = .zero
    @State private var isMagnifying = false
    private var selectionRect: CGRect? { state.rect.map { localRect(for: $0) } }
    private var hoveredTarget: WindowCandidate? {
        guard let target = state.hoveredWindow else { return nil }
        return WindowCandidate(windowID: target.windowID, sckRect: target.sckRect, localRect: localRect(for: target.sckRect), appName: target.appName, title: target.title)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                backdrop(size: geometry.size)
                dimLayer(size: geometry.size)

                // CleanShot X: Window selection highlight when Space is pressed
                if state.mode == .window, let target = hoveredTarget {
                    windowHighlight(target: target)
                }

                // CleanShot X: Area drag selection
                if state.mode == .area, let rect = selectionRect, state.isDragging {
                    border(rect: rect)
                    dimensionLabel(rect: rect)
                }

                // Crosshairs & cursor UI
                if state.mode == .area && !state.isDragging {
                    crosshair(size: geometry.size)
                } else if state.mode == .window {
                    windowCursor(size: geometry.size)
                }

                if state.integrated { modeToolbar } else { instructionBadge }

                if isMagnifying, let rect = selectionRect, state.isDragging {
                    MagnifierView(frozen: frozen, pointer: pointer, rect: rect, screen: screen)
                        .position(magnifierPosition(in: geometry.size))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(state.mode == .area && state.captureMode != .fullscreen ? dragGesture : nil)
            .onTapGesture {
                if state.captureMode == .fullscreen {
                    onCommit(globalRect(for: CGRect(origin: .zero, size: screen.frame.size)))
                } else if state.mode == .window, let target = hoveredTarget {
                    onCommit(target.sckRect)
                }
            }
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    pointer = point
                    if state.mode == .window {
                        detectWindowUnderPointer(localPoint: point)
                    }
                }
            }
            .onChange(of: state.mode) { _, mode in
                let mouse = NSEvent.mouseLocation
                if mode == .window, screen.frame.contains(mouse) {
                    let point = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
                    detectWindowUnderPointer(localPoint: point)
                }
            }

        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func backdrop(size: CGSize) -> some View {
        if let frozen {
            Image(decorative: frozen, scale: screen.backingScaleFactor)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .ignoresSafeArea()
        }
    }

    private func dimLayer(size: CGSize) -> some View {
        Group {
            if state.mode == .area, let rect = selectionRect, state.isDragging {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            } else if state.mode == .window, let target = hoveredTarget {
                // Cut out the hovered window from the dimming layer
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRoundedRect(in: target.localRect, cornerSize: CGSize(width: 8, height: 8))
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
            } else {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - CleanShot X Window Selection UI

    @ViewBuilder
    private func windowHighlight(target: WindowCandidate) -> some View {
        ZStack {
            // Soft glowing accent tint inside the window
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: target.localRect.width, height: target.localRect.height)
                .position(x: target.localRect.midX, y: target.localRect.midY)

            // Prominent CleanShot-style border
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2.5)
                .frame(width: target.localRect.width, height: target.localRect.height)
                .position(x: target.localRect.midX, y: target.localRect.midY)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)

            // Window Information Pill (App Name, Window Title, Dimensions)
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(target.appName)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)

                if !target.title.isEmpty {
                    Text("•")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(target.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                }

                Text("\(Int(target.sckRect.width)) × \(Int(target.sckRect.height))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .position(
                x: target.localRect.midX,
                y: max(30, target.localRect.minY - 18)
            )
        }
        .allowsHitTesting(false)
    }

    private func windowCursor(size: CGSize) -> some View {
        ZStack {
            // CleanShot camera icon floating near the cursor
            HStack(spacing: 4) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("Click to capture")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)
            .position(x: min(pointer.x + 65, size.width - 70), y: min(pointer.y + 24, size.height - 20))
        }
        .allowsHitTesting(false)
    }

    private func border(rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)

            // Corner handles for CleanShot X feel
            ForEach([-1.0, 1.0], id: \.self) { hX in
                ForEach([-1.0, 1.0], id: \.self) { hY in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .shadow(color: Color.black.opacity(0.6), radius: 1)
                        .position(
                            x: rect.midX + hX * (rect.width / 2),
                            y: rect.midY + hY * (rect.height / 2)
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var instructionBadge: some View {
        HStack(spacing: 7) {
            if state.mode == .window {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Click to select window")
                    .font(.system(size: 12, weight: .bold))
                Text("•")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Space for area selection • Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Drag to capture area")
                    .font(.system(size: 12, weight: .bold))
                Text("•")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Space to select window • Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 3)
        .padding(.top, 24)
        .allowsHitTesting(false)
    }

    private func dimensionLabel(rect: CGRect) -> some View {
        let pixels = pixelSize(for: rect)
        return Text("\(Int(pixels.width)) × \(Int(pixels.height))")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            .position(labelPosition(for: rect))
            .allowsHitTesting(false)
    }

    private func crosshair(size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: pointer.x, y: 0))
                path.addLine(to: CGPoint(x: pointer.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: pointer.y))
                path.addLine(to: CGPoint(x: size.width, y: pointer.y))
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)

            // A small coordinate readout beside the cursor
            Text("\(Int((pointer.x * screen.backingScaleFactor).rounded())), \(Int((pointer.y * screen.backingScaleFactor).rounded()))")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .position(x: pointer.x + 52, y: pointer.y + 16)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if state.anchor == nil {
                    state.anchor = globalRect(for: CGRect(origin: value.startLocation, size: .zero)).origin
                    isMagnifying = NSEvent.modifierFlags.contains(.shift)
                }
                let mouse = NSEvent.mouseLocation
                state.current = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
                state.isDragging = true
                isMagnifying = NSEvent.modifierFlags.contains(.shift)
            }
            .onEnded { value in
                let committed = state.rect
                state.isDragging = false
                state.anchor = nil
                state.current = nil
                guard let rect = committed, rect.width >= 2, rect.height >= 2 else { return }
                onCommit(rect)
            }
    }

    private var modeToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(IntegratedCaptureMode.allCases, id: \.self) { mode in
                    Button {
                        state.captureMode = mode
                        state.mode = mode == .window ? .window : .area
                        state.anchor = nil; state.current = nil; state.isDragging = false
                        if mode == .window { detectWindowUnderPointer(localPoint: pointer) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon).font(.system(size: 18))
                            Text(mode.rawValue).font(.system(size: 11, weight: .medium))
                        }.frame(width: 62, height: 48)
                            .background(state.captureMode == mode ? Color.accentColor.opacity(0.85) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 30)
                Button(action: onCancel) { Image(systemName: "xmark").frame(width: 30, height: 48) }
                    .buttonStyle(.plain).help("Cancel (Esc)")
            }.padding(7).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Text(state.captureMode == .window ? "Click a window · Space for area · Esc to cancel" :
                 state.captureMode == .fullscreen ? "Click the display to capture · Esc to cancel" :
                 "Drag to select · Shift for magnifier · Esc to cancel")
                .font(.system(size: 11)).padding(6).background(.black.opacity(0.7), in: Capsule())
                .allowsHitTesting(false)
        }.foregroundStyle(.white).padding(.top, 24)
    }

    // MARK: - Window Detection (CleanShot X style)

    private func detectWindowUnderPointer(localPoint: CGPoint) {
        let globalPt = globalRect(for: CGRect(origin: localPoint, size: .zero)).origin
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            state.hoveredWindow = nil
            return
        }

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ownPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard rect.width >= 50, rect.height >= 50 else { continue }

            if rect.contains(globalPt) {
                let wid = (info[kCGWindowNumber as String] as? CGWindowID) ?? 0
                let appName = (info[kCGWindowOwnerName as String] as? String) ?? "Application"
                let title = (info[kCGWindowName as String] as? String) ?? ""
                let local = localRect(for: rect)

                state.hoveredWindow = WindowCandidate(
                    windowID: wid,
                    sckRect: rect,
                    localRect: local,
                    appName: appName,
                    title: title
                )
                return
            }
        }
        state.hoveredWindow = nil
    }

    private func localRect(for sck: CGRect) -> CGRect {
        let primaryScreen = NSScreen.screens.first ?? screen
        let primaryHeight = primaryScreen.frame.height
        let screenTopInSCK = primaryHeight - screen.frame.maxY
        let screenLeftInSCK = screen.frame.minX

        let localX = sck.minX - screenLeftInSCK
        let localY = sck.minY - screenTopInSCK

        return CGRect(x: localX, y: localY, width: sck.width, height: sck.height)
    }

    // MARK: - Geometry

    /// Converts a view-local rect to a global top-left-origin rect in points
    /// matching ScreenCaptureKit / SCDisplay coordinates.
    private func globalRect(for local: CGRect) -> CGRect {
        let primaryScreen = NSScreen.screens.first ?? screen
        let primaryHeight = primaryScreen.frame.height
        let screenTopInSCK = primaryHeight - screen.frame.maxY
        let screenLeftInSCK = screen.frame.minX

        let sckX = screenLeftInSCK + local.minX
        let sckY = screenTopInSCK + local.minY

        return CGRect(x: sckX, y: sckY, width: local.width, height: local.height)
    }

    /// Converts a local rect's size into device pixels.
    private func pixelSize(for rect: CGRect) -> CGSize {
        let global = globalRect(for: rect)
        let height = NSScreen.screens.first?.frame.height ?? 0
        let scale = NSScreen.screens.filter {
            CGRect(x: $0.frame.minX, y: height - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height).intersects(global)
        }.map(\.backingScaleFactor).max() ?? screen.backingScaleFactor
        return CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    private func labelPosition(for rect: CGRect) -> CGPoint {
        // Prefer just inside the bottom-left of the selection; flip above the
        // rect when it is too close to the bottom edge to fit.
        let below = rect.maxY + 16
        let y = below > screen.frame.height - 24 ? rect.minY - 16 : below
        return CGPoint(x: rect.minX + 46, y: y)
    }

    private func magnifierPosition(in size: CGSize) -> CGPoint {
        // Keep the loupe away from the edges it would otherwise hang off.
        let x = min(max(pointer.x + 90, 90), size.width - 90)
        let y = min(max(pointer.y - 90, 70), size.height - 70)
        return CGPoint(x: x, y: y)
    }
}

/// The pixel loupe shown while Shift is held, so a selection can be placed on an
/// exact edge.
private struct MagnifierView: View {
    let frozen: CGImage?
    let pointer: CGPoint
    let rect: CGRect
    let screen: NSScreen

    private let side: CGFloat = 128
    private let zoom: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let frozen {
                    Image(decorative: frozen, scale: screen.backingScaleFactor)
                        .resizable()
                        .frame(width: side * zoom, height: side * zoom)
                        .offset(x: offsetX, y: offsetY)
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Color.black.opacity(0.85)
                }
                // The crosshair marks the exact pixel the selection will snap to.
                Path { path in
                    path.move(to: CGPoint(x: side / 2, y: 0)); path.addLine(to: CGPoint(x: side / 2, y: side))
                    path.move(to: CGPoint(x: 0, y: side / 2)); path.addLine(to: CGPoint(x: side, y: side / 2))
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 0.5)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))

            HStack(spacing: 8) {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))").monospacedDigit()
                Text("\(Int(pixelOrigin.x)), \(Int(pixelOrigin.y))").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .offset(y: -4)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The loupe shows the region around the pointer, so the image is shifted so
    /// that the pointer lands at the centre of the clipped frame.
    private var offsetX: CGFloat {
        -(pointer.x * zoom) + side / 2
    }
    private var offsetY: CGFloat {
        -(pointer.y * zoom) + side / 2
    }

    private var pixelSize: CGSize {
        let scale = screen.backingScaleFactor
        return CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    private var pixelOrigin: CGPoint {
        let scale = screen.backingScaleFactor
        return CGPoint(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded())
    }
}
