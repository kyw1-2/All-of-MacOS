import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The apps where the bar never appears: icon, name and identifier per row,
/// Remove on each (undoable), Add App… (an open panel on Applications) and
/// Add Running App (a menu of the apps open now).
struct TextActionsAppList: View {
    @Binding var bundleIDs: [String]
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if bundleIDs.isEmpty {
            AOMInlineEmpty(symbol: "hand.raised", message: "The bar can appear in every app.")
        }
        ForEach(bundleIDs, id: \.self) { bundleID in
            TextActionsAppRow(bundleID: bundleID, name: Self.name(bundleID)) { remove(bundleID) }
        }
        AOMSettingRow("Add an app", detail: "The bar stays away from it") {
            HStack(spacing: AOMSpace.x2) {
                Menu("Add Running App") {
                    let running = Self.runningApps(excluding: bundleIDs)
                    if running.isEmpty { Text("No other apps are open") }
                    ForEach(running, id: \.bundleID) { app in
                        Button(app.name) { add([app.bundleID]) }
                    }
                }
                .fixedSize()
                Button("Add App…") { chooseApps() }
            }
        }
    }

    private func add(_ ids: [String]) {
        let before = bundleIDs
        var seen = Set(before.map { $0.lowercased() })
        let added = ids.filter { seen.insert($0.lowercased()).inserted }
        guard !added.isEmpty else { return }
        AOMUndo.perform("Add App", undoManager: undoManager,
                        perform: { bundleIDs = before + added }, revert: { bundleIDs = before })
    }

    private func remove(_ bundleID: String) {
        let before = bundleIDs
        AOMUndo.perform("Remove App", undoManager: undoManager,
                        perform: { bundleIDs = before.filter { $0 != bundleID } }, revert: { bundleIDs = before })
    }

    private func chooseApps() {
        guard !PresetManager.isUIPreview else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    static func name(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return knownNames[bundleID.lowercased()] ?? bundleID
    }

    /// Names for the default list when the app is not installed here.
    private static let knownNames: [String: String] = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden", "com.apple.keychainaccess": "Keychain Access", "com.apple.passwords": "Passwords"
    ]

    static func runningApps(excluding ids: [String]) -> [(name: String, bundleID: String)] {
        let excluded = Set(ids.map { $0.lowercased() } + TextActionsGate.ownBundleIDs)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier, !excluded.contains(id.lowercased()), seen.insert(id).inserted else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One excluded app: its icon, name and identifier, and Remove. Laid out like
/// `AOMSettingRow` with a description, so the card reads as one list.
private struct TextActionsAppRow: View {
    let bundleID: String
    let name: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Group {
                if let icon = AppMetadataCache.shared.icon(for: bundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AOMColor.textSecondary)
                }
            }
            .frame(width: AOMIcon.row, height: AOMIcon.row)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                Text(bundleID)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: AOMSpace.x3)
            AOMIconButton("minus.circle", label: "Remove \(name)", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .accessibilityElement(children: .contain)
    }
}
