import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
protocol WindowPinCaptureStream: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws
}
extension SCStream: WindowPinCaptureStream {}

/// One serial capture lifecycle per pin. Changes during start/stop are reconciled
/// after the in-flight operation, so a late start cannot revive a removed pin.
@MainActor
final class PinnedWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Configuration: Equatable {
        let width: Int
        let height: Int
        let fps: Int
    }
    let videoLayer = AVSampleBufferDisplayLayer()
    private let makeStream: (SCStreamConfiguration, PinnedWindowCapture) throws -> any WindowPinCaptureStream
    private var stream: (any WindowPinCaptureStream)?
    private var applied: Configuration?
    private(set) var desired: Configuration?
    private var worker: Task<Void, Never>?
    private(set) var isClosed = false
    private(set) var hasFrame = false
    private(set) var failure: Error?
    var onFrame: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(window: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        makeStream = { configuration, owner in
            let stream = SCStream(filter: filter, configuration: configuration, delegate: owner)
            try stream.addStreamOutput(owner, type: .screen, sampleHandlerQueue: .main)
            return stream
        }
        super.init()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.clear.cgColor
    }

    init(makeStream: @escaping (SCStreamConfiguration, PinnedWindowCapture) throws -> any WindowPinCaptureStream) {
        self.makeStream = makeStream
        super.init()
    }

    func waitUntilSettled() async { await worker?.value }

    func request(_ configuration: Configuration?) {
        guard !isClosed else { return }
        guard desired != configuration else { return }
        desired = configuration
        if configuration == nil { hasFrame = false }
        reconcile()
    }

    func waitForStart() async throws {
        await worker?.value
        if let failure { throw failure }
        guard !isClosed, stream != nil else { throw CancellationError() }
    }

    func close() {
        isClosed = true
        desired = nil
        hasFrame = false
        onFrame = nil
        onFailure = nil
        videoLayer.flushAndRemoveImage()
        reconcile()
    }

    private func reconcile() {
        guard worker == nil else { return }
        worker = Task { [self] in
            defer { worker = nil }
            while true {
                guard let wanted = desired, !isClosed else {
                    guard let old = stream else { return }
                    stream = nil
                    applied = nil
                    hasFrame = false
                    videoLayer.flushAndRemoveImage()
                    // Never start a replacement while the old stream is stopping.
                    try? await old.stopCapture()
                    continue
                }
                if stream == nil {
                    do {
                        let next = try makeStream(makeConfiguration(wanted), self)
                        stream = next
                        try await next.startCapture()
                        applied = wanted
                    } catch {
                        let failed = stream
                        stream = nil; applied = nil
                        try? await failed?.stopCapture()
                        if !isClosed, desired != nil { fail(error) }
                        return
                    }
                } else if applied != wanted, let current = stream {
                    do {
                        try await current.updateConfiguration(makeConfiguration(wanted))
                        applied = wanted
                    } catch {
                        if !isClosed, desired != nil { fail(error) }
                        // Drain the failed stream through the same lifecycle.
                        desired = nil
                    }
                } else { return }
            }
        }
    }

    private func makeConfiguration(_ value: Configuration) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = value.width
        configuration.height = value.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(value.fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private func fail(_ error: Error) {
        failure = error
        hasFrame = false
        onFailure?(error)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        // The stream explicitly delivers on .main; no unbounded Task per frame.
        MainActor.assumeIsolated {
            guard self.stream === stream, desired != nil, !isClosed else { return }
            if videoLayer.status == .failed { videoLayer.flush() }
            guard videoLayer.isReadyForMoreMediaData else { return }
            videoLayer.enqueue(sampleBuffer)
            if !hasFrame { hasFrame = true; onFrame?() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, !self.isClosed else { return }
            self.stream = nil
            self.applied = nil
            self.desired = nil
            self.fail(error)
        }
    }
}

@MainActor
final class LivePinnedWindow: ObservableObject, Identifiable {
    let id: CGWindowID
    let target: WindowManager.Target
    let title: String
    let appName: String
    let bundleID: String
    let capture: PinnedWindowCapture
    let panel: NSPanel
    let controls: NSPanel
    @Published var isPaused = false
    @Published var opacity = 1.0
    private(set) var frame: CGRect
    private(set) var parkedFrame: CGRect?
    private var restoreFrame: CGRect?
    private(set) var isClosed = false
    var wasMouseInside = false
    var overlayWanted = true

    init(window: SCWindow, target: WindowManager.Target) {
        id = window.windowID
        self.target = target
        title = window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Window")
        appName = window.owningApplication?.applicationName ?? "Application"
        bundleID = window.owningApplication?.bundleIdentifier ?? ""
        frame = WindowPinningGeometry.appKitFrame(window.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        wasMouseInside = frame.contains(NSEvent.mouseLocation)
        capture = PinnedWindowCapture(window: window)
        panel = LivePinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls = LivePinPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [panel, controls] {
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.animationBehavior = .none
            window.applyCaptureVisibilityPreference()
        }
        panel.title = "Pinned: \(title)"
        controls.title = "Pin Controls: \(title)"
        panel.hasShadow = true
        controls.hasShadow = false
        let content = LivePinContentView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.addSublayer(capture.videoLayer)
        content.videoLayer = capture.videoLayer
        content.onClick = { [weak self] count in
            guard let self else { return }
            let activation = WindowPinningService.shared.options.activation
            if activation != .doubleClick || count >= 2 { WindowPinningService.shared.activate(self) }
        }
        panel.contentView = content
        let button = NSButton(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned window controls")!, target: nil, action: nil)
        button.bezelStyle = .circular
        button.isBordered = true
        button.contentTintColor = .controlAccentColor
        button.toolTip = "Pause, change opacity, unpin or close \(title)"
        let handler = PinControlHandler(pin: self)
        button.target = handler
        button.action = #selector(PinControlHandler.openMenu(_:))
        content.controlHandler = handler
        controls.contentView = button
        capture.onFrame = { [weak self] in self?.showIfReady() }
    }

    func update(frame: CGRect, options: WindowPinningOptions, visible: Bool, interacting: Bool, ducked: Bool) {
        guard !isClosed else { return }
        self.frame = frame
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        controls.setFrame(WindowPinningGeometry.controls(in: frame, corner: options.corner), display: false)
        panel.alphaValue = min(1, max(0.2, opacity))
        panel.contentView?.layer?.borderWidth = options.translucentBorder && opacity < 1 ? 1 : 0
        panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
        overlayWanted = visible && !isPaused && !interacting && !ducked
        if visible && !ducked { controls.orderFrontRegardless() } else { controls.orderOut(nil) }
        if overlayWanted {
            let screen = NSScreen.screens.max { a, b in
                let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
                return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
            }
            let size = WindowPinningGeometry.pixelSize(frame.size, scale: screen?.backingScaleFactor ?? 1)
            capture.request(.init(width: Int(size.width), height: Int(size.height),
                                  fps: options.frameRate(displayRate: screen?.maximumFramesPerSecond ?? 60)))
            showIfReady()
        } else {
            panel.orderOut(nil)
            capture.request(nil)
        }
    }

    private func showIfReady() {
        guard !isClosed, overlayWanted, capture.hasFrame else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        controls.order(.above, relativeTo: panel.windowNumber)
    }

    func parkSource(defaults: UserDefaults) -> Bool {
        if parkedFrame != nil { return true }
        guard let original = WindowManager.shared.frame(of: target),
              WindowPinRestoration.remember(self, frame: original, defaults: defaults) else { return false }
        restoreFrame = original
        let desktop = WindowManager.shared.screens().map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let parked = WindowPinningGeometry.parkTarget(original: original, desktop: desktop)
        guard WindowPinRestoration.move(target, to: parked), let actual = WindowManager.shared.frame(of: target),
              !actual.intersects(original),
              WindowPinRestoration.recordParkedFrame(actual, id: id, defaults: defaults) else {
            _ = restoreSource(defaults: defaults)
            return false
        }
        parkedFrame = actual
        return true
    }

    @discardableResult
    func restoreSource(defaults: UserDefaults) -> Bool {
        guard let restoreFrame else { return true }
        guard WindowPinRestoration.restore(target, frame: restoreFrame) else { return false }
        self.restoreFrame = nil
        parkedFrame = nil
        WindowPinRestoration.forget(id, defaults: defaults)
        return true
    }

    /// A source app (or the user via another tool) moved the parked window. Its
    /// new placement takes precedence over the old restoration frame.
    func sourceMoved(defaults: UserDefaults) {
        restoreFrame = nil
        parkedFrame = nil
        WindowPinRestoration.forget(id, defaults: defaults)
    }

    func close() {
        isClosed = true
        panel.orderOut(nil)
        controls.orderOut(nil)
        capture.close()
        panel.close()
        controls.close()
    }
}

private final class LivePinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LivePinContentView: NSView {
    var videoLayer: AVSampleBufferDisplayLayer?
    var onClick: ((Int) -> Void)?
    var controlHandler: PinControlHandler?
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }
}

@MainActor
private final class PinControlHandler: NSObject {
    weak var pin: LivePinnedWindow?
    init(pin: LivePinnedWindow) { self.pin = pin }
    @objc func openMenu(_ sender: NSButton) {
        guard let pin else { return }
        let menu = WindowPinningService.shared.menu(for: pin)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}
