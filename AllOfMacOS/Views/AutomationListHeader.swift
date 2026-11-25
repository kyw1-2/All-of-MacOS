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
    let inputs: [AutomationInputChoice]
    @Binding var input: TriggerCategory
    @Namespace private var segment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// 7.18: search and the scope live in the page toolbar (one filter field,
    /// one options menu); the list header keeps only the input picker.
    var body: some View {
        inputBar
            .padding(.horizontal, AOMSpace.x3)
            .padding(.top, AOMSpace.x3)
            .padding(.bottom, AOMSpace.x2)
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
