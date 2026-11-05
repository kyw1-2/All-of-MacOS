import CoreGraphics
import Foundation
import IOKit

/// Resolve the optional Apple Silicon SPI at runtime. Only bind a port when
/// its registry path matches the display or the whole topology is unambiguous.
final class MonitorI2C: MonitorBus {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias DisplayInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

    private let create: Create
    private let read: Transfer
    private let write: Transfer
    private let info: DisplayInfo?

    init?() {
        #if arch(arm64)
        guard let framework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(framework, "IOAVServiceCreateWithService"),
              let r = dlsym(framework, "IOAVServiceReadI2C"),
              let w = dlsym(framework, "IOAVServiceWriteI2C") else { return nil }
        create = unsafeBitCast(c, to: Create.self)
        read = unsafeBitCast(r, to: Transfer.self)
        write = unsafeBitCast(w, to: Transfer.self)
        info = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
            .flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }
            .map { unsafeBitCast($0, to: DisplayInfo.self) }
        #else
        return nil
        #endif
    }

    func ports(for ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef] {
        guard !ids.isEmpty else { return [:] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [:] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var candidates: [(path: String, framebuffer: String?, port: CFTypeRef)] = []
        var externalCount = 0
        var framebuffer: String?
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        var path = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // DCP firmware can expose the proxy next to the framebuffer rather
            // than underneath its path. The recursive registry iterator groups
            // these entries by framebuffer. Require an exact display location.
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                framebuffer = IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
                    ? String(cString: path) : nil
                continue
            }
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS, String(cString: name) == "DCPAVServiceProxy",
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0),
                  location.takeRetainedValue() as? String == "External" else { continue }
            externalCount += 1
            guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS,
                  let port = create(nil, entry)?.takeRetainedValue() else { continue }
            candidates.append((String(cString: path), framebuffer, port))
        }
        if ids.count == 1, externalCount == 1, let only = candidates.first { return [ids[0]: only.port] }
        var matches: [String: [CGDirectDisplayID]] = [:]
        for id in ids {
            guard let dict = info?(id)?.takeRetainedValue() as NSDictionary?,
                  let path = dict["IODisplayLocation"] as? String, !path.isEmpty else { continue }
            let exact = candidates.filter { $0.framebuffer == path || $0.path == path || $0.path.hasPrefix(path + "/") }
            if exact.count == 1 { matches[exact[0].path, default: []].append(id) }
        }
        var result: [CGDirectDisplayID: CFTypeRef] = [:]
        for candidate in candidates {
            if let matched = matches[candidate.path], matched.count == 1 { result[matched[0]] = candidate.port }
        }
        return result
    }

    func probe(_ feature: MonitorVCP, on port: CFTypeRef) -> MonitorVCP.Reading? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard send(feature.request(), to: port) else { return nil }
        usleep(40_000)
        var reply = [UInt8](repeating: 0, count: 11)
        let status = reply.withUnsafeMutableBytes { read(port, 0x37, 0, $0.baseAddress!, UInt32($0.count)) }
        guard status == 0, DispatchTime.now().uptimeNanoseconds - start <= 100_000_000 else { return nil }
        return feature.decode(reply)
    }

    func send(_ packet: [UInt8], to port: CFTypeRef) -> Bool {
        var bytes = packet
        return bytes.withUnsafeMutableBytes { write(port, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == 0 }
    }
}
