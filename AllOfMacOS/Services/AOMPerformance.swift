import Foundation
import os

/// Opt-in Instruments intervals: no keystrokes, window titles or app identities.
/// Launch with AOM_PERFORMANCE_TRACE=1; normal input avoids interval allocation.
enum AOMPerformance {
    private static let log = OSLog(subsystem: "com.kyw.allofmacos", category: .pointsOfInterest)

    private static let enabled = ProcessInfo.processInfo.environment["AOM_PERFORMANCE_TRACE"] == "1"

    static func begin(_ name: StaticString) -> OSSignpostID? {
        guard enabled, log.signpostsEnabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID?) {
        guard let id else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
