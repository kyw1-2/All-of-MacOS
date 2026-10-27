import AppKit
import SwiftUI

// Shared 2.0 building blocks. Each one owns its edge cases (long text, empty
// detail, disabled state, focus and VoiceOver), so pages compose them instead
// of restyling rows and headings locally.

// MARK: - List row

/// One list row in three slots — leading glyph, title over an optional
/// detail line, trailing value or control — after TDS ListRow, at desktop
/// sizes: 32 pt single-line, 48 pt two-line, 12 pt side padding.
struct AOMListRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var dimmed = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, dimmed: Bool = false,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.dimmed = dimmed
        self.leading = leading()
        self.trailing = trailing()
    }

    private var hasDetail: Bool { !(detail ?? "").isEmpty }

    var body: some View {
        // Hierarchical styles, not fixed label colors: List selection inverts
        // them to white on the accent fill, so selected rows stay readable.
        HStack(spacing: AOMSpace.s - 2) {
            leading
                .frame(width: 20)
                .foregroundStyle(dimmed ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AOMType.rowTitle)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail, hasDetail {
                    Text(detail)
                        .font(AOMType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: hasDetail ? AOMSize.rowDouble - 8 : AOMSize.rowSingle - 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heading

/// A section heading in the Things manner: plain semibold text with an
/// optional count and accessory, and a hairline underneath. No box.
struct AOMHeading<Accessory: View>: View {
    let title: String
    var count: String?
    var showsRule = true
    @ViewBuilder var accessory: Accessory

    init(_ title: String, count: String? = nil, showsRule: Bool = true,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.count = count
        self.showsRule = showsRule
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: AOMSpace.xs) {
                Text(title)
                    .font(AOMType.sectionTitle)
                    .foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text(count).font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary).monospacedDigit()
                }
                Spacer(minLength: AOMSpace.xs)
                accessory
            }
            if showsRule { AOMDivider() }
        }
    }
}

// MARK: - Notice

/// A problem that needs the user, with its fix next to it. Only shown when
/// something is wrong; a healthy state shows nothing.
struct AOMNotice<Actions: View>: View {
    enum Tone { case warning, error, info }
    let tone: Tone
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    init(_ tone: Tone, _ title: String, detail: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    private var tint: Color {
        switch tone {
        case .warning: return AOMTheme.warning
        case .error: return AOMTheme.danger
        case .info: return AOMTheme.blue
        }
    }

    private var symbol: String {
        switch tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.s) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AOMType.bodyEmphasis).foregroundStyle(AOMTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: AOMSpace.xs) { actions }
                .fixedSize()
        }
        .padding(.horizontal, AOMSpace.s)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Run status

/// The outcome of the last manual run, shown next to the button that ran it.
enum AOMRunState: Equatable {
    case idle
    case running
    case succeeded(Date)
    case failed(Date)
}

struct AOMRunStatusView: View {
    let state: AOMRunState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(AOMTheme.textSecondary)
                }
            case .succeeded(let date):
                Label("Ran \(AOMRelativeTime.string(date, now: context.date).lowercased())", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AOMTheme.positive)
            case .failed(let date):
                Label("Failed or stopped \(AOMRelativeTime.string(date, now: context.date).lowercased())",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(AOMTheme.danger)
            }
        }
        .font(AOMType.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shortcut text

/// A shortcut as separate key caps (⌥ P), for places where the trigger is
/// the thing being read.
struct AOMShortcutKeys: View {
    let shortcut: KeyboardShortcut
    /// Renders the caps white-on-transparent so they read inside a selected
    /// list row; plain key caps keep the chip look everywhere else.
    var onSelection = false

    var body: some View {
        let display = shortcut.displayString
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(display).enumerated()), id: \.offset) { _, part in
                AOMKeycap(text: part, onSelection: onSelection)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display)
    }

    /// Splits "⌃⌥P" into ["⌃", "⌥", "P"]; multi-letter keys stay whole.
    static func parts(_ display: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var result: [String] = []
        var rest = Substring(display)
        while let first = rest.first, modifiers.contains(first) {
            result.append(String(first))
            rest = rest.dropFirst()
        }
        if rest.hasPrefix("fn") {
            result.append("fn")
            rest = rest.dropFirst(2)
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }
}

// MARK: - Pane

extension View {
    /// The content pane background (white / dark grey), edge to edge.
    func aomPane() -> some View {
        background(AOMTheme.pane)
    }
}
