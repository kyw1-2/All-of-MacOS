import Foundation

/// The System Tools page's tools by group, for places that report what the
/// page offers without building it (the Workspace tile). The ids and groups
/// follow `SystemToolsView.groups`; keep the two in step when a tool is added
/// or removed.
enum SystemToolsInventory {
    static let groups: [(name: String, toolIDs: [String])] = [
        ("Finder & Network", ["hidden", "desktop", "finder", "dns"]),
        ("PDF & Media", ["pdfmerge", "pdfcompress", "imageconvert", "videoconvert", "qr"]),
        ("Cleanup", ["cache", "dsstore", "trash"])
    ]

    /// Counted the way the page header counts: every tool in every group.
    static var count: Int { groups.reduce(0) { $0 + $1.toolIDs.count } }
}
