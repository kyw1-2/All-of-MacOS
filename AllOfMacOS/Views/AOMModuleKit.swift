import AppKit
import SwiftUI
import UniformTypeIdentifiers

// AOM 3.4 module kit (docs/design-3.4.0.md b.3–b.7): the shared pieces the
// list + detail pages (Folder Rules, Text Actions, Files, Focus) and every
// other page compose, so a rule editor, a token field, a folder row, a big
// status header and a live log look and behave the same everywhere.
//
//   AOMListDetail          list column · resizable divider · detail · optional inspector
//   AOMListColumn          a list column: header (search/filter), rows, + − footer bar
//   AOMAddRemoveBar        the + − (and ⋯) bar under a list (System Settings, Hazel)
//   AOMInspector           trailing inspector content: titled groups split by hairlines
//   AOMConditionRow        one rule condition: subject pop-ups, value, − +
//   AOMConditionGroupHeader "If [all ▾] of the following are true"
//   AOMTokenField / AOMTokenPill   tokens (extensions, app names, words) as removable pills
//   AOMPathRow             a folder or file: Finder icon, name, path, Choose…, drop target
//   AOMStatusHeader        a module's big live figure (timer, count) with ring and actions
//   AOMProgressRing        determinate ring, Reduce Motion aware
//   AOMLogRow / AOMLogSection  live activity rows, newest first, with an empty state
//   AOMProgressRow         a determinate task with label, value and Cancel
//   AOMInlineEmpty         a one-line empty state inside a card
//   AOMTipCard             a dismissible inline tip (instead of TipKit, b.6)
//   AOMHUDContent          the content of a floating HUD (mic mute, focus start)
//   AOMIconButton          a 28 pt borderless symbol button with tooltip and label
//   AOMFlowLayout          wraps chips and tokens onto new lines
//   AOMUndo                one-call undo registration with redo
//   aomHoverHighlight / aomFocusRing / aomDropTarget   the interaction layer (b.4)

// MARK: - Interaction layer

extension View {
    /// The quiet hover fill for a custom row or cell (lists, cards). Buttons
    /// get this from `AOMRowButtonStyle`; use this on non-button rows that
    /// still select or open on click.
    func aomHoverHighlight(radius: CGFloat = AOMRadius.well, enabled: Bool = true) -> some View {
        modifier(AOMHoverHighlight(radius: radius, enabled: enabled))
    }

    /// The keyboard focus ring for a custom focusable view, in the system
    /// focus colour, concentric with the view's corners.
    func aomFocusRing(_ isFocused: Bool, radius: CGFloat = AOMRadius.card) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AOMColor.focusRing, lineWidth: 3)
                    .padding(-2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The drop-target look: an accent wash under a 2 pt accent ring while a
    /// drag hovers over the view (HIG Drag and drop: show whether a
    /// destination can accept the content).
    func aomDropTarget(_ isTargeted: Bool, radius: CGFloat = AOMRadius.card) -> some View {
        overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AOMColor.dropWash)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(AOMColor.accent, lineWidth: 2)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .aomAnimation(.quick, value: isTargeted)
    }
}

private struct AOMHoverHighlight: ViewModifier {
    let radius: CGFloat
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering && enabled ? AOMColor.rowHover : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
    }
}

