import AppKit

/// Query only the tracked windows, including windows parked off screen.
/// Quartz expects raw integer window IDs in a callback-free CFArray, not
/// NSNumber objects. A missing/closed ID is simply absent from the result.
enum WindowInfoQuery {
    static func descriptions(for ids: Set<CGWindowID>) -> [[String: Any]]? {
        guard !ids.isEmpty else { return [] }
        let values = CFArrayCreateMutable(kCFAllocatorDefault, ids.count, nil)!
        for id in ids {
            CFArrayAppendValue(values, UnsafeRawPointer(bitPattern: UInt(id)))
        }
        return CGWindowListCreateDescriptionFromArray(values) as? [[String: Any]]
    }
}
