import AppKit
import IOKit
import IOKit.hid

/// Per-service acceleration overrides. All access is on the main run loop.
final class PointerAcceleration: NSObject, ObservableObject {
    static let shared = PointerAcceleration()
    @Published private(set) var status = "Off"
    private var enabled = false
    private var client: CFTypeRef?
    private var owned: [UInt64: (service: CFTypeRef, key: String, original: NSNumber)] = [:]
    private var manager: IOHIDManager?
    private lazy var api = API()
    private let recoveryKey = "AOMPointerAccelerationRecovery"
    private struct Recovery: Codable {
        let boot: String
        let id: UInt64
        let key: String
        let original: Int64
    }
    private lazy var boot: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }()

    private func saveRecovery() {
        guard !boot.isEmpty else { return }
        let records = owned.map { Recovery(boot: boot, id: $0.key, key: $0.value.key, original: $0.value.original.int64Value) }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recoveryKey)
    }

    private func recoverPreviousRun() -> Bool {
        guard owned.isEmpty, let data = UserDefaults.standard.data(forKey: recoveryKey),
              let records = try? JSONDecoder().decode([Recovery].self, from: data), !records.isEmpty else { return true }
        guard let api else { return false }
        if client == nil { client = api.create(nil, 1, nil)?.takeRetainedValue() }
        guard let client, let services = api.services(client)?.takeRetainedValue() as? [AnyObject] else { return false }
        for record in records where !boot.isEmpty && record.boot == boot &&
            (record.key == "HIDMouseAcceleration" || record.key == "HIDPointerAcceleration") {
            guard let service = services.first(where: { api.registryID($0) == record.id }),
                  let current = api.get(service, record.key as CFString)?.takeRetainedValue() as? NSNumber,
                  current.int64Value == -65_536 else { continue }
            let original = NSNumber(value: record.original)
            if !api.set(service, record.key as CFString, original) ||
                (api.get(service, record.key as CFString)?.takeRetainedValue() as? NSNumber)?.int64Value != record.original {
                owned[record.id] = (service, record.key, original)
            }
        }
        saveRecovery()
        return owned.isEmpty
    }

    private struct API {
        typealias Create = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
        typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias Get = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias Set = @convention(c) (CFTypeRef, CFString, CFTypeRef) -> Bool
        typealias Conforms = @convention(c) (CFTypeRef, UInt32, UInt32) -> Bool
        typealias RegistryID = @convention(c) (CFTypeRef) -> UInt64
        let create: Create
        let services: Services
        let get: Get
        let set: Set
        let conforms: Conforms
        let registryID: RegistryID

        init?() {
            guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
                  let c = dlsym(library, "IOHIDEventSystemClientCreateWithType"),
                  let s = dlsym(library, "IOHIDEventSystemClientCopyServices"),
                  let g = dlsym(library, "IOHIDServiceClientCopyProperty"),
                  let w = dlsym(library, "IOHIDServiceClientSetProperty"),
                  let m = dlsym(library, "IOHIDServiceClientConformsTo"),
                  let i = dlsym(library, "IOHIDServiceClientGetRegistryID") else { return nil }
            create = unsafeBitCast(c, to: Create.self)
            services = unsafeBitCast(s, to: Services.self)
            get = unsafeBitCast(g, to: Get.self)
            set = unsafeBitCast(w, to: Set.self)
            conforms = unsafeBitCast(m, to: Conforms.self)
            registryID = unsafeBitCast(i, to: RegistryID.self)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        guard recoverPreviousRun() else { status = "Could not restore the previous mouse acceleration; retry after reconnecting"; return }
        guard value else { status = restore() ? "Off" : "Mouse acceleration restoration failed; retry after reconnecting"; return }
        guard !boot.isEmpty else { status = "Cannot record mouse acceleration recovery on this Mac"; return }
        guard let api else { status = "Pointer control is unavailable on this macOS version"; return }
        if client == nil { client = api.create(nil, 1, nil)?.takeRetainedValue() }
        guard client != nil else { status = "macOS refused pointer access"; return }
        if manager == nil {
            let manager = IOHIDManagerCreate(nil, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let changed: IOHIDDeviceCallback = { context, _, _, _ in
                guard let context else { return }
                let control = Unmanaged<PointerAcceleration>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { control.refresh() }
                // IOHID service publication can trail the device-matched callback.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { control.refresh() }
            }
            IOHIDManagerRegisterDeviceMatchingCallback(manager, changed, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, changed, context)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        }
        refresh()
    }

    @objc private func refresh() {
        guard enabled, let api, let client,
              let services = api.services(client)?.takeRetainedValue() as? [AnyObject] else { return }
        var present = Set<UInt64>()
        var count = 0
        for service in services {
            let id = api.registryID(service)
            present.insert(id)
            guard api.conforms(service, 1, 2), !api.conforms(service, 13, 5) else { continue }
            func property(_ key: String) -> AnyObject? { api.get(service, key as CFString)?.takeRetainedValue() }
            guard (property("Built-In") as? NSNumber)?.boolValue != true,
                  (property("Transport") as? String) != "SPI" else { continue }
            let key = property("HIDPointerAccelerationType") as? String ?? "HIDMouseAcceleration"
            guard key == "HIDMouseAcceleration" || key == "HIDPointerAcceleration",
                  let old = property(key) as? NSNumber else { continue }
            // This is an IOFixed value. -1.0 is -65536, not integer -1.
            if owned[id] != nil {
                if old.int64Value == -65_536 { count += 1 }
                continue
            }
            guard old.int64Value != -65_536 else { continue }
            owned[id] = (service, key, old)
            saveRecovery() // Record ownership before changing a persistent HID property.
            if api.set(service, key as CFString, NSNumber(value: -65_536)),
               (property(key) as? NSNumber)?.int64Value == -65_536 { count += 1 }
        }
        owned = owned.filter { present.contains($0.key) }
        saveRecovery()
        status = count > 0 ? "Linear motion active on \(count) mouse\(count == 1 ? "" : "s")" : "No supported external mouse, or macOS refused the change"
    }

    private func restore() -> Bool {
        var failed: [UInt64: (service: CFTypeRef, key: String, original: NSNumber)] = [:]
        if let api {
            for (id, item) in owned {
                let now = api.get(item.service, item.key as CFString)?.takeRetainedValue() as? NSNumber
                if now?.int64Value == -65_536 {
                    if !api.set(item.service, item.key as CFString, item.original) ||
                        (api.get(item.service, item.key as CFString)?.takeRetainedValue() as? NSNumber)?.int64Value != item.original.int64Value {
                        failed[id] = item
                    }
                }
            }
        }
        owned = failed
        saveRecovery()
        if let manager { IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
        manager = nil
        client = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        return failed.isEmpty
    }
}
