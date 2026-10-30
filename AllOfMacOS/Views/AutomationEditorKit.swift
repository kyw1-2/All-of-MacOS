import SwiftUI

// Automation editor kit (3.3.3 integration). The e.2 / e.3 patterns for the
// editors that sit inside a card on the Automation page (the When card, an
// action card, Options) and for the automation sheets, built only from
// AOMTokens and AOMComponents:
//
//   AOMEditorGroup   a titled group inside a card (e.2: never a card in a
//                    card): symbol, title, detail, ⓘ, optional disclosure,
//                    and a hairline above every group
//   AOMEditorNote    one line of scope or consequence, or a warning in its
//                    tone with a glyph; longer explanations go in an ⓘ
//   AOMRowValue      the value beside a slider or stepper (monospaced digits)
//   AOMRowStepper    a row control: the value, then the stepper
//   aomRowInset()    pads free content like a row inside a section card
//   AOMEditorSize    the few widths the automation editors and sheets need
//
// Rows themselves are `AOMSettingRow` / `AOMToggleRow` (one row style).

/// A titled group inside a card: the group title (Headline, sentence case)
/// with an optional monochrome symbol, a short detail, an ⓘ and a trailing
/// accessory, then the content. A hairline separates it from what is above.
/// Pass `rows: true` when the content is `AOMSettingRow`s (they inset
/// themselves); free content is inset to the rows' edge. With `isExpanded`
/// the title row discloses the content in place.
struct AOMEditorGroup<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var detail: String?
    var help: String?
    var rows: Bool
    var showsDivider: Bool
    var isExpanded: Binding<Bool>?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String? = nil, detail: String? = nil, help: String? = nil,
         rows: Bool = false, showsDivider: Bool = true, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.help = help
        self.rows = rows
        self.showsDivider = showsDivider
        self.isExpanded = isExpanded
        self.accessory = accessory()
        self.content = content()
    }

    private var expanded: Bool { isExpanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: rows ? 0 : AOMSpace.x2) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, rows ? 0 : AOMSpace.rowInset)
                    .padding(.bottom, rows ? AOMSpace.x1 : AOMSpace.x3)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: 0, trailingInset: 0) }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AOMSpace.x2) {
            if let symbol {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            if let help { AOMInfoButton(help, topic: title) }
            Spacer(minLength: AOMSpace.x2)
            accessory
            if let isExpanded {
                Button { toggle(isExpanded) } label: {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(AOMColor.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide \(title)" : "Show \(title)")
                .accessibilityLabel(title)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides the options" : "Shows the options")
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .frame(minHeight: AOMSize.rowStandard)
        .contentShape(Rectangle())
        .onTapGesture { if let isExpanded { toggle(isExpanded) } }
    }

    private func toggle(_ binding: Binding<Bool>) {
        withAnimation(AOMMotion.standard) { binding.wrappedValue.toggle() }
    }
}

/// One quiet line of scope or consequence under a control, or a warning in
/// its tone with the tone's glyph. Explanations longer than about two lines
/// belong in the group's or row's ⓘ instead (e.10: no caption walls).
struct AOMEditorNote: View {
    let text: String
    var tone: AOMTone?

    init(_ text: String, tone: AOMTone? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        if let tone {
            Label {
                Text(text).foregroundStyle(tone.textColor)
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(tone.color)
            }
            .font(AOMFont.caption)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The value beside a slider or stepper in a row.
struct AOMRowValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(AOMFont.body.monospacedDigit())
            .foregroundStyle(AOMColor.textSecondary)
            .lineLimit(1)
            .frame(minWidth: AOMEditorSize.valueLabel, alignment: .trailing)
    }
}

/// A row control: the current value as text, then the stepper. The stepper
/// keeps its title for VoiceOver and announces the value with it.
struct AOMRowStepper<Value: Strideable>: View {
    let title: String
    let display: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value.Stride

    init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride = 1,
         display: String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.display = display
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            AOMRowValue(display)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityValue(display)
        }
    }
}

extension View {
    /// Free content (a note, a text editor, a row of buttons) inside a
    /// section card, aligned with the `AOMSettingRow`s around it.
    func aomRowInset() -> some View {
        padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A multi-line `TextEditor` as a quiet well with a hairline, so it reads
    /// as a field inside a card (the editor has no bezel of its own).
    func aomTextWell(minHeight: CGFloat = AOMSpace.x12 + AOMSpace.x6) -> some View {
        scrollContentBackground(.hidden)
            .padding(AOMSpace.x1)
            .frame(minHeight: minHeight)
            .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                    .strokeBorder(AOMColor.hairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// Widths and sheet sizes the automation editors need. The spacing, type,
/// radius and colour scale stays in AOMTokens; these are layout extents with
/// no token there (candidates for `AOMSize` once AOMTokens is open again).
enum AOMEditorSize {
    /// The value beside a slider or stepper ("100 %", "16383", "0.25").
    static let valueLabel: CGFloat = AOMSpace.x12
    /// A slider inside a row.
    static let rowSlider: CGFloat = 160
    /// A text field inside a row.
    static let rowField: CGFloat = AOMSize.tileMin
    /// A number field inside a row (milliseconds, seconds, percent).
    static let numberField: CGFloat = AOMSpace.x10 * 2
    /// The new-trigger and edit-trigger sheets: the editor minimum, so a row
    /// keeps its label and control on one line.
    static let triggerSheet: CGFloat = AOMSize.editorMinimum + AOMSpace.x10
    /// The new-trigger sheet while it shows the drawing recorder.
    static let drawingSheet: CGFloat = 540
    /// The drawing recorder inside the new-trigger sheet.
    static let drawingComposer: CGFloat = 510
    /// The gesture list inside the trigger sheets.
    static let gestureList: CGFloat = 200
    /// The action picker sheet and its category column.
    /// 3.3.6: taller and wider for 13 pt rows (was 720 × 420).
    static let actionPicker = CGSize(width: 780, height: 480)
    static let actionPickerSidebar: CGFloat = AOMSize.sidebarMin
    /// The BetterTouchTool import report's minimum (the alert accessory is 640 × 420).
    static let importReport = CGSize(width: 560, height: 360)
    /// The activation groups sheet: minimum and ideal size; its list column.
    static let groupsEditorMinimum = CGSize(width: 720, height: 520)
    static let groupsEditorIdeal = CGSize(width: 780, height: 580)
    static let groupsList: CGFloat = AOMSize.sidebarIdeal
    /// The category menu beside the action library's search field.
    static let libraryCategory: CGFloat = 240
    /// The one-line gesture console.
    static let console: ClosedRange<CGFloat> = 350...550
}
