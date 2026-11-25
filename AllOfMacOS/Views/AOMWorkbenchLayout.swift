import AppKit
import SwiftUI

// Native Workbench 2 (D02–D06, D09): the rules every list + detail
// (+ inspector) page shares, as plain functions so they can be tested
// without a window. Nothing here observes anything or runs a timer; a page
// calls them with the width it already measures.
//
// - A page decides its arrangement from the width it actually has (the
//   detail column less the sidebar), never from the whole window.
// - A stored pane width is a wish. It is checked when read (NaN, negative,
//   out of range) and shrunk to what fits, but only a drag ever writes it, so
//   widening the window again brings the user's width back.
// - A layout change never changes the selection. A selection that a search
//   or filter hides becomes no selection, never a different row, so a key or
//   button can't act on something the user didn't pick.

// MARK: - Pane widths (D04)

enum AOMPaneWidth {
    /// A stored width that is safe to lay out: NaN, infinite, zero or
    /// negative values fall back to `fallback`; anything else is clamped
    /// into `range`. (Old builds and hand-edited defaults wrote all of these.)
    static func sanitized(_ stored: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        let safeFallback = fallback.isFinite ? fallback : range.lowerBound
        let value = stored.isFinite && stored > 0 ? stored : safeFallback
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// The width a pane is drawn at: the sanitized stored width, reduced so
    /// `reserved` (the other panes' minimums and the dividers) still fits in
    /// `available`, and never below the range's minimum. With no measurement
    /// yet (`available` ≤ 0) it is the stored width.
    static func effective(stored: Double, range: ClosedRange<Double>, fallback: Double,
                          available: CGFloat, reserved: CGFloat) -> CGFloat {
        let wanted = CGFloat(sanitized(stored, range: range, fallback: fallback))
        guard available.isFinite, available > 0, reserved.isFinite else { return wanted }
        return max(CGFloat(range.lowerBound), min(wanted, available - reserved))
    }

    /// A drag's new width. It starts from the width on screen (which can be
    /// smaller than the stored one), so the divider follows the pointer from
    /// the first point instead of first "using up" the hidden difference, and
    /// stops at `maximum` (the room the window has) as well as the range.
    static func dragged(start: Double, delta: Double, range: ClosedRange<Double>, maximum: Double? = nil) -> Double {
        var upper = range.upperBound
        if let maximum, maximum.isFinite { upper = max(range.lowerBound, min(upper, maximum)) }
        let base = start.isFinite ? start : range.lowerBound
        let step = delta.isFinite ? delta : 0
        return min(upper, max(range.lowerBound, base + step))
    }
}

// MARK: - Arrangement (D02)

enum AOMWorkbenchPolicy {
    /// How far past a threshold the width has to go before a page switches
    /// arrangement, so a window resized across it doesn't flip back and forth
    /// (and rebuild its panes) on every point. 16–24 pt in the spec; 20 here.
    static let hysteresis: CGFloat = 20
    /// One resize divider in a row: the hairline and its padding.
    static let dividerAllowance: CGFloat = 2 * AOMSpace.x1

    /// List and detail side by side, or one at a time (drill-in). Leaving
    /// side by side happens below `minimum`; coming back needs `hysteresis`
    /// more, so the minimum is always honoured while side by side.
    static func sideBySide(available: CGFloat, minimum: CGFloat, current: Bool,
                           hysteresis: CGFloat = hysteresis) -> Bool {
        guard available.isFinite, available > 0 else { return current }
        return current ? available >= minimum : available >= minimum + hysteresis
    }

    /// Whether a trailing inspector fits beside the list (at `list`) and a
    /// detail at its minimum. It closes as soon as it would squeeze the
    /// detail and reopens only with `hysteresis` to spare.
    static func inspectorFits(available: CGFloat, list: CGFloat, detailMinimum: CGFloat,
                              inspectorMinimum: CGFloat, current: Bool,
                              hysteresis: CGFloat = hysteresis) -> Bool {
        guard available.isFinite, available > 0 else { return false }
        let room = available - list - detailMinimum - 2 * dividerAllowance
        return current ? room >= inspectorMinimum : room >= inspectorMinimum + hysteresis
    }

