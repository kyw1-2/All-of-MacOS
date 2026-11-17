import AppKit
import SwiftUI

// AOM 6.2 — the Automation list header.
//
// Up to 6.1.1 the list column opened with a tall warning box, a row of scope
// chips, a row of input chips and the search field far away in the toolbar:
// three stacked bands of equal weight. The owner called it blunt and ugly.
// Studied: Raycast (one search bar, a dropdown accessory at its right end for
// the second filter dimension), Finder (the search scope beside the query),
// Apple Mail's categories (icon segments; the selected one expands to its name
// in its colour), Linear (a view title with a count, filters as quiet tokens),
// Things and Notion (view titles), BetterTouchTool and Keyboard Maestro (apps
// and groups shown with their own icons), Shortcuts (folder counts), Xcode's
// navigator filter, Spotify's filter pills, GitHub's filter tokens.
//
// Result, top to bottom: a view title with the count; one search field whose
// right end is the scope (the app's own icon, "All apps", a menu with apps and
// groups and their counts); the input kinds as a Mail-style category bar.

/// One choice of the scope menu.
struct AutomationScopeChoice: Identifiable, Hashable {
    enum Kind: Hashable { case all, everywhere, app(UUID), group(UUID) }
    let kind: Kind
    let title: String
    let count: Int
    /// An app's bundle identifier, for its icon.
    var bundleID: String?
    var id: Kind { kind }

    var symbol: String {
        switch kind {
        case .all: return "square.stack.fill"
        case .everywhere: return "globe"
        case .app: return "app.fill"
        case .group: return "square.stack.3d.up.fill"
        }
    }
}

/// One segment of the input bar.
struct AutomationInputChoice: Identifiable, Hashable {
    let category: TriggerCategory
    let title: String
    let symbol: String
    let count: Int
    var id: TriggerCategory { category }
}

struct AutomationListHeader: View {
    let total: Int
    @Binding var query: String
    @Binding var focusRequest: Bool
    let scopes: [AutomationScopeChoice]
    let scope: AutomationScopeChoice.Kind
    let selectScope: (AutomationScopeChoice.Kind) -> Void
    let inputs: [AutomationInputChoice]
    @Binding var input: TriggerCategory
    let editGroups: () -> Void

