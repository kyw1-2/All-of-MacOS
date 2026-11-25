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

/// One key per module. The binding stores the user's preference, not the
/// temporary width a window can fit; AOMPaneWidth validates at the draw site.
struct AOMStoredInspectorWidth<Content: View>: View {
    @AppStorage private var width: Double
    private let content: (Binding<Double>) -> Content

    init(moduleID: String, @ViewBuilder content: @escaping (Binding<Double>) -> Content) {
        _width = AppStorage(wrappedValue: Double(AOMSize.inspectorIdeal), AOMPaneWidth.inspectorKey(moduleID: moduleID))
        self.content = content
    }

    var body: some View { content($width) }
}

extension AOMPaneWidth {
    static func inspectorKey(moduleID: String) -> String { "AOMInspectorWidth.\(moduleID)" }
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
        inspectorFits(available: available, list: list, detailMinimum: detailMinimum,
                             inspectorMinimum: inspectorMinimum, current: current,
                             hysteresis: hysteresis, dividerWidth: dividerAllowance)
    }

    static func inspectorFits(available: CGFloat, list: CGFloat, detailMinimum: CGFloat,
                              inspectorMinimum: CGFloat, current: Bool,
                              hysteresis: CGFloat = hysteresis, dividerWidth: CGFloat) -> Bool {
        guard available.isFinite, available > 0 else { return false }
        let room = inspectorRoom(available: available, list: list, detailMinimum: detailMinimum, dividerWidth: dividerWidth)
        return current ? room >= inspectorMinimum : room >= inspectorMinimum + hysteresis
    }

    /// The width left for an inspector beside the list and the detail minimum.
    static func inspectorRoom(available: CGFloat, list: CGFloat, detailMinimum: CGFloat) -> CGFloat {
        inspectorRoom(available: available, list: list, detailMinimum: detailMinimum, dividerWidth: dividerAllowance)
    }

    static func inspectorRoom(available: CGFloat, list: CGFloat, detailMinimum: CGFloat, dividerWidth: CGFloat) -> CGFloat {
        available - list - detailMinimum - 2 * dividerWidth
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
                                                    current: current == .listDetailInspector, dividerWidth: dividers)
        return fits ? .listDetailInspector : .listDetail
    }

    var showsInspectorBeside: Bool { self == .listDetailInspector }
}

/// Compact navigation is independent of the native list's selection and scroll.
struct AOMDrillInNavigation {
    private(set) var showsDetail = false
    private(set) var returnCount = 0

    mutating func openDetail() { showsDetail = true }
    mutating func selectionChanged(hasSelection: Bool) { showsDetail = hasSelection }
    mutating func goBack() {
        showsDetail = false
        returnCount &+= 1
    }
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

enum AOMHeaderContentID: Hashable {
    case pageTitle(AOMMainTab)
    case state(module: AOMMainTab, value: String)
    case summary(module: AOMMainTab, value: String)
}

enum AOMHeaderDedup {
    /// Suppress only an explicitly identified fact already shown elsewhere.
    static func visible(_ text: String?, id: AOMHeaderContentID?, alreadyShown: [AOMHeaderContentID]) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let id, alreadyShown.contains(id) { return nil }
        return text
    }

    /// Legacy callers have no semantic IDs. Keep their nonblank content.
    static func pill(title: String, status: String?) -> String? {
        visible(status, id: nil, alreadyShown: [])
    }

    static func subtitle(_ subtitle: String?, toolbarTitle: String, toolbarSubtitle: String?) -> String? {
        visible(subtitle, id: nil, alreadyShown: [])
    }
}

// MARK: - Inspector rows (D09)

/// Short read-only labels line up. Long labels and editable values stack,
/// leaving the full width for the label and the control.
struct AOMInspectorRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value
    private let readOnly: Bool

    /// Alignment target for short read-only labels, not a width limit.
    static var labelWidth: CGFloat { 96 }

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
        self.readOnly = false
    }

    var body: some View {
        AOMInspectorRowLayout(labelWidth: Self.labelWidth, readOnly: readOnly) {
            Text(label)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: AOMSpace.x1) { value }
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(AOMFont.callout)
        .accessibilityElement(children: readOnly ? .combine : .contain)
    }
}

extension AOMInspectorRow where Value == Text {
    /// A read-only value: selectable, monospaced digits for sizes and times.
    init(_ label: String, text: String) {
        self.label = label
        self.value = Text(text).monospacedDigit()
        self.readOnly = true
    }
}

struct AOMInspectorRowLayout: Layout {
    let labelWidth: CGFloat
    let readOnly: Bool

    private var gap: CGFloat { AOMSpace.x2 }

    func stacks(label: CGFloat, available: CGFloat) -> Bool {
        !readOnly || label > labelWidth || available < 2 * labelWidth + gap
    }

