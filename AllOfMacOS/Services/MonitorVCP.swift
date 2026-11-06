/// DDC/CI Get VCP and Set VCP packets. IOAVService supplies the host address
/// (0x51) separately from the payload. Monitor replies include their address.
enum MonitorVCP: UInt8, CaseIterable {
    case brightness = 0x10
    case contrast = 0x12
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D

    static let inputSources: [(code: UInt16, title: String)] = [
        (0x11, "HDMI 1"), (0x12, "HDMI 2"), (0x0F, "DisplayPort"), (0x1B, "USB-C")
    ]

    static func validInputSource(_ code: UInt16) -> Bool {
        inputSources.contains { $0.code == code }
    }

    struct Reading: Equatable {
        let current: UInt16
        let maximum: UInt16
        var fraction: Float { maximum == 0 ? 0 : Float(current) / Float(maximum) }

        func scaled(_ level: Float) -> UInt16 {
            UInt16((min(1, max(0, level)) * Float(maximum)).rounded())
        }
    }

    func request(value: UInt16? = nil) -> [UInt8] {
        var packet: [UInt8]
        if let value {
            packet = [0x84, 0x03, rawValue, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
        } else {
            packet = [0x82, 0x01, rawValue]
        }
        packet.append(packet.reduce(0x6e ^ 0x51, ^))
        return packet
    }

    func decode(_ reply: [UInt8]) -> Reading? {
        guard reply.count == 11, reply[0] == 0x6e, reply[1] == 0x88,
              reply[2] == 2, reply[3] == 0, reply[4] == rawValue, reply[5] == 0,
              reply.reduce(0x50, ^) == 0 else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        // Enum controls do not report a meaningful maximum, and sometimes report zero.
        if self != .inputSource && self != .mute {
            guard maximum > 0, current <= maximum else { return nil }
        }
        return Reading(current: current, maximum: maximum)
    }
}


/// At minimum backlight, continue down the calibrated gamma ramp. Coming back
/// up retraces the ramp before increasing the physical backlight.
/// One combined slider: 0...10% is software sub-zero dimming at
/// physical backlight minimum; the remainder is real DDC hardware brightness.
enum MonitorCombinedBrightness {
    static let softwareRange: Float = 0.1
    static let minimumGain: Float = 0.1

    static func slider(hardware: Float, gain: Float) -> Float {
        if gain < 1 && hardware <= 0.0001 {
            return softwareRange * min(1, max(0, (gain - minimumGain) / (1 - minimumGain)))
        }
        return softwareRange + (1 - softwareRange) * min(1, max(0, hardware))
    }

    static func target(slider: Float) -> (hardware: Float, gain: Float) {
        let value = min(1, max(0, slider))
        if value < softwareRange {
            return (0, minimumGain + value / softwareRange * (1 - minimumGain))
        }
        return ((value - softwareRange) / (1 - softwareRange), 1)
    }
}

enum MonitorBrightnessStep: Equatable {
    case brightness(Float)
    case gamma(Float)

    static func next(hardware: Float?, gain: Float, up: Bool) -> Self {
        let delta: Float = up ? 0.0625 : -0.0625
        if hardware == 0 && (!up || gain < 1) {
            return .gamma(min(1, max(0.1, gain + delta)))
        }
        return .brightness(min(1, max(hardware == nil ? 0.1 : 0, (hardware ?? gain) + delta)))
    }
}