    /// The width left for an inspector beside the list and the detail minimum.
    static func inspectorRoom(available: CGFloat, list: CGFloat, detailMinimum: CGFloat) -> CGFloat {
        available - list - detailMinimum - 2 * dividerAllowance
    }
}

/// How a list + detail (+ inspector) page lays itself out.
enum AOMWorkbenchArrangement: Equatable {
    /// Too narrow for two panes: the list, or the detail with a Back button.
    case drillIn
    /// List and detail; an inspector that was asked for shows in the detail.
    case listDetail
    /// List, detail and inspector.
    case listDetailInspector

    /// One decision from the measured width, the panes' minimums and what is
    /// shown now (for hysteresis on both thresholds). `list` is the width the
    /// list is drawn at (its minimum when omitted): the inspector has to fit
    /// beside that, so widening the list by its divider can close it.
    static func resolve(available: CGFloat, listMinimum: CGFloat, detailMinimum: CGFloat,
                        inspectorMinimum: CGFloat, inspectorRequested: Bool,
                        current: AOMWorkbenchArrangement, list: CGFloat? = nil,
                        dividers: CGFloat = AOMWorkbenchPolicy.dividerAllowance) -> AOMWorkbenchArrangement {
        let twoPane = listMinimum + detailMinimum + dividers
        guard AOMWorkbenchPolicy.sideBySide(available: available, minimum: twoPane, current: current != .drillIn) else {
            return .drillIn
        }
        guard inspectorRequested else { return .listDetail }
        let fits = AOMWorkbenchPolicy.inspectorFits(available: available, list: max(listMinimum, list ?? listMinimum),
                                                    detailMinimum: detailMinimum,
                                                    inspectorMinimum: inspectorMinimum,
                                                    current: current == .listDetailInspector)
        return fits ? .listDetailInspector : .listDetail
    }

    var showsInspectorBeside: Bool { self == .listDetailInspector }
}

// MARK: - Selection (D03, D05)

enum AOMStableSelection {
    /// The selection after the visible rows changed. A selection that is
    /// still visible is kept as it is. Otherwise the first row is highlighted
    /// only when the caller allows it — no search or filter is narrowing the
    /// rows (first appearance, a scope or board the user switched to). While
    /// a search or filter is active, a selection that left the rows becomes
    /// `nil`: typing must never quietly move Return or ⌫ to another row.
    static func reconcile<ID: Equatable>(_ current: ID?, visible: [ID], autoSelectFirst: Bool) -> ID? {
        if let current, visible.contains(current) { return current }
        return autoSelectFirst ? visible.first : nil
    }

    /// The row an action (Return, a bar button, ⌫) may act on: the selected
    /// id, and only while it is one of the rows on screen. A row that was
    /// filtered out, deleted or replaced since the selection was made gives
    /// `nil`, so the action does nothing.
    static func actionTarget<ID: Equatable>(_ id: ID?, visible: [ID]) -> ID? {
        guard let id, visible.contains(id) else { return nil }
        return id
    }
}

// MARK: - Headers (D06)

enum AOMHeaderDedup {
    /// The status pill beside a header sentence, unless the sentence already
    /// says it ("Files is on" with an "On" pill says "on" twice).
    static func pill(title: String, status: String?) -> String? {
        guard let status = status?.trimmingCharacters(in: .whitespaces), !status.isEmpty else { return nil }
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let statusWords = status.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !statusWords.isEmpty else { return status }
        // Every word of the pill already in the sentence: drop the pill.
        return statusWords.allSatisfy(words.contains) ? nil : status
    }

    /// A header subtitle, unless it repeats the toolbar's title or subtitle
    /// for the same page (the window shows those already).
    static func subtitle(_ subtitle: String?, toolbarTitle: String, toolbarSubtitle: String?) -> String? {
        guard let subtitle else { return nil }
        let text = normalized(subtitle)
        guard !text.isEmpty, text != normalized(toolbarTitle) else { return nil }
        if let toolbarSubtitle, text == normalized(toolbarSubtitle) { return nil }
        return subtitle
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }
}

// MARK: - Inspector rows (D09)

/// One label/value line in an `AOMInspectorSection`: the label in secondary
/// text on a fixed leading column, the value (text or a control) after it, so
/// every inspector's values start on one vertical line. Long values wrap
/// under themselves, never under the label.
struct AOMInspectorRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    /// Labels end here; values start a divider gap later.
    static var labelWidth: CGFloat { 96 }

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Text(label)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .frame(width: Self.labelWidth, alignment: .leading)
            value
                .font(AOMFont.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension AOMInspectorRow where Value == Text {
    /// A read-only value: selectable, monospaced digits for sizes and times.
    init(_ label: String, text: String) {
        self.label = label
        self.value = Text(text).monospacedDigit()
    }
}

/// An "Advanced" group inside an inspector section, folded by default (D09).
struct AOMInspectorDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    init(_ title: String = "Advanced", isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AOMSpace.x2) { content }
                .padding(.top, AOMSpace.x1)
        } label: {
            Text(title).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
        }
    }
}

