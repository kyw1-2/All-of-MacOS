import AppKit
import IOKit.hid

/// Pure HID/scroll translation. The UGREEN receiver exposes relative
/// Consumer AC Pan (0x0C:0x0238). Some revisions also expose Zoom/Z/Dial,
/// but those are *buttons* on our observed receiver and must not scroll.
enum UGREENThumbWheelMapping {
    static let vendor = 0x2b89
    static let product = 0x0912
    static let usages: [(page: UInt32, usage: UInt32)] = [
        (12, 0x0238), // Consumer AC Pan
        (12, 0x022F), // Consumer AC Zoom (only when relative)
        (1, 0x0032),  // Generic Desktop Z (only when relative)
        (1, 0x0037)   // Generic Desktop Dial (only when relative)
    ]

    static func isWheel(page: UInt32, usage: UInt32, isRelative: Bool) -> Bool {
        isRelative && usages.contains { $0.page == page && $0.usage == usage }
    }

    /// IOHIDValueGetIntegerValue may give an unsigned representation even
    /// when the actual report represents a signed 8-bit delta (255 means -1).
    /// Refuse malformed/non-relative/button data and cap runaway reports.
    static func ticks(raw: Int, bitSize: Int, isRelative: Bool) -> Int? {
        guard isRelative, (1...32).contains(bitSize) else { return nil }
        let width = Int64(1) << bitSize
        let value = Int64(raw)
        guard value >= -(width / 2), value < width else { return nil }
        let signed = value >= width / 2 ? value - width : value
        guard signed != 0 else { return nil }
        return Int(max(-8, min(8, signed)))
    }

    /// A deliberate click of the UGREEN thumb wheel changes the current
    /// system output by 3 percentage points. The device reports signed AC Pan
    /// ticks; positive means right, negative means left. Cap abnormal bursts.
    static func volumeDelta(ticks: Int) -> Double {
        Double(max(-4, min(4, ticks))) * 3.0
    }

    static let pixelsPerTick = 36

    /// Populate line, point and 16.16 fixed-point fields consistently.
    /// Keep the event continuous like a horizontal trackpad scroll, but tag
    /// it so AOM's independent wheel reverse/smoothing never processes it.
    static func scrollEvent(ticks: Int, location: CGPoint, flags: CGEventFlags = []) -> CGEvent? {
        guard (-8...8).contains(ticks), ticks != 0 else { return nil }
        let pixels = ticks * pixelsPerTick
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: Int32(pixels), wheel3: 0) else { return nil }
        event.location = location
        event.flags = flags
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(ticks))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pixels))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(pixels) * 65_536)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
        return event
    }
}

/// Narrow UGREEN-only HID fallback. All callbacks run on the main run loop,
/// no device is seized and no HID values from keyboards/other mice are read.
/// Native horizontal CG/NSEvent input wins to prevent double scrolling.
final class MouseWheelInterceptor {
    static let shared = MouseWheelInterceptor()
    private var manager: IOHIDManager?
    private var nativeMonitor: Any?
    /// Unlike the legacy horizontal-scroll fallback, this mode consumes the
    /// receiver's actual relative AC Pan reports for output volume. It does not
    /// claim all horizontal gestures from a trackpad or other mouse.
    private var volumeMode = false
    private lazy var volumeQueue = MouseWheelVolumeQueue { [weak self] delta, completion in
        guard let self, self.isRunning, self.volumeMode, AutomationGate.allows(.mouse) else {
            completion(); return
        }
        AudioOutputService.shared.adjustVolume(percentagePoints: delta) { ok in
            if !ok { NSLog("[MouseWheelInterceptor] UGREEN side wheel: output volume write failed") }
            completion()
        }
    }
    private var wantsEnabled = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let nativeSuppressionWindow: TimeInterval = 0.08

    static func shouldSynthesize(elapsedSinceNative: TimeInterval) -> Bool {
        elapsedSinceNative > nativeSuppressionWindow
    }

    private var lastNativeHorizontal: TimeInterval = -.infinity
    private var pendingWork: DispatchWorkItem?
    private var pendingTicks = 0
    private var latestLocation = CGPoint.zero
    private var latestFlags: CGEventFlags = []
    private(set) var isRunning = false

