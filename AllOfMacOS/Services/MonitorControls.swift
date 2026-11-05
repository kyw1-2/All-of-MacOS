import CoreGraphics
import Foundation
import CoreFoundation

protocol MonitorBus {
    func ports(for ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef]
    func probe(_ feature: MonitorVCP, on port: CFTypeRef) -> MonitorVCP.Reading?
    func send(_ packet: [UInt8], to port: CFTypeRef) -> Bool
}

/// Capabilities are learned once per topology. UI reads only the snapshot.
final class MonitorControls {
    static let shared = MonitorControls()
    private let bus: MonitorBus?
    private let discovery = DispatchQueue(label: "aom.monitor.discovery", qos: .utility)
    private var queues: [CGDirectDisplayID: DispatchQueue] = [:]
    private let lock = NSLock()
    private var generation = 0

    init(bus: MonitorBus? = MonitorI2C()) {
        self.bus = bus
    }

    private struct Key: Hashable {
        let id: CGDirectDisplayID
        let feature: MonitorVCP
    }
    enum WriteResult { case applied, failed, cancelled }

    private final class Pending {
        let target: UInt16
        let completion: ((WriteResult) -> Void)?

        init(target: UInt16, completion: ((WriteResult) -> Void)?) {
            self.target = target
            self.completion = completion
        }

        func cancel() {
            if let completion { DispatchQueue.main.async { completion(.cancelled) } }
        }
    }
    private struct Control {
        let port: CFTypeRef
        let queue: DispatchQueue
        var reading: MonitorVCP.Reading
        var pending: Pending?
        var inFlight: Pending?
    }
    private var controls: [Key: Control] = [:]
    private var output: (device: UInt32, display: CGDirectDisplayID)?

    func bindOutput(device: UInt32, display: CGDirectDisplayID?) {
        lock.lock(); defer { lock.unlock() }
        output = display.map { (device, $0) }
    }

    func outputLevel(device: UInt32) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let output, output.device == device else { return nil }
        return cachedLevel(output.display, .volume)
    }

    func reset(displays: [CGDirectDisplayID], ready: @escaping () -> Void) {
        lock.lock()
        generation += 1
        let revision = generation
        for control in controls.values { control.pending?.cancel() }
        controls.removeAll()
        output = nil
        queues = queues.filter { displays.contains($0.key) }
        for id in displays where queues[id] == nil {
            queues[id] = DispatchQueue(label: "aom.monitor.ddc.\(id)", qos: .userInitiated)
        }
        let activeQueues = queues
        lock.unlock()
        guard let bus, !displays.isEmpty else { ready(); return }
        discovery.async {
            guard self.isCurrent(revision) else { return }
            let ports = bus.ports(for: displays)
            let notify = {
                DispatchQueue.main.async { if self.isCurrent(revision) { ready() } }
            }
            if ports.isEmpty { notify() }
            for (id, port) in ports {
                guard let queue = activeQueues[id] else { continue }
                queue.async {
                    for feature in MonitorVCP.allCases {
                        guard self.isCurrent(revision) else { return }
                        guard let value = bus.probe(feature, on: port) else { continue }
                        self.lock.lock()
                        if self.generation == revision {
                            self.controls[Key(id: id, feature: feature)] = Control(port: port, queue: queue, reading: value)
                        }
                        self.lock.unlock()
                    }
                    notify()
                }
            }
        }
    }

    private func isCurrent(_ revision: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == revision
    }

    func level(_ id: CGDirectDisplayID, _ feature: MonitorVCP) -> Float? {
        lock.lock(); defer { lock.unlock() }
        return cachedLevel(id, feature)
    }

    private func cachedLevel(_ id: CGDirectDisplayID, _ feature: MonitorVCP) -> Float? {
        guard let control = controls[Key(id: id, feature: feature)] else { return nil }
        return Float(control.pending?.target ?? control.reading.current) / Float(control.reading.maximum)
    }

    /// Every accepted request completes on main, including superseded writes.
    @discardableResult
    func request(_ id: CGDirectDisplayID, _ feature: MonitorVCP, _ level: Float,
                 completion: ((WriteResult) -> Void)? = nil) -> Bool {
        let key = Key(id: id, feature: feature)
        lock.lock(); defer { lock.unlock() }
        guard level.isFinite, var control = controls[key] else { return false }
        let target = control.reading.scaled(level)
        let schedule = control.pending == nil
        control.pending?.cancel()
        control.pending = Pending(target: target, completion: completion)
        controls[key] = control
        if schedule { enqueue(key, generation, control.queue) }
        return true
    }

    private func enqueue(_ key: Key, _ revision: Int, _ queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { self.flush(key, revision) }
    }

    private func flush(_ key: Key, _ revision: Int) {
        lock.lock()
        guard generation == revision, let control = controls[key], let pending = control.pending else {
            lock.unlock(); return
        }
        controls[key]?.inFlight = pending
        lock.unlock()
        // IOAVService exposes no cancellation API. A stuck driver must not
        // strand the audio action queue, even if the kernel call returns late.
        let timeout = DispatchWorkItem {
            self.lock.lock()
            guard self.generation == revision, let control = self.controls[key],
                  control.inFlight === pending else { self.lock.unlock(); return }
            self.controls[key] = nil
            self.lock.unlock()
            DispatchQueue.main.async {
                control.pending?.completion?(self.isCurrent(revision) ? .failed : .cancelled)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250), execute: timeout)
        let ok = bus?.send(key.feature.request(value: pending.target), to: control.port) == true
        timeout.cancel()
        lock.lock()
        guard generation == revision, let latest = controls[key]?.pending else { lock.unlock(); return }
        controls[key]?.inFlight = nil
        if ok {
            controls[key]?.reading = .init(current: pending.target, maximum: control.reading.maximum)
            if latest !== pending {
                enqueue(key, revision, control.queue)
                lock.unlock()
                return
            }
            controls[key]?.pending = nil
        } else {
            controls[key] = nil
        }
        lock.unlock()
        DispatchQueue.main.async {
            let result: WriteResult = self.isCurrent(revision) ? (ok ? .applied : .failed) : .cancelled
            latest.completion?(result)
        }
    }
}