/// A borderless symbol button with a 28 pt hit area, a tooltip and a
/// VoiceOver label (HIG Buttons, Toolbars: symbols with `.help`).
struct AOMIconButton: View {
    let symbol: String
    let label: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ symbol: String, label: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(AOMFont.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(role == .destructive ? AOMColor.dangerText
                                                      : (hovering && isEnabled ? AOMColor.text : AOMColor.textSecondary))
                .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                .background(hovering && isEnabled ? AOMColor.rowHover : .clear,
                            in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Flow layout

/// Lays chips and tokens out left to right and wraps onto new lines.
struct AOMFlowLayout: Layout {
    var spacing: CGFloat = AOMSpace.x1
    var lineSpacing: CGFloat = AOMSpace.x1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - List + detail + inspector

/// The template for rule and editor pages (design-3.4.0 b.3): a list column
/// on the leading side, a resizable hairline, the detail for the selection,
/// and an optional trailing inspector (the system inspector column, toggled
/// with a toolbar button or ⌥⌘I). The list width is the caller's
/// `@AppStorage("AOM<Module>ListWidth")` so it survives relaunch.
///
///     AOMListDetail(listWidth: $listWidth, showsInspector: $inspector) {
///         AOMListColumn(…) { List(selection: $selection) { … } }
///     } detail: {
///         RuleDetail(rule)
///     } inspector: {
///         AOMInspector { AOMInspectorSection("Preview") { … } }
///     }
struct AOMListDetail<ListContent: View, Detail: View, InspectorContent: View>: View {
    @Binding var listWidth: Double
    var showsInspector: Binding<Bool>?
    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: Detail
    @ViewBuilder var inspector: InspectorContent

    init(listWidth: Binding<Double>, showsInspector: Binding<Bool>? = nil,
         @ViewBuilder list: () -> ListContent,
         @ViewBuilder detail: () -> Detail,
         @ViewBuilder inspector: () -> InspectorContent = { EmptyView() }) {
        self._listWidth = listWidth
        self.showsInspector = showsInspector
        self.list = list()
        self.detail = detail()
        self.inspector = inspector()
    }

    var body: some View {
        // The system inspector only when a page passes one: an always-attached
        // `.inspector(isPresented: false)` inset the first row under the
        // toolbar and blurred it (B, C and D's pages, 3.4.0).
        if let showsInspector {
            columns
                .inspector(isPresented: showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: AOMSize.inspectorWidth.lowerBound, ideal: AOMSize.inspectorIdeal,
                                              max: AOMSize.inspectorWidth.upperBound)
                }
        } else {
            columns
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            list
                .frame(width: CGFloat(min(AOMSize.moduleListRange.upperBound,
                                          max(AOMSize.moduleListRange.lowerBound, listWidth))))
                .frame(maxHeight: .infinity)
            AOMResizeDivider(width: $listWidth, range: AOMSize.moduleListRange, paneEdge: .leading)
            detail
                .frame(minWidth: AOMSize.detailMinimum, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AOMColor.pageBackground)
    }
}

/// A list column: an optional header (search field, scope bar), the rows
/// (usually a `List` with selection, which brings type-to-select, arrow keys
/// and the system selection), and the + − footer.
struct AOMListColumn<Header: View, Rows: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows
    @ViewBuilder var footer: Footer

    init(@ViewBuilder header: () -> Header = { EmptyView() },
         @ViewBuilder rows: () -> Rows,
         @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.header = header()
        self.rows = rows()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AOMSpace.x3)
                .padding(.top, AOMSpace.x3)
                .padding(.bottom, AOMSpace.x2)
            rows
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxHeight: .infinity)
    }
}

/// The + − bar under a list (System Settings, Hazel, Mail rules): Add, Remove
/// (disabled with nothing selected) and an optional ⋯ pull-down for the
/// rarer commands (Duplicate, Import…). Each one has a tooltip.
struct AOMAddRemoveBar<More: View>: View {
    var addLabel: String
    var add: () -> Void
    var removeLabel: String
    var remove: (() -> Void)?
    @ViewBuilder var more: More

    init(addLabel: String = "Add", add: @escaping () -> Void,
         removeLabel: String = "Remove", remove: (() -> Void)?,
         @ViewBuilder more: () -> More = { EmptyView() }) {
        self.addLabel = addLabel
        self.add = add
        self.removeLabel = removeLabel
        self.remove = remove
        self.more = more()
    }

