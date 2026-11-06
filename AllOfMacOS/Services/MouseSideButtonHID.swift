import AppKit
import IOKit.hid

/// Some composite receivers (including UGREEN 2b89:0912) expose mouse and
/// Consumer AC Back/Forward on a vendor-primary HID collection. Do not match
/// only PrimaryUsage=Mouse, and never seize the receiver or read key values.
final class MouseSideButtonHID {
    private var manager: IOHIDManager?
    private(set) var held = Set<Int>()
    var onEvent: ((Int, Bool) -> Void)?

    static func button(page: UInt32, usage: UInt32) -> Int? {
        switch (page, usage) {
        case (9, 4), (12, 0x224): return 3
        case (9, 5), (12, 0x225): return 4
        default: return nil
        }
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, nil)
        let matches: [[String: Int]] = [(9, 4), (9, 5), (12, 0x224), (12, 0x225)].map {
            [kIOHIDElementUsagePageKey: $0.0, kIOHIDElementUsageKey: $0.1]
        }
        IOHIDManagerSetInputValueMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<MouseSideButtonHID>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard let button = MouseSideButtonHID.button(page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element)),
                  let device = IOHIDElementGetDevice(element), owner.isMouseReceiver(device) else { return }
            let down = IOHIDValueGetIntegerValue(value) != 0
            if down { guard owner.held.insert(button).inserted else { return } }
            else { guard owner.held.remove(button) != nil else { return } }
            owner.onEvent?(button, down)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<MouseSideButtonHID>.fromOpaque(context).takeUnretainedValue()
            for button in owner.held { owner.onEvent?(button, false) }
            owner.held.removeAll()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("[MouseSideButtonHID] Cannot observe side buttons (%d); check Input Monitoring permission", result)
        }
    }

    static func isKnownCompositeReceiver(vendor: Int, product: Int) -> Bool {
        // Observed on the attached UGREEN 2b89:0912 receiver: the HID device
        // reports a vendor collection and a keyboard collection, but no
        // GenericDesktop Mouse (1:2) collection. Match this known hardware
        // exactly; never treat arbitrary keyboards as mice.
        vendor == 0x2b89 && product == 0x0912
    }

    private func isMouseReceiver(_ device: IOHIDDevice) -> Bool {
        guard let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber else { return false }
        if Self.isKnownCompositeReceiver(vendor: vendor.intValue, product: product.intValue) { return true }
        if IOHIDDeviceConformsTo(device, 1, 2) { return true }
        // Other vendors need a separate mouse collection on the same physical
        // receiver; never capture arbitrary keyboard/headset media keys.
        guard let manager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains {
            IOHIDDeviceConformsTo($0, 1, 2)
            && IOHIDDeviceGetProperty($0, kIOHIDVendorIDKey as CFString) as? NSNumber == vendor
            && IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? NSNumber == product
        }
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        held.removeAll()
    }
    deinit { stop() }
}

/// HID fallback waits for the normal event tap. Duplicate observations of an
/// edge are consumed once; distinct down/up pairs (double click) stay distinct.
struct MouseSideButtonDeduplicator {
    struct Edge: Hashable { let button: Int; let down: Bool }
    private var cg: [Edge: TimeInterval] = [:]
    private var fallback: [Edge: (time: TimeInterval, swallow: Bool)] = [:]
    mutating func noteCG(_ edge: Edge, time: TimeInterval) -> Bool? {
        cg[edge] = time
        guard let prior = fallback[edge], abs(time - prior.time) <= 0.08 else { return nil }
        fallback[edge] = nil
        return prior.swallow
    }
    func shouldDeliverHID(_ edge: Edge, time: TimeInterval) -> Bool {
        guard let seen = cg[edge] else { return true }
        return abs(time - seen) > 0.08
    }
    mutating func noteHID(_ edge: Edge, time: TimeInterval, swallow: Bool) {
        fallback[edge] = (time, swallow)
    }
}
