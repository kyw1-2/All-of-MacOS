import Foundation

/// The System Tools page's tools by group, for places that report what the
/// page offers without building it (the Workspace tile). Derived from
/// `SystemToolCatalog`, the list the page itself draws, so the two can't
/// drift apart.
enum SystemToolsInventory {
    static var groups: [(name: String, toolIDs: [String])] {
        SystemToolGroup.allCases.map { group in
            (group.name, SystemToolCatalog.tools(in: group).map(\.id.rawValue))
        }.filter { !$0.toolIDs.isEmpty }
    }

    /// Counted the way the page header counts: every tool in every group.
    static var count: Int { SystemToolCatalog.all.count }

    /// A one-line summary for the Workspace tile, short enough to share the
    /// tile's single "value · status" line with the count.
    static let subtitle = "Toggles, cleanup, dev and more"
}