    var body: some View {
        VStack(spacing: 0) {
            AOMDivider()
            HStack(spacing: AOMSpace.x0_5) {
                AOMIconButton("plus", label: addLabel, action: add)
                AOMIconButton("minus", label: removeLabel) { remove?() }
                    .disabled(remove == nil)
                if !(More.self == EmptyView.self) {
                    Menu {
                        more
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(AOMFont.body.weight(.medium))
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                    .help("More")
                    .accessibilityLabel("More")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x1)
            .padding(.vertical, AOMSpace.x0_5)
        }
    }
}

/// Inspector content (Xcode, Shortcuts, Keynote): no cards, titled groups
/// split by hairlines, 16 pt padding, controls at small size.
struct AOMInspector<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .background(AOMColor.pageBackground)
    }
}

/// One group in an `AOMInspector`.
struct AOMInspectorSection<Content: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder var content: Content

    init(_ title: String, showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text(title)
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(AOMSpace.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if showsDivider { AOMDivider() } }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Rule builder

/// How the conditions of a group combine.
enum AOMConditionMatch: String, CaseIterable, Identifiable, Codable {
    case all, any, none
    var id: String { rawValue }
    /// The word inside "If [all] of the following are true".
    var title: String {
        switch self {
        case .all: return "all"
        case .any: return "any"
        case .none: return "none"
        }
    }
}

/// "If [all ▾] of the following are true": the sentence that heads a rule's
/// conditions (Hazel, Mail rules, Finder smart folders).
struct AOMConditionGroupHeader: View {
    @Binding var match: AOMConditionMatch
    var prefix = "If"
    var suffix = "of the following are true"
    var depth = 0

    var body: some View {
        HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Text(prefix)
            Picker(prefix, selection: $match) {
                ForEach(AOMConditionMatch.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text(suffix)
            Spacer(minLength: 0)
        }
        .font(AOMFont.body)
        .foregroundStyle(AOMColor.text)
        .padding(.leading, AOMSpace.rowInset + CGFloat(depth) * AOMSpace.x5)
        .padding(.trailing, AOMSpace.rowInset)
        .frame(minHeight: AOMSize.rowStandard)
        .accessibilityElement(children: .contain)
    }
}

/// One condition or action row of a rule (Hazel's editor): the subject
/// pop-ups (attribute, operator) at their natural width, the value filling
/// the rest, then − and +. 36 pt, a hairline above, indented per nesting
/// level. Remove is disabled for the last row instead of hidden, so rows
/// never jump.
struct AOMConditionRow<Subject: View, Value: View>: View {
    var depth = 0
    var canRemove = true
    var showsDivider = true
    var addLabel = "Add Condition"
    var removeLabel = "Remove Condition"
    let add: () -> Void
    let remove: () -> Void
    @ViewBuilder var subject: Subject
    @ViewBuilder var value: Value

    init(depth: Int = 0, canRemove: Bool = true, showsDivider: Bool = true,
         addLabel: String = "Add Condition", removeLabel: String = "Remove Condition",
         add: @escaping () -> Void, remove: @escaping () -> Void,
         @ViewBuilder subject: () -> Subject, @ViewBuilder value: () -> Value) {
        self.depth = depth
        self.canRemove = canRemove
        self.showsDivider = showsDivider
        self.addLabel = addLabel
        self.removeLabel = removeLabel
        self.add = add
        self.remove = remove
        self.subject = subject()
        self.value = value()
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            subject
                .labelsHidden()
                .fixedSize()
            value
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                AOMIconButton("minus.circle", label: removeLabel, action: remove)
                    .disabled(!canRemove)
                AOMIconButton("plus.circle", label: addLabel, action: add)
            }
        }
        .padding(.leading, AOMSpace.rowInset + CGFloat(depth) * AOMSpace.x5)
        .padding(.trailing, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowStandard)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowInset + CGFloat(depth) * AOMSpace.x5) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tokens

/// One token: a capsule with its label and a remove button (×). Context menu:
/// Copy and Remove (HIG Token fields: add value with a context menu).
struct AOMTokenPill: View {
    let text: String
    var symbol: String?
    var tint: Color?
    var onRemove: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoveringRemove = false

    init(_ text: String, symbol: String? = nil, tint: Color? = nil, onRemove: (() -> Void)? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.onRemove = onRemove
    }

    var body: some View {
        let fill = tint ?? AOMColor.accent
        HStack(spacing: AOMSpace.x1) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            }
            Text(text).lineLimit(1).truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .font(AOMFont.token.weight(.bold))
                        .opacity(hoveringRemove ? 1 : 0.65)
                        .frame(width: AOMIcon.dot * 2 + AOMSpace.x0_5, height: AOMIcon.dot * 2 + AOMSpace.x0_5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringRemove = $0 }
                .help("Remove \(text)")
                .accessibilityLabel("Remove \(text)")
            }
        }
        .font(AOMFont.token.weight(.medium))
        .foregroundStyle(AOMColor.text)
        .padding(.leading, AOMSpace.x2)
        .padding(.trailing, onRemove == nil ? AOMSpace.x2 : AOMSpace.x1)
        .frame(height: AOMSize.tokenHeight)
        .background(fill.opacity(contrast == .increased ? 0.28 : 0.16), in: Capsule())
        .overlay { if contrast == .increased { Capsule().strokeBorder(fill, lineWidth: 1) } }
        .fixedSize()
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if let onRemove { Button("Remove", role: .destructive, action: onRemove) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }
}

