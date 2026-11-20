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
    /// 6.10 (AlDente-style controls on macOS 27 firmware).
    @Published private(set) var power: BatteryTelemetry?
    /// The native macOS limit, nil when off; `nativeAvailable` once probed.
    @Published private(set) var nativeLimit: Int?
    @Published private(set) var nativeAvailable = false
    /// Discharging to this level through the helper (adapter cut).
    @Published private(set) var dischargeTarget: Int?
    /// Topping up to 100 %; the limit to put back afterwards.
    @Published private(set) var topUpRestore: Int? = {
        let saved = UserDefaults.standard.integer(forKey: HardwareCareModel.topUpKey)
        return (80...100).contains(saved) ? saved : nil
    }()
    /// The running helper is older than this AOM (it refused a new policy).
    @Published private(set) var helperOutdated = false
    static let topUpKey = "AOMBatteryTopUpRestore"

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
            let telemetry = BatteryTelemetry.read()
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
                if self.power != telemetry { self.power = telemetry }
                let available = self.native != nil
                if self.nativeAvailable != available { self.nativeAvailable = available }
                if let current {
                    let limit = current.enabled ? current.percent : nil
                    if self.nativeLimit != limit { self.nativeLimit = limit }
                }
                self.followUp(telemetry)
                if !self.busy, self.helperBattery == .off {
                    let next: BatteryCareMode = current?.enabled == true && current?.percent == 80 ? .limit80 : .off
                    if self.battery != next { self.battery = next }
                }
            }
        }
    }

    /// Asks Service Management on the worker queue: the status is an XPC
    /// round trip that stalled the System Tools page as it opened.
    func refreshHelper() {
        worker.async {
            let status = SMAppService.daemon(plistName: HardwareHelperIdentity.plist).status
            DispatchQueue.main.async { self.apply(helperStatus: status) }
        }
    }

    private func refreshHelperNow() {
        apply(helperStatus: SMAppService.daemon(plistName: HardwareHelperIdentity.plist).status)
    }

    private func apply(helperStatus status: SMAppService.Status) {
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
            refreshHelperNow()
            if !helperReady { SMAppService.openSystemSettingsLoginItems() }
        } catch { message = error.localizedDescription; refreshHelperNow() }
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

    // MARK: 6.10 battery controls

    /// One read now (menu bar panel, launcher), whether or not the page shows.
    func refreshBattery() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        sampleNow()
    }

    /// Top Up ends at 100 % or when the adapter goes; Discharge ends at its target.
    private func followUp(_ telemetry: BatteryTelemetry?) {
        guard let telemetry, let percent = telemetry.percent else { return }
        if let restore = topUpRestore, percent >= 100 || telemetry.fullyCharged || !telemetry.externalConnected {
            setLimit(restore, endingTopUp: true)
            message = percent >= 100 ? "Topped up to 100%; the \(restore)% limit is back" : "Unplugged; the \(restore)% limit is back"
        }
        if let target = dischargeTarget, percent <= target, !busy {
            stopDischarge(reached: target)
        }
    }

    /// The limits macOS takes, shared by the card, the menu bar and the launcher.
    static let limits = [80, 85, 90, 95, 100]

    /// Whether Top Up can do anything now: a limit to lift, on the adapter.
    var canTopUp: Bool { nativeLimit != nil && topUpRestore == nil && (power?.externalConnected ?? sample.onAC) }

    /// The native macOS limit (80–100 %), or off with nil. `done` gets the
    /// result as shown to the user, once macOS has confirmed (or refused) it.
    func setLimit(_ percent: Int?, endingTopUp: Bool = true, done: ((String) -> Void)? = nil) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { done?("Not available in previews"); return }
        guard !busy else { done?("Another battery change is still running"); return }
        busy = true
        if endingTopUp { setTopUpRestore(nil) }
        worker.async {
            if !self.nativeChecked { self.native = NativeChargeLimit(); self.nativeChecked = true }
            let result = Result { () throws -> NativeChargeLimit.State in
                guard let native = self.native else {
                    throw HardwareControlError.unavailable("This Mac's macOS has no native charge limit (macOS 26.4 or later)")
                }
                return try percent.map(native.setLimit) ?? native.disableLimit()
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let state):
                    self.nativeLimit = state.enabled ? state.percent : nil
                    self.battery = state.enabled && state.percent == 80 ? .limit80 : .off
                    self.message = state.enabled ? "Charging stops at \(state.percent)% (macOS's own limit)" : "Charge limit off"
                case .failure(let error):
                    self.message = error.localizedDescription
                }
                done?(self.message)
                self.sampleNow()
            }
        }
    }

    /// AlDente's bypass on macOS 27: stop charging here and run on the
    /// adapter — the native limit at this level (5 % steps, 80 % at least).
    func holdHere(done: ((String) -> Void)? = nil) {
        guard let percent = power?.percent ?? sample.batteryPercent else { message = "No battery reading yet"; done?(message); return }
        let limit = BatteryTelemetry.holdLimit(for: percent)
        setLimit(limit) { [weak self] result in
            guard let self, self.nativeLimit == limit else { done?(result); return }
            self.message = percent < 80 ? "Charges to 80%, then holds there (macOS 27 can't hold lower; Discharge goes lower)"
                : "Holding at \(limit)%: the Mac runs on the adapter, the battery rests"
            done?(self.message)
        }
    }

    /// Charge to 100 % once, then put the limit back.
    func topUp(done: ((String) -> Void)? = nil) {
        guard let limit = nativeLimit else { message = "No limit is set, so the battery already charges to 100%"; done?(message); return }
        setTopUpRestore(limit)
        setLimit(nil, endingTopUp: false) { [weak self] result in
            guard let self else { return }
            guard self.nativeLimit == nil else { self.setTopUpRestore(nil); done?(result); return }
            self.message = "Topping up to 100%; \(limit)% comes back when full or unplugged"
            done?(self.message)
        }
    }

    private func setTopUpRestore(_ value: Int?) {
        topUpRestore = value
        if let value { UserDefaults.standard.set(value, forKey: Self.topUpKey) } else { UserDefaults.standard.removeObject(forKey: Self.topUpKey) }
    }

    /// Cuts the adapter through the helper until the battery reaches `target`.
    func discharge(to target: Int, done: ((String) -> Void)? = nil) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { done?("Not available in previews"); return }
        guard !busy else { done?("Another battery change is still running"); return }
        guard power?.externalConnected ?? sample.onAC else {
            message = "Plug in the adapter first; discharge runs on battery while it stays connected"; done?(message); return
        }
        if let percent = power?.percent, percent <= target { message = "The battery is already at \(percent)%"; done?(message); return }
        busy = true
        message = ""
        configureHelper(battery: .discharge, fan: fan, target: target) { success in
            self.dischargeTarget = success ? target : nil
            if success { self.message = "Discharging to \(target)%: the adapter is cut; it comes back at \(target)%, on sleep, or if AOM quits" }
            done?(self.message)
            self.sampleNow()
        }
    }

    func stopDischarge(reached: Int? = nil, done: ((String) -> Void)? = nil) {
        guard dischargeTarget != nil else { done?("No discharge is running"); return }
        dischargeTarget = nil
        busy = true
        configureHelper(battery: .off, fan: fan) { _ in
            self.message = reached.map { "Reached \($0)%; the adapter is back" } ?? "Discharge stopped; the adapter is back"
            done?(self.message)
            self.sampleNow()
        }
    }

    /// Replaces a helper an AOM update left running (unregister, register).
    func restartHelper() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        let old = connection
        connection = nil
        old?.invalidate()
        worker.async {
            let service = SMAppService.daemon(plistName: HardwareHelperIdentity.plist)
            var failure: String?
            do {
                try? service.unregister()
                try service.register()
            } catch { failure = error.localizedDescription }
            let status = service.status
            DispatchQueue.main.async {
                self.apply(helperStatus: status)
                self.helperOutdated = false
                if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                self.message = failure ?? (status == .enabled ? "Battery helper restarted with this version" : "Allow AOM in Login Items to finish")
            }
        }
    }

    private func configureHelper(battery: BatteryCareMode, fan: FanPreset, completion: @escaping (Bool) -> Void) {
        configureHelper(battery: battery, fan: fan, target: nil, completion: completion)
    }

    private func configureHelper(battery: BatteryCareMode, fan: FanPreset, target: Int?, completion: @escaping (Bool) -> Void) {
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
            let code = battery == .discharge ? "discharge-\(target ?? 80)" : battery.rawValue
            proxy.configure(battery: code, fan: fan.rawValue) { error in
                DispatchQueue.main.async {
                    guard self.generation == request, !self.terminating else { return }
                    self.timeout?.cancel(); self.timeout = nil
                    self.busy = false
                    if let error {
                        // An older helper doesn't know a newer policy.
                        if error.contains("Unknown hardware policy") { self.helperOutdated = true }
                        self.controlFailed(self.helperOutdated
                            ? "The battery helper is from an older AOM. Restart Helper, then try again." : error)
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
        dischargeTarget = nil
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
