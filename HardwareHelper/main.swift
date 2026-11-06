import Foundation
import SystemConfiguration
import IOKit.pwr_mgt
import Darwin

private func consoleUserID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid != 0 else { return nil }
    return uid
}

final class HelperState {
    let queue = DispatchQueue(label: "com.kyw.allofmacos.hardware", qos: .utility)
    var controller: HardwareController?
    var owner: UUID?
    var ownerUID: uid_t?
    var deadline = 0.0
    var timer: DispatchSourceTimer?
    var failure: String?
    var sleeping = false

    func prepare() throws {
        if controller == nil {
            let smc = try SMCTransport()
            let reader = HardwareReader()
            controller = try HardwareController(
                smc: smc, journal: URL(fileURLWithPath: "/var/db/com.kyw.allofmacos.HardwareHelper.plist"),
                readSample: { reader.sample() },
                thermalPressure: {
                    let state = ProcessInfo.processInfo.thermalState
                    return state == .serious || state == .critical
                })
        }
    }

    func stop() {
        owner = nil
        ownerUID = nil
        do {
            if controller == nil && FileManager.default.fileExists(atPath: "/var/db/com.kyw.allofmacos.HardwareHelper.plist") { try prepare() }
            try controller?.stop()
            timer?.cancel(); timer = nil
            failure = nil
        } catch {
            failure = error.localizedDescription
            startTimer() // Keep retrying restoration; the journal survives crashes.
        }
    }

    func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.owner != nil, self.ownerUID == consoleUserID(), !self.sleeping, ProcessInfo.processInfo.systemUptime < self.deadline else {
                self.stop(); return
            }
            do { try self.controller?.tick() }
            catch { let reason = error.localizedDescription; self.stop(); self.failure = reason }
        }
        self.timer = timer
        timer.resume()
    }
}

final class HelperSession: NSObject, HardwareHelperProtocol {
    let id = UUID()
    let state: HelperState
    let uid: uid_t
    init(_ state: HelperState, uid: uid_t) { self.state = state; self.uid = uid }

    func configure(battery: String, fan: String, reply: @escaping (String?) -> Void) {
        state.queue.async {
            guard let battery = BatteryCareMode(rawValue: battery), let fan = FanPreset(rawValue: fan) else {
                reply("Unknown hardware policy"); return
            }
            guard consoleUserID() == self.uid, !self.state.sleeping, self.state.owner == nil || self.state.owner == self.id else {
                reply("Hardware control is busy"); return
            }
            do {
                try self.state.prepare()
                try self.state.controller?.configure(battery: battery, fan: fan)
                self.state.failure = nil
                if battery == .off && fan == .auto { self.state.stop() }
                else {
                    self.state.owner = self.id
                    self.state.ownerUID = self.uid
                    self.state.deadline = ProcessInfo.processInfo.systemUptime + 30
                    self.state.startTimer()
                }
                reply(nil)
            } catch {
                let reason = error.localizedDescription
                self.state.stop()
                reply(reason + (self.state.failure.map { "; " + $0 } ?? ""))
            }
        }
    }

    func renew(reply: @escaping (String?) -> Void) {
        state.queue.async {
            guard consoleUserID() == self.uid, self.state.owner == self.id else {
                reply(self.state.failure ?? "Hardware control ended; select the policy again")
                return
            }
            self.state.deadline = ProcessInfo.processInfo.systemUptime + 30
            reply(nil)
        }
    }

    func releaseControl(reply: @escaping (String?) -> Void) {
        state.queue.async {
            if self.state.owner == self.id { self.state.stop() }
            reply(self.state.failure)
        }
    }

    func disconnected() {
        state.queue.async { if self.state.owner == self.id { self.state.stop() } }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    let state: HelperState
    let requirement: String
    init(state: HelperState) throws {
        self.state = state
        requirement = try HardwareHelperIdentity.requirement(identifier: "com.kyw.allofmacos")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let uid = consoleUserID(), connection.effectiveUserIdentifier == uid else { return false }
        connection.setCodeSigningRequirement(requirement)
        let session = HelperSession(state, uid: uid)
        connection.exportedInterface = NSXPCInterface(with: HardwareHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnected() }
        connection.interruptionHandler = { session.disconnected() }
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else { fputs("The hardware helper must be launched by SMAppService.\n", stderr); exit(1) }
let state = HelperState()
let delegate: HelperDelegate
do { delegate = try HelperDelegate(state: state) }
catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
state.queue.async {
    do { try state.prepare() }
    catch {
        state.failure = error.localizedDescription
        if FileManager.default.fileExists(atPath: "/var/db/com.kyw.allofmacos.HardwareHelper.plist") { state.startTimer() }
    }
}

// Before sleep restore the firmware defaults; do not leave a quiet fan pinned
// while AOM cannot renew its lease. Legacy policies must be selected after wake.
var powerPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
var powerRoot: io_connect_t = 0
// IOMessage.h iokit_common_msg constants (macros are not imported into Swift).
powerRoot = IORegisterForSystemPower(nil, &powerPort, { _, _, message, argument in
    let token = Int(bitPattern: argument)
    if message == 0xe0000270 {
        IOAllowPowerChange(powerRoot, token)
    } else if message == 0xe0000280 {
        state.queue.async {
            state.sleeping = true
            state.stop()
            IOAllowPowerChange(powerRoot, token)
        }
    } else if message == 0xe0000300 {
        state.queue.async { state.sleeping = false }
    }
}, &powerNotifier)
if let powerPort, let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
}

signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: state.queue)
termination.setEventHandler { state.stop(); exit(state.failure == nil ? 0 : 1) }
termination.resume()
let listener = NSXPCListener(machServiceName: HardwareHelperIdentity.name)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