    private func measure(_ width: CGFloat, _ views: Subviews) -> (CGPoint, ProposedViewSize, ProposedViewSize, CGFloat) {
        let stacked = stacks(label: views[0].sizeThatFits(.unspecified).width, available: width)
        let labelProposal = ProposedViewSize(width: stacked ? width : labelWidth, height: nil)
        let valueProposal = ProposedViewSize(width: stacked ? width : max(0, width - labelWidth - gap), height: nil)
        let label = views[0].dimensions(in: labelProposal)
        let value = views[1].dimensions(in: valueProposal)
        if stacked {
            let y = label.height + AOMSpace.x1
            return (CGPoint(x: 0, y: y), labelProposal, valueProposal, y + value.height)
        }
        let baseline = max(label[.firstTextBaseline], value[.firstTextBaseline])
        let labelY = baseline - label[.firstTextBaseline]
        let valueY = baseline - value[.firstTextBaseline]
        return (CGPoint(x: labelY, y: valueY), labelProposal, valueProposal,
                max(labelY + label.height, valueY + value.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (max(labelWidth, subviews[0].sizeThatFits(.unspecified).width)
                                      + gap + subviews[1].sizeThatFits(.unspecified).width)
        return CGSize(width: width, height: measure(width, subviews).3)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (positions, label, value, _) = measure(bounds.width, subviews)
        let stacked = stacks(label: subviews[0].sizeThatFits(.unspecified).width, available: bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (stacked ? 0 : positions.x)),
                          anchor: .topLeading, proposal: label)
        subviews[1].place(at: CGPoint(x: bounds.minX + (stacked ? 0 : labelWidth + gap), y: bounds.minY + positions.y),
                          anchor: .topLeading, proposal: value)
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

/// A one-shot focus request bound to its original key window. A new request,
/// a losing key window, or a detached view must cancel the old request.
@MainActor
final class AOMDeferredWindowFocus {
    private var task: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?
    private var generation = 0

    func schedule(in window: NSWindow, delay: Duration = .zero, action: @escaping @MainActor () -> Void) {
        cancel()
        let token = generation
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        task = Task { [weak self, weak window] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.cancel()
            guard window?.isKeyWindow == true else { return }
            action()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// Put behind a row: when `token` changes (and isn't 0), the first focusable
/// AppKit control drawn inside the row becomes first responder, so a search
/// result opened with "Show in…" can be changed from the keyboard at once.
/// It doesn't take clicks and draws nothing.
struct AOMFocusFirstControl: NSViewRepresentable {
    enum Target { case control, list }

    let token: Int
    var target: Target = .control
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.update(token: isEnabled ? token : 0, target: target)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.cancel() }

    final class AnchorView: NSView {
        private var lastToken = 0
        private var target: Target = .control
        private var waitingForWindow = false
        private var focus = AOMDeferredWindowFocus()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(token: Int, target: Target) {
            guard token != lastToken || target != self.target else { return }
            cancel()
            lastToken = token
            self.target = target
            if token != 0 { schedule() }
        }

        func cancel() {
            waitingForWindow = false
            focus.cancel()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window != nil && newWindow !== window { cancel() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if waitingForWindow, window != nil { schedule() }
        }

        private func schedule() {
            guard let window else { waitingForWindow = true; return }
            waitingForWindow = false
            let token = lastToken
            focus.schedule(in: window, delay: target == .control ? .milliseconds(200) : .zero) { [weak self, weak window] in
                guard let self, let window, self.lastToken == token, self.window === window else { return }
                self.focusTarget(in: window)
            }
        }

        private func focusTarget(in window: NSWindow) {
            guard !isHiddenOrHasHiddenAncestor, let root = window.contentView else { return }
            let row = convert(visibleRect, to: nil)
            guard !row.isEmpty else { return }
            var candidates: [NSView] = []
            collect(in: root, row: row, into: &candidates)
            var frames = candidates.map { $0.convert($0.visibleRect, to: nil) }
            while let index = AOMRevealFocus.pick(frames, in: row) {
                if window.makeFirstResponder(candidates[index]) { return }
                candidates.remove(at: index)
                frames.remove(at: index)
            }
        }

        private func collect(in view: NSView, row: CGRect, into result: inout [NSView]) {
            for sub in view.subviews where sub !== self && !sub.isHidden && sub.alphaValue > 0 {
                let frame = sub.convert(sub.visibleRect, to: nil)
                guard frame.intersects(row) else { continue }
                if let control = sub as? NSControl, !control.isEnabled { continue }
                let eligible = target == .list ? (sub is NSTableView || sub is NSCollectionView) : !(sub is NSClipView)
                if eligible && (sub.acceptsFirstResponder || sub.canBecomeKeyView) {
                    result.append(sub)
                } else {
                    collect(in: sub, row: row, into: &result)
                }
            }
        }
    }
}

// MARK: - Automation editor status (D14)

/// A master preset write and the automation's runtime validity are independent.
enum AOMAutomationSaveState: Equatable {
    case unconfirmed
    case pending
    case saved
    case failed(String)
}

/// Whether the automation can run, regardless of the last write's outcome.
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

    func presentation(saveState: AOMAutomationSaveState) -> AOMStatus {
        switch saveState {
        case .unconfirmed:
            return AOMStatus(text, tone: tone, symbol: symbol)
        case .pending:
            return AOMStatus("Saving… · \(text)", tone: tone == .warning ? .warning : .neutral, symbol: "clock")
        case .saved:
            return AOMStatus("\(text) · Saved", tone: tone, symbol: symbol)
        case .failed(let reason):
            return AOMStatus("Couldn't save: \(reason) · \(text)", tone: .danger, symbol: AOMTone.danger.symbol)
        }
    }

    var text: String {
        switch self {
        case .ready: return "On"
        case .off: return "Off · won't run until turned on"
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