/// A token field (Mail's address field, Finder tags): existing tokens as
/// pills, then a plain text field. Return, Tab or a comma turns the typed
/// text into a token; Delete in an empty field removes the last token.
/// `normalize` cleans or rejects a token (return nil to reject), so a module
/// can lower-case extensions or check app names. Suggestions show in a
/// trailing pull-down.
struct AOMTokenField: View {
    @Binding var tokens: [String]
    var placeholder: String
    var suggestions: [String] = []
    var symbol: ((String) -> String?)?
    var normalize: ((String) -> String?)?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(tokens: Binding<[String]>, placeholder: String, suggestions: [String] = [],
         symbol: ((String) -> String?)? = nil, normalize: ((String) -> String?)? = nil) {
        self._tokens = tokens
        self.placeholder = placeholder
        self.suggestions = suggestions
        self.symbol = symbol
        self.normalize = normalize
    }

    private var openSuggestions: [String] {
        let typed = draft.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions.filter { candidate in
            !tokens.contains(candidate) && (typed.isEmpty || candidate.lowercased().contains(typed))
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
        HStack(alignment: .top, spacing: AOMSpace.x1) {
            AOMFlowLayout(spacing: AOMSpace.x1, lineSpacing: AOMSpace.x1) {
                ForEach(tokens, id: \.self) { token in
                    AOMTokenPill(token, symbol: symbol?(token)) { remove(token) }
                }
                TextField(tokens.isEmpty ? placeholder : "", text: $draft)
                    .textFieldStyle(.plain)
                    .font(AOMFont.body)
                    .focused($focused)
                    .frame(minWidth: 96)
                    .frame(height: AOMSize.tokenHeight)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, value in
                        if value.contains(",") { commit() }
                    }
                    .onKeyPress(.delete) {
                        guard draft.isEmpty, let last = tokens.last else { return .ignored }
                        remove(last)
                        return .handled
                    }
                    .accessibilityLabel(placeholder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !openSuggestions.isEmpty {
                Menu {
                    ForEach(openSuggestions.prefix(20), id: \.self) { suggestion in
                        Button(suggestion) { add(suggestion) }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .foregroundStyle(AOMColor.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(height: AOMSize.tokenHeight)
                .help("Suggestions")
                .accessibilityLabel("Suggestions")
            }
        }
        .padding(.horizontal, AOMSpace.x1 + AOMSpace.x0_5)
        .padding(.vertical, AOMSpace.x0_5 + 1)
        .frame(minHeight: AOMSize.tokenFieldMinHeight)
        .background(AOMColor.field, in: shape)
        .overlay {
            shape.strokeBorder(focused ? AOMColor.focusRing
                                       : (contrast == .increased ? AOMColor.strongLine : AOMColor.hairline),
                               lineWidth: focused ? 2 : (contrast == .increased ? 1 : 0.5))
        }
        // Clicks on the empty part of the well focus the text field; tokens
        // and the field itself keep their own clicks.
        .background { shape.fill(Color.clear).contentShape(shape).onTapGesture { focused = true } }
        .accessibilityElement(children: .contain)
    }

    private func commit() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        draft = ""
        for part in parts where !part.isEmpty { add(part) }
    }

    private func add(_ raw: String) {
        let cleaned: String?
        if let normalize { cleaned = normalize(raw) } else { cleaned = raw }
        guard let token = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, !tokens.contains(token) else { return }
        tokens.append(token)
    }

    private func remove(_ token: String) {
        tokens.removeAll { $0 == token }
    }
}

// MARK: - Status header

/// A determinate ring (Activity rings, Screen Time limits, Flighty's
/// progress): the track in the hue at 18%, the progress in the hue, round
/// caps. Changes animate with the standard curve, or crossfade under Reduce
/// Motion.
struct AOMProgressRing: View {
    let progress: Double
    var tint: Color = AOMColor.accent
    var lineWidth: CGFloat = AOMSpace.x1 + 1
    var label: String = "Progress"

    var body: some View {
        let clamped = min(1, max(0, progress))
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .aomAnimation(.standard, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}

/// The large live header of a module page (a Focus session, today's tidied
/// files): the squircle inside an optional progress ring, a title, the one
/// big figure in Display (26 pt, monospaced digits, numeric transition) with
/// its unit, a detail line, an optional status pill, and the actions at
/// large size on the trailing edge. It sits on the canvas, never in a card.
struct AOMStatusHeader<Actions: View>: View {
    let module: AOMModule
    var active = true
    let title: String
    let figure: String
    var unit: String?
    var detail: String?
    var status: AOMStatus?
    var progress: Double?
    @ViewBuilder var actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ module: AOMModule, active: Bool = true, title: String, figure: String, unit: String? = nil,
         detail: String? = nil, status: AOMStatus? = nil, progress: Double? = nil,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.module = module
        self.active = active
        self.title = title
        self.figure = figure
        self.unit = unit
        self.detail = detail
        self.status = status
        self.progress = progress
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.x4) {
            // The ring only while something is in progress (a Focus
            // session); otherwise the big figure stands alone.
            if let progress {
                ZStack {
                    AOMProgressRing(progress: progress, tint: active ? module.hue : AOMColor.paused,
                                    label: "\(title) progress")
                    Image(systemName: module.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(active ? AOMColor.text : AOMColor.textTertiary)
                        .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
                        .accessibilityHidden(true)
                }
                .frame(width: AOMIcon.statusRing, height: AOMIcon.statusRing)
            }
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(spacing: AOMSpace.x2) {
                    Text(title)
                        .font(AOMFont.headline)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                    if let status { AOMStatusPill(status.text, tone: status.tone, symbol: status.symbol) }
                }
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    Text(figure)
                        .font(AOMFont.display)
                        .foregroundStyle(active ? AOMColor.text : AOMColor.textSecondary)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .lineLimit(1)
                    if let unit {
                        Text(unit)
                            .font(AOMFont.body)
                            .foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: AOMSpace.x3)
            HStack(spacing: AOMSpace.x2) { actions }
                .controlSize(.large)
                .fixedSize()
        }
        .frame(minHeight: progress == nil ? nil : AOMIcon.statusRing + AOMSpace.x2)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Live log

/// One entry of a module's live log.
struct AOMLogEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    var tone: AOMTone
    var message: String
    var detail: String?
    /// The file, app or rule it came from ("Invoice.pdf", "Safari").
    var source: String?

    init(id: UUID = UUID(), date: Date = Date(), tone: AOMTone = .success, message: String,
         detail: String? = nil, source: String? = nil) {
        self.id = id
        self.date = date
        self.tone = tone
        self.message = message
        self.detail = detail
        self.source = source
    }
}

/// One live log row (Console, Hazel's log, Xcode's report navigator): tone
/// glyph, time stamp in monospaced digits, the message in Body, an optional
/// detail line and source, and one trailing action (Undo, Show in Finder).
struct AOMLogRow<Trailing: View>: View {
    let entry: AOMLogEntry
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    init(_ entry: AOMLogEntry, showsDivider: Bool = true, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.entry = entry
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Image(systemName: entry.tone.symbol)
                .imageScale(.small)
                .foregroundStyle(entry.tone.color)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(AOMFont.callout)
                        .foregroundStyle(entry.tone == .danger ? AOMColor.dangerText : AOMColor.textSecondary)
                        .lineLimit(2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            if let source = entry.source {
                Text(source)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AOMRelativeTime.string(entry.date, now: context.date))
                    .font(AOMFont.timestamp)
                    .foregroundStyle(AOMColor.textTertiary)
                    .lineLimit(1)
                    .help(entry.date.formatted(date: .abbreviated, time: .standard))
            }
            trailing
                .controlSize(.small)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.logRow)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) } }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString([entry.message, entry.detail, entry.source].compactMap { $0 }
                    .joined(separator: " — "), forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled card of live log rows, newest first: at most `limit` rows with
/// Show All, a Clear button, and the inline empty state while there is none.
/// New rows slide in from the top (a crossfade under Reduce Motion).
struct AOMLogSection<Trailing: View>: View {
    let title: String
    let entries: [AOMLogEntry]
    var limit = 6
    var emptySymbol = "list.bullet.rectangle"
    var emptyMessage = "Nothing has happened yet."
    var clear: (() -> Void)?
    let trailing: (AOMLogEntry) -> Trailing
    @State private var showsAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, entries: [AOMLogEntry], limit: Int = 6, emptySymbol: String = "list.bullet.rectangle",
         emptyMessage: String = "Nothing has happened yet.", clear: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping (AOMLogEntry) -> Trailing = { _ in EmptyView() }) {
        self.title = title
        self.entries = entries
        self.limit = limit
        self.emptySymbol = emptySymbol
        self.emptyMessage = emptyMessage
        self.clear = clear
        self.trailing = trailing
    }

    var body: some View {
        let visible = showsAll ? entries : Array(entries.prefix(limit))
        AOMSection(title, detail: entries.isEmpty ? nil : "\(entries.count)") {
            HStack(spacing: AOMSpace.x1) {
                if entries.count > limit {
                    AOMCardLink(showsAll ? "Show Less" : "Show All", symbol: showsAll ? "chevron.up" : "chevron.down") {
                        withAnimation(AOMMotion.standard) { showsAll.toggle() }
                    }
                }
                if let clear, !entries.isEmpty {
                    AOMCardLink("Clear", symbol: nil, action: clear)
                }
            }
        } content: {
            if entries.isEmpty {
                AOMInlineEmpty(symbol: emptySymbol, message: emptyMessage)
            } else {
                ForEach(visible) { entry in
                    AOMLogRow(entry) { trailing(entry) }
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .aomAnimation(.standard, value: entries.first?.id)
    }
}

// MARK: - Progress and empty states

/// A task in progress (HIG Progress indicators: determinate when the amount
/// is known): label, a bar, "3 of 12" and Cancel. `progress` nil shows the
/// indeterminate bar.
struct AOMProgressRow: View {
    let title: String
    var progress: Double?
    var detail: String?
    var cancel: (() -> Void)?
    var showsDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            HStack(spacing: AOMSpace.x2) {
                Text(title).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                Spacer(minLength: AOMSpace.x2)
                if let detail {
                    Text(detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).monospacedDigit().lineLimit(1)
                }
                if let cancel {
                    Button("Cancel", action: cancel).controlSize(.small)
                }
            }
            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider() } }
        .accessibilityElement(children: .combine)
    }
}

/// A one-line empty state inside a card (design-3.4.0 b.5): a 20 pt
/// hierarchical glyph, one sentence in Body secondary and at most one button,
/// in a 48 pt row. A whole empty page uses `AOMEmptyState` instead.
struct AOMInlineEmpty: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(symbol: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol)
                .font(AOMFont.body)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AOMColor.textTertiary)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            Text(message)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AOMSpace.x2)
            if let actionTitle, let action {
                Button(actionTitle, action: action).fixedSize()
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMSize.rowDetail)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tips

/// A dismissible inline tip (HIG Offering help: short, actionable, shown in
/// context). Dismissal is remembered under `AOMTipDismissed.<id>`, which
/// Reset Preferences clears. AOM does not use TipKit: `Tips.configure()`
/// writes a shared datastore at launch, which isolated previews and unit
/// tests must not do (design-3.4.0 b.6).
struct AOMTipCard: View {
    let id: String
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @AppStorage private var dismissed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(id: String, symbol: String, title: String, message: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self._dismissed = AppStorage(wrappedValue: false, "AOMTipDismissed.\(id)")
    }

    var body: some View {
        if !dismissed {
            let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
            HStack(alignment: .top, spacing: AOMSpace.x3) {
                Image(systemName: symbol)
                    .font(AOMFont.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.accent)
                    .frame(width: AOMIcon.tileBadge)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    Text(title).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                    Text(message)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(.link)
                            .font(AOMFont.callout.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AOMIconButton("xmark", label: "Dismiss Tip") {
                    withAnimation(AOMMotion.standard) { dismissed = true }
                }
            }
            .padding(AOMSpace.x3)
            .background(AOMColor.surface, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(AOMColor.accent.opacity(0.8), lineWidth: 1) } }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tip: \(title)")
        }
    }
}

// MARK: - HUD

/// The content of a floating HUD (HIG Panels, HUD-style: small, brief, one
/// colour for state): a 40 pt glyph, the state in Headline and an optional
/// detail or level. Host it in a non-activating panel with
/// `.aomFloatingSurface(.hud)`; it never takes focus.
struct AOMHUDContent: View {
    let symbol: String
    let title: String
    var detail: String?
    var tone: AOMTone?
    var level: Double?

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol)
                .font(AOMFont.display)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone?.color ?? AOMColor.text)
                .frame(width: AOMIcon.hudGlyph, height: AOMIcon.hudGlyph)
                .accessibilityHidden(true)
            Text(title)
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if let level {
                ProgressView(value: min(1, max(0, level)))
                    .progressViewStyle(.linear)
                    .frame(width: AOMSize.quickActionMin)
            }
        }
        .padding(.horizontal, AOMSpace.x6)
        .padding(.vertical, AOMSpace.x4)
        .frame(minWidth: AOMSize.quickActionMin + AOMSpace.x8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Undo

/// One-call undo with redo (HIG Undo and redo: name the action, let people
/// undo several times). Uses the window's undo manager from
/// `@Environment(\.undoManager)`, so Edit › Undo “Hide Tile” and ⌘Z work.
@MainActor
enum AOMUndo {
    private final class Target {}
    private static let target = Target()

    /// Runs `perform`, then registers `revert` under `name` ("Hide Tile").
    /// Undo runs `revert` and registers `perform` as the redo, and so on.
    static func perform(_ name: String, undoManager: UndoManager?,
                        perform: @escaping @MainActor () -> Void, revert: @escaping @MainActor () -> Void) {
        perform()
        register(name, undoManager: undoManager, undo: revert, redo: perform)
    }

    private static func register(_ name: String, undoManager: UndoManager?,
                                 undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: target) { _ in
            MainActor.assumeIsolated {
                undo()
                register(name, undoManager: undoManager, undo: redo, redo: undo)
            }
        }
        undoManager.setActionName(name)
    }
}

// MARK: - Search tokens