    func setEnabled(_ enabled: Bool, volumeMode: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        wantsEnabled = enabled
        if enabled, isRunning, self.volumeMode == volumeMode { return }
        stopObservation()
        self.volumeMode = volumeMode
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        observeRecovery()
        guard enabled else { return }
        guard AXIsProcessTrusted() else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Int] = [kIOHIDVendorIDKey: UGREENThumbWheelMapping.vendor,
                                    kIOHIDProductIDKey: UGREENThumbWheelMapping.product]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let filters = UGREENThumbWheelMapping.usages.map { entry in
            [kIOHIDElementUsagePageKey: Int(entry.page), kIOHIDElementUsageKey: Int(entry.usage)]
        }
        IOHIDManagerSetInputValueMatchingMultiple(manager, filters as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<MouseWheelInterceptor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard UGREENThumbWheelMapping.isWheel(page: page, usage: usage,
                                                  isRelative: IOHIDElementIsRelative(element)),
                  let ticks = UGREENThumbWheelMapping.ticks(raw: IOHIDValueGetIntegerValue(value),
                                                            bitSize: Int(IOHIDElementGetReportSize(element)),
                                                            isRelative: IOHIDElementIsRelative(element)) else { return }
            if owner.volumeMode {
                // Only Consumer AC Pan 0C:0238 is the physical SIDE wheel.
                // Do not turn the receiver's buttons, X/Y motion, Z or Dial into volume.
                guard page == 12, usage == 0x0238 else { return }
                owner.receiveVolume(ticks)
            } else {
                owner.receive(ticks)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            NSLog("[MouseWheelInterceptor] UGREEN HID observation unavailable (%d)", opened)
            return
        }
        self.manager = manager
        if !volumeMode { nativeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticInput.selfTag { return }
            // Only native horizontal motion is relevant. Vertical wheels or
            // touchpad momentum must not suppress the UGREEN thumb wheel.
            let nativeHorizontal = event.scrollingDeltaX != 0 ||
                (event.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis2) ?? 0) != 0 ||
                (event.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) ?? 0) != 0
            guard nativeHorizontal else { return }
            self.lastNativeHorizontal = ProcessInfo.processInfo.systemUptime
            self.pendingTicks = 0
            self.pendingWork?.cancel()
            self.pendingWork = nil
        } }
        isRunning = true
        NSLog("[MouseWheelInterceptor] UGREEN AC Pan mode: %@", volumeMode ? "output-volume" : "horizontal-scroll")
    }

    private func receiveVolume(_ ticks: Int) {
        guard isRunning, volumeMode, AutomationGate.allows(.mouse) else { return }
        volumeQueue.add(ticks: ticks)
    }

    private func receive(_ ticks: Int) {
        guard isRunning else { return }
        // An HID report may precede its native NSEvent: wait one short frame
        // for macOS to deliver that event before posting a fallback.
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldSynthesize(elapsedSinceNative: now - lastNativeHorizontal) else { return }
        pendingTicks = max(-8, min(8, pendingTicks + ticks))
        latestLocation = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        latestFlags = CGEventSource.flagsState(.combinedSessionState)
        guard pendingWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingWork = nil
            let ticks = self.pendingTicks
            self.pendingTicks = 0
            guard Self.shouldSynthesize(elapsedSinceNative:
                      ProcessInfo.processInfo.systemUptime - self.lastNativeHorizontal),
                  AutomationGate.allows(.mouse),
                  let event = UGREENThumbWheelMapping.scrollEvent(ticks: ticks,
                      location: self.latestLocation, flags: self.latestFlags) else { return }
            event.post(tap: .cgSessionEventTap)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        wantsEnabled = false
        stopObservation()
    }

    private func observeRecovery() {
        guard observers.isEmpty else { return }
        let settingsToken = NotificationCenter.default.addObserver(forName: .aomSettingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.setEnabled(InputRemapSettings.ugreenThumbWheel, volumeMode: InputRemapSettings.ugreenThumbWheelVolume)
        }
        observers.append((.default, settingsToken))
        func observe(_ center: NotificationCenter, _ name: Notification.Name, restart: Bool, suspend: Bool = false) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.wantsEnabled else { return }
                if restart || suspend { self.stopObservation() }
                if !suspend { self.setEnabled(true, volumeMode: self.volumeMode) }
            }
            observers.append((center, token))
        }
        observe(.default, PermissionWatchdog.accessibilityLost, restart: false, suspend: true)
        observe(.default, PermissionWatchdog.accessibilityRecovered, restart: true)
        observe(.default, NSApplication.didBecomeActiveNotification, restart: false)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, restart: false, suspend: true)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, restart: true)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification, restart: true)
    }

    private func stopObservation() {
        isRunning = false
        pendingWork?.cancel(); pendingWork = nil; pendingTicks = 0
        volumeQueue.reset()
        lastNativeHorizontal = -.infinity
        if let nativeMonitor { NSEvent.removeMonitor(nativeMonitor) }
        nativeMonitor = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        stopObservation()
    }
}

/// Main-thread coalescing with at most one hardware request in flight. Slow
/// monitor/DDC volume writes must not build a seconds-long queue of old ticks.
final class MouseWheelVolumeQueue {
    typealias Schedule = (@escaping () -> Void) -> Void
    private let schedule: Schedule
    private let write: (Double, @escaping () -> Void) -> Void
    private var pending = 0.0
    private var scheduled = false
    private var writing = false
    private var generation = 0

    init(schedule: @escaping Schedule = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }, write: @escaping (Double, @escaping () -> Void) -> Void) {
        self.schedule = schedule
        self.write = write
    }

    func add(ticks: Int) {
        // Preserve the existing four-tick/12-point burst limit, including
        // when the device takes longer than one batching interval to reply.
        let limit = UGREENThumbWheelMapping.volumeDelta(ticks: 4)
        pending = max(-limit, min(limit, pending + UGREENThumbWheelMapping.volumeDelta(ticks: ticks)))
        drainLater()
    }

    func reset() {
        generation += 1
        pending = 0
        scheduled = false
        // An already submitted write still owns the slot until completion.
    }

    private func drainLater() {
        guard pending != 0, !scheduled, !writing else { return }
        scheduled = true
        let expected = generation
        schedule { [weak self] in
            guard let self, self.generation == expected else { return }
            self.scheduled = false
            let delta = self.pending
            self.pending = 0
            guard delta != 0 else { return }
            self.writing = true
            self.write(delta) { [weak self] in
                guard let self else { return }
                self.writing = false
                self.drainLater()
            }
        }
    }
}
