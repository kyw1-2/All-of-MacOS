import AppKit
import Combine
import ServiceManagement

/// The view owns sampling demand. The helper lease runs only while a policy is
/// active. All IOKit and PowerUI work stays off the main/UI queue.
final class HardwareCareModel: ObservableObject {
    static let shared = HardwareCareModel()
    @Published private(set) var sample = HardwareSample()
    @Published private(set) var battery: BatteryCareMode = .off
    @Published private(set) var fan: FanPreset = .auto
    @Published private(set) var nativeStatus = "Checking native charge limit…"
    @Published private(set) var helperStatus = ""
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var helperReady = false

    private let worker = DispatchQueue(label: "com.kyw.allofmacos.hardware.read", qos: .utility)
    private let reader = HardwareReader()
    private var native: NativeChargeLimit?
    private var nativeChecked = false
    private var helperBattery: BatteryCareMode = .off
    private var connection: NSXPCConnection?
    private var sampling: Timer?
    private var lease: Timer?
    private var demand = 0
    private var samplingInFlight = false
    private var generation = 0
    private var timeout: DispatchWorkItem?
    private var terminating = false

    func appear() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        demand += 1
        refreshHelper()
        sampleNow()
        if sampling == nil {
            let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.sampleNow() }
            timer.tolerance = 1.6
            sampling = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func disappear() {
        demand = max(0, demand - 1)
        if demand == 0 { sampling?.invalidate(); sampling = nil }
    }

    private func sampleNow() {
        guard !terminating, !samplingInFlight else { return }
        samplingInFlight = true
        worker.async {
            let snapshot = self.reader.sample()
            if !self.nativeChecked { self.native = NativeChargeLimit(); self.nativeChecked = true }
            var text = "Native charge limit unavailable; optional helper required"
            var current: NativeChargeLimit.State?
            if let native = self.native {
                do {
                    current = try native.state()
                    text = current!.enabled ? "macOS charge limit: \(current!.percent)%" : "macOS native charge limit available"
                } catch { text = error.localizedDescription }
            }
            DispatchQueue.main.async {
                self.samplingInFlight = false
                guard !self.terminating else { return }
                if self.sample != snapshot { self.sample = snapshot }
                if self.nativeStatus != text { self.nativeStatus = text }
                if !self.busy, self.helperBattery == .off {
                    let next: BatteryCareMode = current?.enabled == true && current?.percent == 80 ? .limit80 : .off
                    if self.battery != next { self.battery = next }
                }
            }
        }
    }

    func refreshHelper() {
        let status = SMAppService.daemon(plistName: HardwareHelperIdentity.plist).status
        helperReady = status == .enabled
        switch status {
        case .enabled: helperStatus = "Hardware helper enabled"
        case .requiresApproval: helperStatus = "Allow AOM in System Settings → General → Login Items"
        case .notRegistered: helperStatus = "Optional helper is not enabled"
        default: helperStatus = "Helper is not bundled in this build"
        }
    }

    func installHelper() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        do {
            _ = try HardwareHelperIdentity.requirement(identifier: HardwareHelperIdentity.name)
            try SMAppService.daemon(plistName: HardwareHelperIdentity.plist).register()
            refreshHelper()
            if !helperReady { SMAppService.openSystemSettingsLoginItems() }
        } catch { message = error.localizedDescription; refreshHelper() }
    }

    func setBattery(_ mode: BatteryCareMode) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        guard !busy else { return }
        busy = true
        message = ""
        worker.async {
            if !self.nativeChecked { self.native = NativeChargeLimit(); self.nativeChecked = true }
            var failure: String?
            var confirmedNative = false
            do {
                if let native = self.native {
                    let old = try native.state()
                    if mode == .limit80 {
                        _ = try native.limit80(true)
                        confirmedNative = true
                    } else if old.enabled { _ = try native.limit80(false) }
                }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard !self.terminating else { return }
                if let failure { self.message = failure; self.busy = false; return }
                self.battery = confirmedNative ? .limit80 : .off
                self.helperBattery = .off
                let legacy = confirmedNative ? BatteryCareMode.off : mode
                self.configureHelper(battery: legacy, fan: self.fan) { success in
                    if success { self.battery = mode }
                    self.sampleNow()
                }
            }
        }
    }

    func setFan(_ preset: FanPreset) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        guard !busy else { return }
        busy = true
        message = ""
        configureHelper(battery: helperBattery, fan: preset) { _ in }
    }

    private func proxy() throws -> HardwareHelperProtocol {
        if connection == nil {
            let requirement = try HardwareHelperIdentity.requirement(identifier: HardwareHelperIdentity.name)
            let connection = NSXPCConnection(machServiceName: HardwareHelperIdentity.name, options: .privileged)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HardwareHelperProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let self, self.connection === connection else { return }
                    self.connection = nil
                    self.controlFailed("Hardware helper disconnected; defaults are being restored")
                }
            }
            connection.resume()
            self.connection = connection
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async { self?.controlFailed(error.localizedDescription) }
        }) as? HardwareHelperProtocol else { throw HardwareControlError.unavailable("Hardware helper could not be reached") }
        return proxy
    }

    private func configureHelper(battery: BatteryCareMode, fan: FanPreset, completion: @escaping (Bool) -> Void) {
        refreshHelper()
        if battery == .off && fan == .auto && connection == nil {
            helperBattery = .off
            self.fan = .auto
            busy = false
            completion(true)
            return
        }
        guard helperReady else {
            busy = false
            message = "Enable the optional hardware helper to use this control"
            completion(false)
            return
        }
        generation += 1
        let request = generation
        do {
            let proxy = try proxy()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == request else { return }
                self.controlFailed("Hardware helper timed out; control stopped")
            }
            self.timeout?.cancel()
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            proxy.configure(battery: battery.rawValue, fan: fan.rawValue) { error in
                DispatchQueue.main.async {
                    guard self.generation == request, !self.terminating else { return }
                    self.timeout?.cancel(); self.timeout = nil
                    self.busy = false
                    if let error {
                        self.controlFailed(error)
                        completion(false)
                    } else {
                        self.helperBattery = battery
                        self.fan = fan
                        self.lease?.invalidate(); self.lease = nil
                        if battery != .off || fan != .auto {
                            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.renew() }
                            timer.tolerance = 1
                            self.lease = timer
                            RunLoop.main.add(timer, forMode: .common)
                        }
                        self.message = "Applied and read back from hardware"
                        completion(true)
                    }
                }
            }
        } catch { controlFailed(error.localizedDescription); completion(false) }
    }

    private func renew() {
        guard !busy else { return }
        let request = generation
        do {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == request else { return }
                self.controlFailed("Hardware helper stopped responding; control ended")
            }
            self.timeout?.cancel()
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
            try proxy().renew { error in
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.timeout?.cancel(); self.timeout = nil
                    if let error { self.controlFailed(error) }
                }
            }
        } catch { controlFailed(error.localizedDescription) }
    }

    private func controlFailed(_ reason: String) {
        generation += 1
        timeout?.cancel(); timeout = nil
        lease?.invalidate(); lease = nil
        let old = connection
        connection = nil
        old?.invalidate()
        if helperBattery != .off { battery = .off }
        helperBattery = .off
        fan = .auto
        busy = false
        message = reason
    }

    func stop() {
        terminating = true
        sampling?.invalidate(); sampling = nil
        lease?.invalidate(); lease = nil
        timeout?.cancel(); timeout = nil
        // Connection invalidation independently restores controls on the daemon.
        connection?.invalidate()
        connection = nil
    }
}
