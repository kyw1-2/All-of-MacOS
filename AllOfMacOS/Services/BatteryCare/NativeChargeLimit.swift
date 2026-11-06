import Foundation
import ObjectiveC

/// Optional PowerUI MCL bridge. Probe selectors and ABI, never infer support
/// from the OS version number.
final class NativeChargeLimit {
    struct State {
        let percent: Int
        let enabled: Bool
    }

    private let client: AnyObject
    private typealias Get = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt8
    private typealias Enabled = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt64
    private typealias SetLimit = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias Disable = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool

    private let get: Get
    private let enabled: Enabled
    private let set: SetLimit
    private let disable: Disable

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let alloc = class_getClassMethod(cls, NSSelectorFromString("alloc")),
              let initialize = Self.method(cls, "initWithClientName:", result: "@", arguments: ["@"]),
              let support = Self.method(cls, "isMCLSupported", result: "B", arguments: []),
              let getMethod = Self.method(cls, "getMCLLimitWithError:", result: "C", arguments: ["^@"]),
              let enabledMethod = Self.method(cls, "isMCLCurrentlyEnabled:", result: "Q", arguments: ["^@"]),
              let setMethod = Self.method(cls, "setMCLLimit:error:", result: "B", arguments: ["C", "^@"]),
              let disableMethod = Self.method(cls, "disableMCL:", result: "B", arguments: ["^@"]) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, NSString) -> UnsafeMutableRawPointer?
        typealias Supported = @convention(c) (AnyObject, Selector) -> Bool
        let allocate = unsafeBitCast(method_getImplementation(alloc), to: Alloc.self)
        let initClient = unsafeBitCast(method_getImplementation(initialize), to: Initialize.self)
        guard let storage = allocate(cls, NSSelectorFromString("alloc")),
              let instance = initClient(storage, NSSelectorFromString("initWithClientName:"), "All of MacOS") else { return nil }
        client = Unmanaged<AnyObject>.fromOpaque(instance).takeRetainedValue()
        let isSupported = unsafeBitCast(method_getImplementation(support), to: Supported.self)
        guard isSupported(client, NSSelectorFromString("isMCLSupported")) else { return nil }
        get = unsafeBitCast(method_getImplementation(getMethod), to: Get.self)
        enabled = unsafeBitCast(method_getImplementation(enabledMethod), to: Enabled.self)
        set = unsafeBitCast(method_getImplementation(setMethod), to: SetLimit.self)
        disable = unsafeBitCast(method_getImplementation(disableMethod), to: Disable.self)
    }

    private static func method(_ cls: AnyClass, _ name: String, result: String, arguments: [String]) -> Method? {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              method_getNumberOfArguments(method) == arguments.count + 2 else { return nil }
        let returned = method_copyReturnType(method)
        defer { free(returned) }
        guard String(cString: returned) == result else { return nil }
        for (i, expected) in arguments.enumerated() {
            guard let actual = method_copyArgumentType(method, UInt32(i + 2)) else { return nil }
            defer { free(actual) }
            guard String(cString: actual) == expected else { return nil }
        }
        return method
    }

    func state() throws -> State {
        var error: NSError?
        let percent = get(client, NSSelectorFromString("getMCLLimitWithError:"), &error)
        if let error { throw error }
        let on = enabled(client, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error)
        if let error { throw error }
        guard (80...100).contains(percent) else { throw HardwareControlError.unavailable("macOS returned an unknown charging limit") }
        return State(percent: Int(percent), enabled: on != 0)
    }

    func limit80(_ on: Bool) throws -> State {
        var error: NSError?
        let ok = on ? set(client, NSSelectorFromString("setMCLLimit:error:"), 80, &error)
                    : disable(client, NSSelectorFromString("disableMCL:"), &error)
        if let error { throw error }
        guard ok else { throw HardwareControlError.unavailable("macOS refused the charging limit") }
        let state = try state()
        guard on ? (state.enabled && state.percent == 80) : !state.enabled else {
            throw HardwareControlError.unavailable("macOS has not confirmed the charging limit")
        }
        return state
    }
}
