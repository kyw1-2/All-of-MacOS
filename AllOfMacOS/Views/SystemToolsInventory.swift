import Foundation

/// The System Tools page's tools by section, for places that report what the
/// page offers without building it (the Workspace tile). Derived from
/// `SystemToolCatalog`, the list the page itself draws, so the two can't
/// drift apart. Tools whose command isn't installed (Homebrew) are neither
/// shown nor counted.
enum SystemToolsInventory {
    static var groups: [(name: String, toolIDs: [String])] {
        SystemToolGroup.allCases.map { group in
            (group.name, SystemToolCatalog.availableTools(in: group).map(\.id.rawValue))
        }.filter { !$0.toolIDs.isEmpty }
    }

    /// Counted the way the page header counts: every tool the page shows.
    static var count: Int { SystemToolCatalog.available.count }

    /// A one-line summary for the Workspace tile.
    static var subtitle: String {
        SystemToolAvailability.shared.hasHomebrew ? "Toggles, storage, Homebrew" : "Toggles, storage, network"
    }
}
