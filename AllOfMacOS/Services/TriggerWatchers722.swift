import AppKit
import CoreAudio
import Vision

// 7.22 (DeepSeek 7.21 report §4.6): two trigger sources that let a Scene or
// any action list start by itself — "a call app took the microphone" and
// "this text is on screen" (Shortery / Keyboard Maestro-style conditions).

// MARK: - Microphone in use

/// Watches the default input device's "running somewhere" flag. It reports
/// changes only: the reading when the watcher starts is the baseline. When
/// the default input changes (AirPods connect) the listener moves with it.
final class MicrophoneActivityWatcher {
    private let onChange: (Bool) -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var runningBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?
    private var last: Bool?

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    private static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachToDefault() }
        var address = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            defaultBlock = block
        }
        attachToDefault()
    }

    func stop() {
        detach()
        if let defaultBlock {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultBlock)
        }
        defaultBlock = nil
        last = nil
    }

    deinit { stop() }

    static func defaultInputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// True while any process (including AOM) has the device's IO running.
    static func isRunning(_ device: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = runningAddress
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Whether the default microphone is in use right now (no listener).
    static var isMicrophoneInUse: Bool { defaultInputDevice().map(isRunning) ?? false }

    private func attachToDefault() {
        guard let next = Self.defaultInputDevice() else { detach(); return }
        if next != device {
            detach()
            device = next
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            var address = Self.runningAddress
            if AudioObjectAddPropertyListenerBlock(next, &address, .main, block) == noErr { runningBlock = block }
        }
        report()
    }

    private func detach() {
        if let runningBlock, device != kAudioObjectUnknown {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, runningBlock)
        }
        runningBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func report() {
        let now = device == kAudioObjectUnknown ? false : Self.isRunning(device)
        defer { last = now }
        guard let last, last != now else { return }
        onChange(now)
    }
}

// MARK: - Text on screen

/// Pure part of the screen-text trigger: normalising what to look for and
/// turning readings into "appeared" edges (absent → present). The first
/// reading is the baseline, so text already on screen when the trigger is
/// saved does not fire it.
struct ScreenTextWatchSet {
    let texts: Set<String>
    private var present: Set<String>?

    init(texts: Set<String>) { self.texts = texts }

    /// Case-, width- and diacritic-insensitive, whitespace collapsed.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The watched texts that are in `recognized` now and were not before.
    mutating func appeared(in recognized: String) -> [String] {
        let haystack = Self.normalized(recognized)
        let now = Set(texts.filter { haystack.contains($0) })
        defer { present = now }
        guard let present else { return [] }
        return now.subtracting(present).sorted()
    }

    /// The screen did not change: nothing appears or disappears.
    var hasBaseline: Bool { present != nil }
}

/// Captures the display under the pointer every `interval` seconds and runs
/// fast on-device text recognition — only when the screen changed since the
/// last check (a 32×18 grey thumbnail is compared first), so a static screen
/// costs one small capture per interval. Without Screen Recording permission
/// it does nothing (and never prompts).
final class ScreenTextWatcher {
    private var watch: ScreenTextWatchSet
    private let interval: TimeInterval
    private let area: ScreenTextArea
    private let onAppear: (String) -> Void
    private var timer: Timer?
    private var busy = false
    private var lastThumbnail: [UInt8] = []

    init(texts: Set<String>, interval: TimeInterval, area: ScreenTextArea = .display, onAppear: @escaping (String) -> Void) {
        watch = ScreenTextWatchSet(texts: texts)
        self.area = area
        self.interval = min(60, max(2, interval))
        self.onAppear = onAppear
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { stop() }

    private func tick() {
        guard !busy, ScreenCaptureService.hasPermission, !PresetManager.isRunningTests else { return }
        busy = true
        guard let bounds = Self.bounds(for: area) else { busy = false; return }
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            guard let capture = try? await ScreenCaptureService.shared.captureArea(bounds, showsCursor: false, pixelSnap: true) else { return }
            let thumbnail = Self.thumbnail(capture.image)
            guard let self else { return }
            if self.watch.hasBaseline, thumbnail == self.lastThumbnail { return }
            self.lastThumbnail = thumbnail
            let text = await ClipboardScreenContextOCR.recognize(capture.image)
            for appeared in self.watch.appeared(in: text) { self.onAppear(appeared) }
        }
    }

    /// 7.23: the global top-left rectangle to read for an area, nil when
    /// there is nothing to read (no front window).
    static func bounds(for area: ScreenTextArea) -> CGRect? {
        switch area {
        case .display:
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
            guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        case .frontWindow:
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            else { return nil }
            for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict), rect.width >= 40, rect.height >= 40 else { continue }
                return rect
            }
            return nil
        case .region:
            return area.rect
        }
    }

    /// 32×18 8-bit grey pixels; equal arrays mean nothing visible changed
    /// enough to re-read the screen.
    static func thumbnail(_ image: CGImage) -> [UInt8] {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
