import AppKit
import SwiftUI

/// Session controls never intercept the captured app's scrolling. Both windows
/// are explicitly excluded from every frame, even when no free screen edge exists.
@MainActor
final class ScrollingCaptureSession: ObservableObject {
    @Published var automatic = false
    @Published var paused = false
    @Published var direction: ScrollingCaptureService.Direction
    @Published private(set) var preview: NSImage?
    @Published private(set) var frameCount = 0
    @Published private(set) var pixelSize = CGSize.zero
    @Published private(set) var message = "Scroll slowly in one direction, or enable Auto Scroll."
    private let area: CGRect
    private let maxFrames: Int
    private var panel: ScrollSessionPanel?
    private var border: NSPanel?
    private var finished = false
    private var cancelled = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var axis: ScrollingCaptureService.Direction?

    init(area: CGRect, direction: ScrollingCaptureService.Direction, maxFrames: Int) {
        self.area = area; self.direction = direction; self.maxFrames = maxFrames
    }

    func finish() { finished = true }
    func cancel() { cancelled = true; finished = true }

    func run() async throws -> CaptureResult {
        present()
        defer { dismiss() }
        let controlWindows: [NSWindow?] = [panel, border]
        let ids = Set(controlWindows.compactMap { $0 }.map { CGWindowID($0.windowNumber) })
        let first = try await ScreenCaptureService.shared.captureArea(area, showsCursor: false,
                                                                     excludingWindowIDs: ids)
        var previous = first.image
        var accumulated = first.image
        update(accumulated)
        frameCount = 1
        var failedFrames = 0
        while !finished {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
            guard !finished, !paused else { continue }
            if automatic {
                _ = try await ScrollingCaptureService.shared.scrollOnce(at: area, direction: direction)
                try await Task.sleep(nanoseconds: 240_000_000)
            }
            guard !finished, !paused else { continue }
            let next = try await ScreenCaptureService.shared.captureArea(area, showsCursor: false,
                                                                        excludingWindowIDs: ids)
            guard !finished, !paused else { continue }
            if let joined = ScrollingCaptureService.appendFrame(next.image, after: previous,
                                                                 to: accumulated, direction: direction) {
                accumulated = joined.image
                previous = next.image
                axis = direction
                frameCount += 1
                failedFrames = 0
                message = automatic ? "Auto Scroll is capturing. Pause or finish at any time." :
                    "Captured. Keep scrolling slowly in the same direction."
                update(accumulated)
                if frameCount >= maxFrames {
                    paused = true
                    message = "Frame limit reached. Finish to save this capture."
                }
            } else {
                failedFrames += 1
                if automatic && failedFrames >= 3 {
                    paused = true
                    message = "No matching movement or image limit reached. Finish, or resume after adjusting the content."
                } else if !automatic && failedFrames >= 8 {
                    message = "Waiting for matching movement. Scroll slowly down or right; avoid reversing direction."
                }
            }
        }
        if cancelled { throw CaptureError.cancelled }
        return CaptureResult(image: accumulated, globalRect: area, scale: first.scale, kind: .scrolling)
    }

    var canChangeDirection: Bool { axis == nil }

    private func update(_ image: CGImage) {
        pixelSize = CGSize(width: image.width, height: image.height)
        // Keep a bounded preview instead of handing the full stitched bitmap to
        // SwiftUI each frame; the full-resolution accumulator remains untouched.
        let scale = min(1, 1000 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        if let context = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let reduced = context.makeImage() {
                preview = NSImage(cgImage: reduced, size: CGSize(width: width, height: height))
            }
        }
    }

    private func present() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitArea = CGRect(x: area.minX, y: primaryHeight - area.maxY,
                               width: area.width, height: area.height)
        let screen = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(appKitArea), b = rhs.frame.intersection(appKitArea)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? appKitArea
        let width: CGFloat = min(350, visible.width - 24)
        let height: CGFloat = min(490, visible.height - 24)
        var x = appKitArea.maxX + 12
        if x + width > visible.maxX { x = max(visible.minX + 12, appKitArea.minX - width - 12) }
        let y = min(max(appKitArea.maxY - height, visible.minY + 12), visible.maxY - height - 12)
        let panel = ScrollSessionPanel(contentRect: CGRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollSessionView(session: self))
        panel.orderFrontRegardless()
        self.panel = panel

        let border = NSPanel(contentRect: appKitArea.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        border.level = .floating; border.isOpaque = false; border.backgroundColor = .clear
        border.hasShadow = false; border.ignoresMouseEvents = true; border.hidesOnDeactivate = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView: Rectangle().stroke(Color.accentColor, lineWidth: 2).padding(1))
        border.orderFrontRegardless()
        self.border = border
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil
            case 36: self.finish(); return nil
            case 49: self.paused.toggle(); return nil
            default: return event
            }
        }
    }

    private func dismiss() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        panel?.orderOut(nil); border?.orderOut(nil)
        panel = nil; border = nil
    }
}

private final class ScrollSessionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ScrollSessionView: View {
    @ObservedObject var session: ScrollingCaptureSession
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Scrolling Capture", systemImage: "scroll").font(.headline)
                Spacer()
                Button(action: session.cancel) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack {
                Picker("Direction", selection: $session.direction) {
                    Text("Vertical").tag(ScrollingCaptureService.Direction.vertical)
                    Text("Horizontal").tag(ScrollingCaptureService.Direction.horizontal)
                }.pickerStyle(.segmented).disabled(!session.canChangeDirection)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.12))
                if let preview = session.preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(8)
                } else { ProgressView() }
            }.frame(maxHeight: .infinity)
            Text("\(Int(session.pixelSize.width)) × \(Int(session.pixelSize.height)) px · \(session.frameCount) frames")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(session.message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Auto Scroll", isOn: $session.automatic).toggleStyle(.switch)
            HStack {
                Button("Cancel", action: session.cancel)
                Spacer()
                Button(session.paused ? "Resume" : "Pause") { session.paused.toggle() }
                Button("Finish", action: session.finish).buttonStyle(.borderedProminent)
            }.controlSize(.regular)
        }.padding(16).aomFloatingSurface(.bar, radius: AOMRadius.bar)
    }
}
