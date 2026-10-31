import Foundation

/// The System Tools page's tools by group, for places that report what the
/// page offers without building it (the Workspace tile). Derived from
/// `SystemToolCatalog`, the list the page itself draws, so the two can't
/// drift apart. Tools whose app or command isn't installed (Homebrew,
/// Tailscale, OpenVPN Connect) are neither shown nor counted.
enum SystemToolsInventory {
    static var groups: [(name: String, toolIDs: [String])] {
        SystemToolGroup.allCases.map { group in
            (group.name, SystemToolCatalog.availableTools(in: group).map(\.id.rawValue))
        }.filter { !$0.toolIDs.isEmpty }
    }

    /// Counted the way the page header counts: every tool the page shows.
    static var count: Int { SystemToolCatalog.available.count }

    /// The groups the page shows (a group whose tools all need something
    /// missing, such as Homebrew, isn't shown).
    static var groupCount: Int { groups.count }

    /// A one-line summary for the Workspace tile, short enough to share the
    /// tile's single "value · status" line with the count (24 characters).
    static var subtitle: String {
        SystemToolAvailability.shared.hasHomebrew ? "Toggles, Homebrew, PDF" : "Toggles, power and PDF"
    }
}
