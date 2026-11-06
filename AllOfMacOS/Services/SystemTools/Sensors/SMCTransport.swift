import Foundation
import IOKit

/// AppleSMC user-client ABI. Explicit offsets avoid Swift structure padding.
/// One instance belongs to one serial queue.
final class SMCTransport {
    private var connection: io_connect_t = 0
    private var metadata: [String: (size: Int, type: String)] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw HardwareControlError.unavailable("AppleSMC is unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw HardwareControlError.unavailable("SMC access denied (\(result))")
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(key: String, command: UInt8, size: Int = 0, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, size <= 32, bytes.count <= 32 else {
            throw HardwareControlError.unavailable("Invalid SMC request")
        }
        var input = [UInt8](repeating: 0, count: 80)
        let rawKey = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        for i in 0..<4 {
            input[i] = UInt8(truncatingIfNeeded: rawKey >> (8 * i))
            input[28 + i] = UInt8(truncatingIfNeeded: UInt32(size) >> (8 * i))
        }
        input[42] = command
        for (index, value) in bytes.enumerated() { input[48 + index] = value }
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, target.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else {
            throw HardwareControlError.unavailable("SMC \(key) operation failed (\(result), \(output[40]))")
        }
        return output
    }

    func read(_ key: String) throws -> SMCValue {
        let info: (size: Int, type: String)
        if let cached = metadata[key] { info = cached }
        else {
            let reply = try call(key: key, command: 9)
            let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(reply[28 + $1]) << (8 * $1) }
            guard (1...32).contains(size) else { throw HardwareControlError.unavailable("SMC \(key) has no readable data") }
            info = (Int(size), String(bytes: reply[32..<36].reversed(), encoding: .ascii) ?? "")
            metadata[key] = info
        }
        let reply = try call(key: key, command: 5, size: info.size)
        return SMCValue(type: info.type, bytes: Array(reply[48..<(48 + info.size)]))
    }

    func write(_ key: String, value: SMCValue) throws {
        let current = try read(key)
        guard current.type == value.type, current.bytes.count == value.bytes.count else {
            throw HardwareControlError.unavailable("SMC \(key) format changed")
        }
        _ = try call(key: key, command: 6, size: value.bytes.count, bytes: value.bytes)
        guard try read(key) == value else { throw HardwareControlError.unavailable("SMC \(key) did not confirm the change") }
    }
}

extension SMCTransport: SMCWriting {}
