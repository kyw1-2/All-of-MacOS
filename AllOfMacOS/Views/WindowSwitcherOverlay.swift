import AppKit
import SwiftUI
import ScreenCaptureKit

/// AltTab-style window switcher: a floating overlay lists the on-screen
/// windows of every other app with live thumbnails; arrows move, Return or a
/// click activates, Esc cancels. When the switcher was opened while a modifier
/// was held (the natural binding, e.g. ⌃Tab), releasing all modifiers
/// confirms the selection — the AltTab grammar.
@MainActor
final class WindowSwitcherController: NSObject, ObservableObject {
    static let shared = WindowSwitcherController()

    struct Item: Identifiable {
        let id: CGWindowID
        let title: String
        let appName: String
        let icon: NSImage?
        let axWindow: AXUIElement?
        let pid: pid_t
        var thumbnail: CGImage?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedIndex = 0
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var previousApp: NSRunningApplication?

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        guard panel == nil else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { await present() }
    }

    private func present() async {
        var candidates: [Item] = []
        var scWindows: [SCWindow] = []
        if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
            for sc in content.windows where sc.isActiveWindowCandidate {
                let app = sc.owningApplication
                let running = app.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
                let axWindow = WindowPinningService.shared.accessibilityTarget(for: sc)?.window
                candidates.append(Item(id: sc.windowID, title: sc.title ?? "",
                                       appName: app?.applicationName ?? "Unknown",
                                       icon: running?.icon, axWindow: axWindow,
                                       pid: app?.processID ?? 0, thumbnail: nil))
                scWindows.append(sc)
            }
        }
        // SCShareableContent already reports front-to-back.
        candidates = Array(candidates.prefix(12))
        guard !candidates.isEmpty else { return }
        items = candidates
        selectedIndex = 0

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 190),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.worksWhenModal = true
        panel.contentView = NSHostingView(rootView: WindowSwitcherView(controller: self))
        if let screen = NSScreen.main {
            let size = CGSize(width: 900, height: 190)
            let frame = NSRect(origin: screen.visibleFrame.origin,
                               size: size).offsetBy(dx: (screen.visibleFrame.width - size.width) / 2,
                                                    dy: (screen.visibleFrame.height - size.height) * 0.32)
            panel.setFrame(frame, display: false)
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        loadThumbnails(from: scWindows)
    }

    private func loadThumbnails(from windows: [SCWindow]) {
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        for item in items {
            guard let sc = byID[item.id] else { continue }
            Task { [weak self] in
                guard let image = try? await WindowSwitcherController.thumbnail(for: sc) else { return }
                await MainActor.run {
                    guard let index = self?.items.firstIndex(where: { $0.id == item.id }) else { return }
                    self?.items[index].thumbnail = image
                }
            }
        }
    }

    nonisolated private static func thumbnail(for window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.queueDepth = 1
        config.showsCursor = false
        config.captureResolution = .best
        let frame = window.frame
        config.width = Int(min(max(frame.width, 160), 480))
        config.height = Int(min(max(frame.height, 100), 300))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + items.count) % items.count
    }

    func confirm() { activateAndClose() }

    func cancel() {
        closePanel()
        previousApp?.activate(options: [])
    }

    private func activateAndClose() {
        let item = items[selectedIndex]
        closePanel()
        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [])
        if let ax = item.axWindow {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    private func closePanel() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        items = []
    }

    private func installMonitors() {
        let key = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isShowing else { return event }
            if event.type == .flagsChanged {
                // Releasing the held modifier confirms the selection.
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty { self.confirm() }
                return nil
            }
            switch event.keyCode {
            case 123: self.moveSelection(-1); return nil // left
            case 124: self.moveSelection(1); return nil // right
            case 36, 76: self.confirm(); return nil // return / enter
            case 53: self.cancel(); return nil // esc
            default: return event
            }
        }
        if let key { monitors.append(key) }
        // A click on a card activates it (handled in SwiftUI); clicks outside close.
        let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isShowing, event.window !== self.panel else { return event }
            self.cancel()
            return event
        }
        if let click { monitors.append(click) }
    }
}

private extension SCWindow {
    /// A normal, visible app window worth switching to.
    var isActiveWindowCandidate: Bool {
        guard let app = owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier else { return false }
        guard windowLayer == 0, frame.width > 120, frame.height > 80 else { return false }
        return true
    }
}

private extension NSRect {
    func centered(in bounds: NSRect, size: CGSize) -> NSRect {
        NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

private struct WindowSwitcherView: View {
    @ObservedObject var controller: WindowSwitcherController

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                WindowSwitcherCard(item: item, isSelected: index == controller.selectedIndex)
                    .onTapGesture { controller.confirm() }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 18, y: 6)
    }
}

private struct WindowSwitcherCard: View {
    let item: WindowSwitcherController.Item
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable().scaledToFit().padding(22)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 30)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 96)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 4) {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150)
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}
