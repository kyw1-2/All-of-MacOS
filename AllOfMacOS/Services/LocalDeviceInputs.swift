import Foundation
import CoreMIDI
import GameController

/// MIDI 1 byte-stream decoder, retaining running status and incomplete messages
/// between packets. Realtime bytes may appear inside another message.
struct MIDIMessageDecoder {
    private var status: UInt8?
    private var payload: [UInt8] = []
    mutating func consume(_ bytes: [UInt8]) -> [(status: Int, channel: Int, number: Int, value: Int)] {
        var messages: [(Int, Int, Int, Int)] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte & 0x80 != 0 {
                payload.removeAll(); status = byte < 0xF0 ? byte : nil; continue
            }
            guard let status else { continue }
            payload.append(byte)
            let type = status & 0xF0
            let size = type == 0xC0 || type == 0xD0 ? 1 : 2
            guard payload.count == size else { continue }
            if [0x80, 0x90, 0xB0].contains(type) {
                let normalized = type == 0x90 && payload[1] == 0 ? 0x80 : type
                messages.append((Int(normalized), Int(status & 0x0F) + 1, Int(payload[0]), Int(payload[1])))
            }
            payload.removeAll()
        }
        return messages
    }
}

/// Public CoreMIDI input port, dynamically reconnecting when sources change.
final class MIDIInputMonitor {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var sources: [MIDIEndpointRef] = []
    private var decoders: [MIDIEndpointRef: MIDIMessageDecoder] = [:]
    private let emit: (SystemSignal) -> Void
    init(emit: @escaping (SystemSignal) -> Void) { self.emit = emit }
    func start() {
        guard client == 0 else { return }
        guard MIDIClientCreateWithBlock("AllOfMacOS" as CFString, &client, { [weak self] _ in
            DispatchQueue.main.async { self?.reconnect() }
        }) == noErr else { return }
        let result = MIDIInputPortCreateWithBlock(client, "AOM MIDI Input" as CFString, &port) { [weak self] list, context in
            let source = MIDIEndpointRef(UInt(bitPattern: context))
            let bytes = Self.packetBytes(list)
            DispatchQueue.main.async { self?.receive(bytes, source: source) }
        }
        guard result == noErr else { stop(); return }
        reconnect()
    }
    static func packetBytes(_ list: UnsafePointer<MIDIPacketList>) -> [UInt8] {
        var bytes: [UInt8] = []
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<list.pointee.numPackets {
            let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!)
            bytes.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: Int(packet.pointee.length)))
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        return bytes
    }
    func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        sources.removeAll(); decoders.removeAll()
    }
    deinit { stop() }
    private func reconnect() {
        guard port != 0 else { return }
        let next = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { $0 != 0 }
        for source in sources where !next.contains(source) { MIDIPortDisconnectSource(port, source); decoders[source] = nil }
        for source in next where !sources.contains(source) {
            MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: UInt(source)))
        }
        sources = next
    }
    private func receive(_ bytes: [UInt8], source: MIDIEndpointRef) {
        guard client != 0 else { return }
        var decoder = decoders[source] ?? MIDIMessageDecoder()
        let messages = decoder.consume(bytes); decoders[source] = decoder
        var value: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &value)
        let name = value?.takeRetainedValue() as String? ?? "MIDI"
        for message in messages {
            emit(.midi(device: name, status: message.status, channel: message.channel, number: message.number, value: message.value))
        }
    }
}

/// Public GameController driver. Only controls actually exposed by the attached
/// extended gamepad are registered. Threshold crossings generate press/release.
final class GamepadInputMonitor {
    private let emit: (SystemSignal) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var controllers: [GCController] = []
    private var started = false
    private var previousBackgroundSetting = false
    init(emit: @escaping (SystemSignal) -> Void) { self.emit = emit }
    func start() {
        guard !started else { return }; started = true
        previousBackgroundSetting = GCController.shouldMonitorBackgroundEvents
        GCController.shouldMonitorBackgroundEvents = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reconnect() })
        }
        reconnect()
    }
    func stop() {
        guard started else { return }; started = false
        tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
        controllers.forEach { $0.extendedGamepad?.valueChangedHandler = nil; $0.microGamepad?.valueChangedHandler = nil }; controllers.removeAll()
        GCController.shouldMonitorBackgroundEvents = previousBackgroundSetting
    }
    deinit { stop() }
    private func reconnect() {
        controllers.forEach { $0.extendedGamepad?.valueChangedHandler = nil; $0.microGamepad?.valueChangedHandler = nil }
        controllers = GCController.controllers()
        for controller in controllers {
            controller.handlerQueue = .main
            if controller.extendedGamepad == nil, let micro = controller.microGamepad {
                micro.reportsAbsoluteDpadValues = true
                let name = controller.vendorName ?? "Remote"
                var previous: [String: Bool] = [:]
                micro.valueChangedHandler = { [weak self] pad, _ in
                    let controls = [("a", pad.buttonA.isPressed), ("x", pad.buttonX.isPressed),
                                    ("up", pad.dpad.up.isPressed), ("down", pad.dpad.down.isPressed),
                                    ("left", pad.dpad.left.isPressed), ("right", pad.dpad.right.isPressed)]
                    for (control, pressed) in controls where pressed != (previous[control] ?? false) {
                        previous[control] = pressed
                        DispatchQueue.main.async { self?.emit(.gamepad(device: name, control: control, pressed: pressed)) }
                    }
                }
            }
            guard let pad = controller.extendedGamepad else { continue }
            let name = controller.vendorName ?? "Gamepad"
            var previous: [String: Bool] = [:]
            pad.valueChangedHandler = { [weak self] pad, _ in
                let controls: [(String, Bool)] = [
                    ("a", pad.buttonA.isPressed), ("b", pad.buttonB.isPressed),
                    ("x", pad.buttonX.isPressed), ("y", pad.buttonY.isPressed),
                    ("leftShoulder", pad.leftShoulder.isPressed), ("rightShoulder", pad.rightShoulder.isPressed),
                    ("leftTrigger", pad.leftTrigger.value >= 0.5), ("rightTrigger", pad.rightTrigger.value >= 0.5),
                    ("up", pad.dpad.up.isPressed), ("down", pad.dpad.down.isPressed),
                    ("left", pad.dpad.left.isPressed), ("right", pad.dpad.right.isPressed),
                    ("menu", pad.buttonMenu.isPressed), ("options", pad.buttonOptions?.isPressed ?? false),
                    ("leftThumbstick", pad.leftThumbstickButton?.isPressed ?? false),
                    ("rightThumbstick", pad.rightThumbstickButton?.isPressed ?? false),
                    ("leftStickUp", pad.leftThumbstick.yAxis.value >= 0.5), ("leftStickDown", pad.leftThumbstick.yAxis.value <= -0.5),
                    ("leftStickLeft", pad.leftThumbstick.xAxis.value <= -0.5), ("leftStickRight", pad.leftThumbstick.xAxis.value >= 0.5),
                    ("rightStickUp", pad.rightThumbstick.yAxis.value >= 0.5), ("rightStickDown", pad.rightThumbstick.yAxis.value <= -0.5),
                    ("rightStickLeft", pad.rightThumbstick.xAxis.value <= -0.5), ("rightStickRight", pad.rightThumbstick.xAxis.value >= 0.5)]
                for (control, pressed) in controls where pressed != (previous[control] ?? false) {
                    previous[control] = pressed
                    DispatchQueue.main.async { self?.emit(.gamepad(device: name, control: control, pressed: pressed)) }
                }
            }
        }
    }
}