    @FocusState private var searchFocused: Bool
    @Namespace private var segment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var current: AutomationScopeChoice? { scopes.first { $0.kind == scope } }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2 + AOMSpace.x0_5) {
            titleRow
            searchField
            inputBar
        }
        .padding(.horizontal, AOMSpace.x3)
        .padding(.top, AOMSpace.x3)
        .padding(.bottom, AOMSpace.x2)
        .onChange(of: focusRequest) { _, requested in
            if requested { searchFocused = true; focusRequest = false }
        }
    }

    // MARK: Title

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Text("Automations")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AOMColor.text)
                .accessibilityAddTraits(.isHeader)
            Text("\(total)")
                .font(AOMFont.callout.monospacedDigit())
                .foregroundStyle(AOMColor.textTertiary)
            Spacer(minLength: AOMSpace.x2)
        }
    }

    // MARK: Search + scope

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AOMColor.textTertiary)
            TextField("Search \(current?.count ?? total) automations", text: $query)
                .textFieldStyle(.plain)
                .font(AOMFont.body)
                .focused($searchFocused)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search automations")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            scopeMenu
        }
        .padding(.leading, AOMSpace.x2 + AOMSpace.x0_5)
        .padding(.trailing, AOMSpace.x1)
        .frame(height: 32)
        .background(AOMColor.surface, in: shape)
        .overlay {
            shape.strokeBorder(searchFocused ? AOMColor.accent.opacity(0.7)
                               : (contrast == .increased ? AOMColor.strongLine : AOMColor.hairline),
                               lineWidth: searchFocused ? 1.5 : 0.5)
        }
        .aomAnimation(.quick, value: searchFocused)
    }

    /// The scope as the search field's accessory (Raycast's dropdown): the
    /// app's own icon or a glyph, its name, a chevron; the menu lists every
    /// scope with its count.
    private var scopeMenu: some View {
        Menu {
            ForEach(scopes.filter { $0.kind == .all || $0.kind == .everywhere }) { choice in
                scopeItem(choice)
            }
            let apps = scopes.filter { if case .app = $0.kind { return true }; return false }
            if !apps.isEmpty {
                Section("Only in an app") { ForEach(apps) { scopeItem($0) } }
            }
            let groups = scopes.filter { if case .group = $0.kind { return true }; return false }
            if !groups.isEmpty {
                Section("Activation groups") { ForEach(groups) { scopeItem($0) } }
            }
            Divider()
            Button("Edit Activation Groups…", action: editGroups)
        } label: {
            HStack(spacing: AOMSpace.x1) {
                scopeIcon(current, size: 15)
                Text(current?.title ?? "All apps")
                    .font(AOMFont.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AOMColor.textTertiary)
            }
            .foregroundStyle(AOMColor.text)
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 24)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which automations the list shows. Each automation's “Applies to” sets where it runs.")
        .accessibilityLabel("Show automations for, \(current?.title ?? "All apps")")
    }

    private func scopeItem(_ choice: AutomationScopeChoice) -> some View {
        Button {
            selectScope(choice.kind)
        } label: {
            if let image = Self.appIcon(choice.bundleID) {
                Label { Text("\(choice.title)  \(choice.count)") } icon: { Image(nsImage: image) }
            } else {
                Label("\(choice.title)  \(choice.count)", systemImage: choice.kind == scope ? "checkmark" : choice.symbol)
            }
        }
    }

    @ViewBuilder private func scopeIcon(_ choice: AutomationScopeChoice?, size: CGFloat) -> some View {
        if let image = Self.appIcon(choice?.bundleID) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: choice?.symbol ?? "square.stack.fill")
                .font(.system(size: size - 4, weight: .semibold))
                .foregroundStyle(AOMModule.automation.hue)
                .frame(width: size, height: size)
        }
    }

    /// An app's icon, 16 pt, cached by bundle identifier.
    @MainActor private static var iconCache: [String: NSImage] = [:]
    @MainActor static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        iconCache[bundleID] = image
        return image
    }

    // MARK: Input bar

    /// The input kinds as one segmented track (macOS segmented controls,
    /// Linear's view switcher): every segment shows its glyph and count, the
    /// selected one sits on a raised white plate with its name, in the
    /// automation colour. No coloured capsule.
    private var inputBar: some View {
        let track = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 2) {
            ForEach(inputs) { choice in
                let selected = choice.category == input
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { input = choice.category }
                } label: {
                    HStack(spacing: AOMSpace.x1) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? AOMModule.automation.hue : AOMColor.textSecondary)
                        if selected {
                            Text(choice.title)
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.text)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Text("\(choice.count)")
                            .font(AOMFont.caption.monospacedDigit())
                            .foregroundStyle(selected ? AOMColor.textSecondary : AOMColor.textTertiary)
                            .fixedSize()
                    }
                    .fixedSize(horizontal: selected, vertical: false)
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(maxWidth: selected ? nil : .infinity)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AOMColor.surface)
                                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "selection", in: segment)
                        }
                    }
                    .contentShape(Rectangle())
                    .opacity(choice.count == 0 && !selected ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .layoutPriority(selected ? 1 : 0)
                .help("\(choice.title) · \(choice.count)")
                .accessibilityLabel(choice.title)
                .accessibilityValue("\(choice.count) automations")
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: track)
        .overlay {
            if contrast == .increased { track.strokeBorder(AOMColor.strongLine, lineWidth: 1) }
        }
    }
}

// MARK: - Compact status strip

/// The permission or pause notice as one slim line over the list (6.2),
/// instead of a tall box: the reason in a few words and its one fix.
struct AOMStatusStrip: View {
    let tone: AOMTone
    let text: String
    var detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: tone.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.color)
            Text(text)
                .font(AOMFont.callout.weight(.medium))
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
                .help(detail ?? text)
            Spacer(minLength: AOMSpace.x1)
            Button(actionTitle, action: action)
                .buttonStyle(AOMSoftButtonStyle())
                .controlSize(.mini)
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: 32)
        .background(tone.color.opacity(0.08))
        .overlay(alignment: .bottom) { AOMDivider() }
        .accessibilityElement(children: .combine)
    }
}