// MARK: - Focus after a reveal (D31)

enum AOMRevealFocus {
    /// Which of the controls found under a revealed row gets focus: the
    /// first one whose centre is inside the row, top to bottom then leading
    /// to trailing (window coordinates, y up). Nil when none is inside.
    static func pick(_ frames: [CGRect], in row: CGRect) -> Int? {
        frames.indices
            .filter { row.contains(CGPoint(x: frames[$0].midX, y: frames[$0].midY)) }
            .min { a, b in
                let fa = frames[a], fb = frames[b]
                if abs(fa.maxY - fb.maxY) > 1 { return fa.maxY > fb.maxY }
                return fa.minX < fb.minX
            }
    }
}

/// Put behind a row: when `token` changes (and isn't 0), the first focusable
/// AppKit control drawn inside the row becomes first responder, so a search
/// result opened with "Show in…" can be changed from the keyboard at once.
/// It doesn't take clicks and draws nothing.
struct AOMFocusFirstControl: NSViewRepresentable {
    let token: Int

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        guard token != view.lastToken else { return }
        view.lastToken = token
        guard token != 0 else { return }
        // After the scroll that brought the row into view has laid it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in view?.focusFirstControl() }
    }

    final class AnchorView: NSView {
        var lastToken = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func focusFirstControl() {
            guard let window, let root = window.contentView else { return }
            let row = convert(bounds, to: nil)
            var candidates: [NSView] = []
            collect(in: root, row: row, into: &candidates)
            let frames = candidates.map { $0.convert($0.bounds, to: nil) }
            guard let index = AOMRevealFocus.pick(frames, in: row) else { return }
            window.makeFirstResponder(candidates[index])
        }

        private func collect(in view: NSView, row: CGRect, into result: inout [NSView]) {
            for sub in view.subviews where sub !== self && !sub.isHidden && sub.alphaValue > 0 {
                let frame = sub.convert(sub.bounds, to: nil)
                guard frame.intersects(row) else { continue }
                if sub is NSControl, sub.acceptsFirstResponder || sub.canBecomeKeyView {
                    result.append(sub)
                } else {
                    collect(in: sub, row: row, into: &result)
                }
            }
        }
    }
}

// MARK: - Automation editor status (D14)

/// The one state line under an automation's name: whether it can run, and
/// why not. Edits apply as they are made, so "saved" is always true; what
/// varies is whether it will run.
enum AOMAutomationEditorStatus: Equatable {
    case ready
    case off
    case noSteps
    case invalidInput(String)
    case invalidSteps(String)

    static func resolve(isEnabled: Bool, stepCount: Int, inputProblem: String?, stepsProblem: String?) -> AOMAutomationEditorStatus {
        if let inputProblem { return .invalidInput(inputProblem) }
        if stepCount == 0 { return .noSteps }
        if let stepsProblem { return .invalidSteps(stepsProblem) }
        return isEnabled ? .ready : .off
    }

    var text: String {
        switch self {
        case .ready: return "On · changes are saved as you make them"
        case .off: return "Off · saved, won't run until turned on"
        case .noSteps: return "Add a step for this automation to do something"
        case .invalidInput(let problem): return "Can't start: \(problem)"
        case .invalidSteps(let problem): return "Can't run: \(problem)"
        }
    }

    var tone: AOMTone {
        switch self {
        case .ready: return .success
        case .off, .noSteps: return .neutral
        case .invalidInput, .invalidSteps: return .warning
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle"
        case .off: return "pause.circle"
        case .noSteps: return "plus.circle"
        case .invalidInput, .invalidSteps: return "exclamationmark.triangle"
        }
    }
}
