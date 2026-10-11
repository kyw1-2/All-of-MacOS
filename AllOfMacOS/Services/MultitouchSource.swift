import AppKit

/// ABI observed on the built-in trackpad and matching MTVector-based layouts.
/// Both normalized and absolute vectors contain POSITION AND VELOCITY (96 bytes).
/// The old 80-byte struct omitted both velocities, then guessed strides by
/// probing memory beyond the callback buffer. Never probe past a known record.
enum TouchFrameDecoder {
    static let stride = 96
    struct Frame {
        var contacts: [TouchPoint]
        var rawCount: Int
        var states: [Int]
    }
    static func decode(_ bytes: UnsafeRawBufferPointer, count: Int) -> Frame? {
        guard (0...32).contains(count), bytes.count >= count * stride else { return nil }
        var points: [TouchPoint] = []
        var ids = Set<Int>()
        var states: [Int] = []
        for i in 0..<count {
            let offset = i * stride
            let state = Int(bytes.loadUnaligned(fromByteOffset: offset + 20, as: Int32.self))
            guard (0...7).contains(state) else { return nil }
            states.append(state)
            // 1/2 are approach/hover; 5/6/7 are break/linger/lift. In particular,
            // a nonempty frame of lifted contacts is a ZERO-contact frame.
            guard state == 3 || state == 4 else { continue }
            let id = Int(bytes.loadUnaligned(fromByteOffset: offset + 16, as: Int32.self))
            let x = bytes.loadUnaligned(fromByteOffset: offset + 32, as: Float.self)
            let y = bytes.loadUnaligned(fromByteOffset: offset + 36, as: Float.self)
            let major = bytes.loadUnaligned(fromByteOffset: offset + 60, as: Float.self)
            let force = bytes.loadUnaligned(fromByteOffset: offset + 64, as: Float.self)
            guard id >= 0, ids.insert(id).inserted, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y), major.isFinite else { return nil }
            // A non-finite or out-of-range force is treated as "no reading"
            // rather than failing the frame: not every trackpad reports it.
            let pressure: Float = force.isFinite ? max(0, min(force, 1)) : 0
            points.append(TouchPoint(id: id, x: x, y: y, size: max(0, min(major / 20, 1)), pressure: pressure))
        }
        return Frame(contacts: points, rawCount: count, states: states)
    }
}

private typealias Device = UnsafeMutableRawPointer
private typealias ContactCallback = @convention(c) (Device?, UnsafeMutableRawPointer?, Int, Double, Int) -> Void
private let sourceLock = NSLock()
private weak var activeSource: MultitouchSource?
private let contactCallback: ContactCallback = { device, raw, count, timestamp, _ in
    sourceLock.lock()
    let source = activeSource
    sourceLock.unlock()
    source?.receive(device: device, raw: raw, count: count, timestamp: timestamp)
}

/// Owns hardware resources only. All recognition happens after a bounded value
/// copy; device callbacks never execute actions, create event taps, or touch UI.
final class MultitouchSource {
    private let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>
    private typealias Register = @convention(c) (Device, ContactCallback) -> Void
    private typealias Start = @convention(c) (Device, Int32) -> Int32
    private typealias Stop = @convention(c) (Device) -> Int32
    private typealias Running = @convention(c) (Device) -> Bool
    private typealias DeviceID = @convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32
    private var deviceList: CFArray?
    private var devices: [Device] = []
    private var token = UUID()
    private let lock = NSLock()
    var onFrame: ((UInt64, TouchFrameDecoder.Frame, Double) -> Void)?
    private(set) var error: String?
    private(set) var rejectedFrames = 0

    private func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let framework, let ptr = dlsym(framework, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }
    private func identifier(_ device: Device) -> UInt64 {
        var id: UInt64 = 0
        if let get = symbol("MTDeviceGetDeviceID", DeviceID.self), get(device, &id) == 0 { return id }
        return UInt64(UInt(bitPattern: device))
    }
    var deviceIDs: [UInt64] { devices.map(identifier) }
    var running: Bool {
        guard !devices.isEmpty, let check = symbol("MTDeviceIsRunning", Running.self) else { return false }
        return devices.allSatisfy(check)
    }
    func availableDeviceIDs() -> Set<UInt64> {
        guard let list = symbol("MTDeviceCreateList", CreateList.self) else { return [] }
        let array = list().takeRetainedValue()
        return Set((0..<CFArrayGetCount(array)).compactMap {
            CFArrayGetValueAtIndex(array, $0).map { identifier(Device(mutating: $0)) }
        })
    }
    func start() {
        stop()
        guard let create = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self) else {
            error = "MultitouchSupport unavailable"; return
        }
        error = nil
        let list = create().takeRetainedValue()
        deviceList = list
        sourceLock.lock(); activeSource = self; sourceLock.unlock()
        for i in 0..<CFArrayGetCount(list) {
            guard let ref = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = Device(mutating: ref)
            register(device, contactCallback)
            let status = start(device, 0)
            if status == 0 { devices.append(device) }
            else {
                symbol("MTUnregisterContactFrameCallback", Register.self)?(device, contactCallback)
                error = "MTDeviceStart failed: \(status)"
            }
        }
        if devices.isEmpty { error = error ?? "No trackpad found" }
    }
    func invalidatePendingFrames() { lock.lock(); token = UUID(); lock.unlock() }
    func stop() {
        sourceLock.lock()
        if activeSource === self { activeSource = nil }
        sourceLock.unlock()
        lock.lock(); token = UUID(); lock.unlock()
        for device in devices {
            symbol("MTUnregisterContactFrameCallback", Register.self)?(device, contactCallback)
            _ = symbol("MTDeviceStop", Stop.self)?(device)
        }
        devices.removeAll(); deviceList = nil
        lock.lock(); token = UUID(); lock.unlock()
    }
    fileprivate func receive(device: Device?, raw: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        guard let device, (0...32).contains(count), timestamp.isFinite, count == 0 || raw != nil else { return }
        lock.lock(); let generation = token; lock.unlock()
        let decoded = TouchFrameDecoder.decode(UnsafeRawBufferPointer(start: raw, count: count * TouchFrameDecoder.stride), count: count)
        let id = identifier(device)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let valid = self.token == generation; self.lock.unlock()
            guard valid else { return }
            guard let decoded else { self.rejectedFrames += 1; return }
            self.onFrame?(id, decoded, timestamp)
        }
    }
    deinit { stop() }
}
