import Foundation
import IOKit.hid

struct GenericHIDFilter: Hashable {
    let vendorID: Int
    let productID: Int
}

/// Opt-in IOHID input: only explicitly configured VID/PID pairs are opened,
/// with nonseizing access. Standard keyboards/mice are excluded to prevent a
/// generic binding from duplicating the ordinary keyboard/mouse monitors.
final class GenericHIDInputMonitor {
    private var manager: IOHIDManager?
    private var lastValues: [String: Int] = [:]
    private let filters: Set<GenericHIDFilter>
    private let emit: (SystemSignal) -> Void
    init(filters: Set<GenericHIDFilter>, emit: @escaping (SystemSignal) -> Void) { self.filters = filters; self.emit = emit }
    func start() {
        guard manager == nil, !filters.isEmpty else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = filters.filter { (1...65535).contains($0.vendorID) && (1...65535).contains($0.productID) }.map {
            [kIOHIDVendorIDKey: $0.vendorID, kIOHIDProductIDKey: $0.productID]
        }
        guard !matching.isEmpty else { return }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<GenericHIDInputMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue); return
        }
        self.manager = manager
    }
    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)); self.manager = nil
        lastValues.removeAll()
    }
    deinit { stop() }
    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard !IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)),
              !IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)),
              let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber else { return }
        let usagePage = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
        let integer = IOHIDValueGetIntegerValue(value)
        let key = "\(IOHIDDeviceGetService(device)):\(IOHIDElementGetCookie(element))"
        guard lastValues[key] != integer else { return }; lastValues[key] = integer
        emit(.hid(vendorID: vendor.intValue, productID: product.intValue, usagePage: usagePage, usage: usage, value: integer))
    }
}
