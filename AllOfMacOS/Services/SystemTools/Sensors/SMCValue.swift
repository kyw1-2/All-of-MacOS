import Foundation

struct SMCValue: Codable, Equatable {
    let type: String
    let bytes: [UInt8]

    var number: Double? {
        switch (type, bytes.count) {
        case ("ui8 ", 1): return Double(bytes[0])
        case ("ui16", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case ("fpe2", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("flt ", 4):
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        default: return nil
        }
    }

    func encoding(_ value: Double) -> SMCValue? {
        guard value.isFinite, value >= 0 else { return nil }
        switch (type, bytes.count) {
        case ("fpe2", 2):
            guard value <= 16383.75 else { return nil }
            let raw = UInt16((value * 4).rounded())
            return .init(type: type, bytes: [UInt8(raw >> 8), UInt8(truncatingIfNeeded: raw)])
        case ("flt ", 4):
            guard Float(value).isFinite else { return nil }
            let raw = Float(value).bitPattern
            return .init(type: type, bytes: (0..<4).map { UInt8(truncatingIfNeeded: raw >> ($0 * 8)) })
        default: return nil
        }
    }
}

enum HardwareControlError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}
