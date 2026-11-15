import AppKit
import Combine
import SwiftUI

/// The main window's pages. A page is built the first time it is selected
/// and then kept: switching back shows it again instead of rebuilding it.
///
/// Every visited page stays in one `ZStack` with a fixed identity (no `if`,
/// no changing `.id`), so its state survives. Each page gets its own
/// `AOMPageActivity` once; a page change flips two of those objects instead
/// of giving any page a new environment. The selected page is visible and
/// hit-testable; the others are hidden (`AOMPageHiding`), inert and keep the
/// size they last had while selected, so resizing the window lays out the
/// selected page only. Page order never changes (no `zIndex`): hidden pages
/// neither draw nor take clicks, and reordering re-inserts AppKit views.
struct AOMPageHost<Page: View>: View {
    @ObservedObject private var navigation = AOMNavigation.shared
    /// Pages in the order they were first selected.
    @State private var visited: [AOMMainTab] = []
    @State private var memory = AOMPageHostMemory()
    private let page: (AOMMainTab) -> Page

    init(@ViewBuilder page: @escaping (AOMMainTab) -> Page) {
        self.page = page
    }

    /// The visited pages after selecting `tab`: appended on its first
    /// selection, otherwise unchanged, so no page ever moves in the list.
    nonisolated static func visiting(_ tab: AOMMainTab, after visited: [AOMMainTab]) -> [AOMMainTab] {
        visited.contains(tab) ? visited : visited + [tab]
    }

    var body: some View {
        let selected = navigation.selected
        // The new page is in the list from the first render of the switch;
        // `visited` catches up in `onChange` with the same order.
        let pages = Self.visiting(selected, after: visited)
        GeometryReader { proxy in
            let live = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(pages, id: \.self) { tab in
                    let active = tab == selected
                    let size = active ? live : (memory.sizes[tab] ?? live)
                    // The same chain for every page; only the values differ.
                    page(tab)
                        .frame(width: size.width, height: size.height)
                        .environment(\.aomPageActivity, navigation.activity(for: tab))
                        .opacity(AOMPageHiding.current.opacity(active: active))
                        .offset(x: AOMPageHiding.current.offset(active: active))
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                }
            }
            .frame(width: live.width, height: live.height, alignment: .topLeading)
            .onChange(of: live, initial: true) { _, size in
                memory.live = size
                memory.sizes[navigation.selected] = size
            }
        }
        .background(AOMPageFocusProbe(memory: memory))
        .onChange(of: selected, initial: true) { _, tab in
            let next = Self.visiting(tab, after: visited)
            if next != visited { visited = next }
            navigation.createdPages.insert(tab)
            memory.sizes[tab] = memory.live
            memory.resignHiddenFocus()
        }
    }
}

/// How a page kept alive behind the selected one is hidden. Isolated previews
/// can compare them (`--aom-preview-hide opacity|offset`).
enum AOMPageHiding {
    /// Fully transparent in place.
    case opacity
    /// Opaque, moved out of the window by a transform on the page root.
    case offset

    static let current: AOMPageHiding = {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-hide"),
              args.indices.contains(index + 1), args[index + 1] == "offset" else { return .opacity }
        return .offset
    }()

    static let offscreenDistance: CGFloat = 100_000

    func opacity(active: Bool) -> Double { self == .opacity && !active ? 0 : 1 }
    func offset(active: Bool) -> CGFloat { self == .offset && !active ? Self.offscreenDistance : 0 }
}

/// What the host remembers without re-rendering: the live size, each page's
/// size when it was last selected, and the view that locates the host in
/// its window.
@MainActor
final class AOMPageHostMemory {
    var live: CGSize = .zero
    var sizes: [AOMMainTab: CGSize] = [:]
    weak var probe: NSView?

    /// A page that was hidden keeps no keyboard focus: typing, Delete and
    /// Escape must not reach a page you cannot see. Focus elsewhere (the
    /// sidebar, the toolbar, the diagnostics drawer) stays.
    func resignHiddenFocus() {
        guard let probe, let window = probe.window, let responder = window.firstResponder as? NSView else { return }
        // The detail column: the probe's ancestor that sits in the split view.
        var column: NSView? = probe
        while let view = column, !(view.superview is NSSplitView) { column = view.superview }
        guard let column, responder.isDescendant(of: column) else { return }
        var focused: NSView = responder
        if let editor = responder as? NSText, editor.isFieldEditor, let field = editor.delegate as? NSView {
            focused = field
        }
        let host = probe.convert(probe.bounds, to: nil)
        let rect = focused.convert(focused.bounds, to: nil)
        // SwiftUI's own focus sits on the hosting view, which covers the host.
        guard rect.contains(host) || host.contains(NSPoint(x: rect.midX, y: rect.midY)) else { return }
        window.makeFirstResponder(nil)
    }
}

private struct AOMPageFocusProbe: NSViewRepresentable {
    let memory: AOMPageHostMemory

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe(frame: .zero)
        memory.probe = view
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { memory.probe = view }
}

// MARK: - Page modifiers

// Every modifier here reads the page's `AOMPageActivity` from the
// environment (a reference that never changes for a page) and observes it in
// its own small modifier, so a page change re-renders these leaves, never the
// page body they are attached to.

extension View {
    /// The page's toolbar items, shown only while the page is selected. The
    /// condition sits inside the toolbar builder, so the page itself never
    /// changes identity.
    func aomPageToolbar<C: ToolbarContent>(@ToolbarContentBuilder _ content: () -> C) -> some View {
        let items = content()
        return modifier(AOMActivityReader { AOMPageToolbar(items: items, activity: $0) })
    }

    /// Work bounded by the page being selected: `onActivate` runs when the
    /// view appears on the selected page or its page becomes selected;
    /// `onDeactivate` when the page is hidden or the view disappears. With a
    /// `minimumInterval`, an activation that comes sooner than that after the
    /// last `onActivate` skips it (the values it refreshes are still fresh).
    func aomPageLifecycle(minimumInterval: TimeInterval = 0, onActivate: @escaping () -> Void,
                          onDeactivate: @escaping () -> Void = {}) -> some View {
        modifier(AOMActivityReader {
            AOMPageLifecycle(minimumInterval: minimumInterval, onActivate: onActivate,
                             onDeactivate: onDeactivate, activity: $0)
        })
    }

    /// `aomOnWindowVisibilityChange`, and also false while the page is
    /// hidden behind another one.
    func aomOnPageVisibilityChange(_ changed: @escaping (Bool) -> Void) -> some View {
        modifier(AOMActivityReader { AOMPageVisibility(changed: changed, activity: $0) })
    }

    /// A task that runs while its page is selected and its window is on
    /// screen, cancelled when either ends and started again on return.
    func aomVisibleTask(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(AOMVisiblePageTask(id: 0, action: action))
    }

    /// `aomVisibleTask`, also started again when `id` changes.
    func aomVisibleTask<ID: Equatable>(id: ID, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(AOMVisiblePageTask(id: id, action: action))
    }

    /// A key equivalent only the selected page claims: hidden pages stay in
    /// the window, and `allowsHitTesting(false)` does not stop shortcuts.
    func aomShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        aomShortcut(SwiftUI.KeyboardShortcut(key, modifiers: modifiers))
    }

    func aomShortcut(_ shortcut: SwiftUI.KeyboardShortcut) -> some View {
        modifier(AOMActivityReader { AOMPageShortcut(shortcut: shortcut, activity: $0) })
    }

    /// `focusedSceneValue` while the page is selected, nil while it is hidden.
    func aomPageFocusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T) -> some View {
        modifier(AOMActivityReader { AOMPageFocusedSceneValue(keyPath: keyPath, value: value, activity: $0) })
    }

    /// Edit ▸ Delete for the page, only while it is selected.
    func aomPageDeleteCommand(perform action: @escaping () -> Void) -> some View {
        modifier(AOMActivityReader { AOMPageDeleteCommand(action: action, activity: $0) })
    }

    /// A sheet driven by shared state (AppState) that only the selected page
    /// presents.
    func aomPageSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(AOMActivityReader { AOMPageSheet(isPresented: isPresented, sheet: content, activity: $0) })
    }
}

/// Hands the environment's activity object to a modifier that observes it.
private struct AOMActivityReader<Inner: ViewModifier>: ViewModifier {
    let inner: (AOMPageActivity) -> Inner
    @Environment(\.aomPageActivity) private var activity

    func body(content: Content) -> some View {
        content.modifier(inner(activity))
    }
}

private struct AOMPageToolbar<Items: ToolbarContent>: ViewModifier {
    let items: Items
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.toolbar {
            if activity.isActive { items }
        }
    }
}

private struct AOMPageShortcut: ViewModifier {
    let shortcut: SwiftUI.KeyboardShortcut
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.keyboardShortcut(activity.isActive ? shortcut : nil)
    }
}

private struct AOMPageFocusedSceneValue<T>: ViewModifier {
    let keyPath: WritableKeyPath<FocusedValues, T?>
    let value: T
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.focusedSceneValue(keyPath, activity.isActive ? value : nil)
    }
}

private struct AOMPageDeleteCommand: ViewModifier {
    let action: () -> Void
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.onDeleteCommand(perform: activity.isActive ? action : nil)
    }
}

private struct AOMPageSheet<Sheet: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let sheet: () -> Sheet
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { activity.isActive && isPresented.wrappedValue },
                                           set: { isPresented.wrappedValue = $0 }),
                      content: sheet)
    }
}

/// When a page last refreshed something, so selecting it again soon after
/// can skip a refresh whose values are still fresh. Plain storage: keep it in
/// `@State` and writing it never re-renders.
final class AOMRefreshClock {
    private(set) var last: Date?

    /// Seconds until a refresh every `interval` is due again (0 when due).
    func remaining(of interval: TimeInterval, now: Date = Date()) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    func mark(_ now: Date = Date()) { last = now }
}

/// Plain storage: reading it never re-renders.
private final class AOMPageActivityState {
    var onScreen = false
    var running = false
    var lastActivation: Date?
    var windowVisible = false
    var reported: Bool?
}

private struct AOMPageLifecycle: ViewModifier {
    let minimumInterval: TimeInterval
    let onActivate: () -> Void
    let onDeactivate: () -> Void
    @ObservedObject var activity: AOMPageActivity
    @State private var state = AOMPageActivityState()

    func body(content: Content) -> some View {
        content
            .onAppear { state.onScreen = true; update(activity.isActive) }
            .onDisappear { state.onScreen = false; update(activity.isActive) }
            .onChange(of: activity.isActive) { _, now in update(now) }
    }

    private func update(_ active: Bool) {
        let running = state.onScreen && active
        guard running != state.running else { return }
        state.running = running
        guard running else { onDeactivate(); return }
        let now = Date()
        if let last = state.lastActivation, now.timeIntervalSince(last) < minimumInterval { return }
        state.lastActivation = now
        onActivate()
    }
}

private struct AOMPageVisibility: ViewModifier {
    let changed: (Bool) -> Void
    @ObservedObject var activity: AOMPageActivity
    @State private var state = AOMPageActivityState()

    func body(content: Content) -> some View {
        content
            .aomOnWindowVisibilityChange { visible in
                state.windowVisible = visible
                report(activity.isActive)
            }
            .onChange(of: activity.isActive) { _, now in report(now) }
    }

    private func report(_ active: Bool) {
        let visible = active && state.windowVisible
        guard state.reported != visible else { return }
        state.reported = visible
        changed(visible)
    }
}

private struct AOMVisiblePageTask<ID: Equatable>: ViewModifier {
    let id: ID
    let action: @MainActor () async -> Void
    @State private var visible = false

    private struct Key: Equatable {
        let visible: Bool
        let id: ID
    }

    func body(content: Content) -> some View {
        content
            .aomOnPageVisibilityChange { visible = $0 }
            .task(id: Key(visible: visible, id: id)) {
                guard visible else { return }
                await action()
            }
    }
}

// MARK: - Observation

/// Shared models a page observes, forwarded only while the page is selected.
/// A page kept alive behind another one would otherwise re-render on every
/// change (Insights on every gesture detection, Capture on every recording
/// second); it re-renders once when selected again if anything changed.
@MainActor
final class AOMPageObservation: ObservableObject {
    private var subscriptions: [AnyCancellable] = []
    private var active = true
    private var missed = false

    init(_ sources: [AnyPublisher<Void, Never>]) {
        subscriptions = sources.map { source in
            source.sink { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.sourceWillChange() }
                } else {
                    DispatchQueue.main.async { self?.sourceWillChange() }
                }
            }
        }
    }

    private func sourceWillChange() {
        if active { objectWillChange.send() } else { missed = true }
    }

    private var following: (activity: AOMPageActivity, subscription: AnyCancellable)?

    /// Forwards while `activity` is active. The subscription is synchronous,
    /// so a page that missed changes re-renders in the same update that
    /// selects it, and no view observes the flag for this.
    func follow(_ activity: AOMPageActivity) {
        guard following?.activity !== activity else { return }
        following = (activity, activity.$isActive.sink { [weak self] active in
            MainActor.assumeIsolated { self?.setActive(active) }
        })
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value, missed {
            missed = false
            objectWillChange.send()
        }
    }
}

extension ObservableObject where ObjectWillChangePublisher.Failure == Never {
    /// Every change, as `AOMPageObservation` takes it.
    var aomChanges: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }
}

extension View {
    /// Keeps `observation` forwarding while this view's page is selected.
    func aomObserving(_ observation: AOMPageObservation) -> some View {
        modifier(AOMPageObserving(observation: observation))
    }
}

private struct AOMPageObserving: ViewModifier {
    let observation: AOMPageObservation
    @Environment(\.aomPageActivity) private var activity

    func body(content: Content) -> some View {
        content.onAppear { observation.follow(activity) }
    }
}

// MARK: - Timelines

/// `.periodic(from:by:)` that stops after its first entry while `paused`, so
/// a hidden page's clock does not redraw it; unpausing starts again from now.
struct AOMPageSchedule: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, interval: interval, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let interval: TimeInterval
        let paused: Bool

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            upcoming = paused ? nil : date.addingTimeInterval(interval)
            return date
        }
    }
}

extension TimelineSchedule where Self == AOMPageSchedule {
    static func aomPeriodic(by interval: TimeInterval, paused: Bool) -> AOMPageSchedule {
        AOMPageSchedule(interval: interval, paused: paused)
    }
}

/// `TimelineView(.periodic(from: .now, by: interval))` that pauses while its
/// page is hidden. Only this view observes the page's activity.
struct AOMPageTimeline<Content: View>: View {
    let interval: TimeInterval
    let content: (TimelineViewDefaultContext) -> Content
    @Environment(\.aomPageActivity) private var activity

    init(every interval: TimeInterval, @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {
        self.interval = interval
        self.content = content
    }

    var body: some View {
        AOMPageTimelineBody(interval: interval, content: content, activity: activity)
    }
}

private struct AOMPageTimelineBody<Content: View>: View {
    let interval: TimeInterval
    let content: (TimelineViewDefaultContext) -> Content
    @ObservedObject var activity: AOMPageActivity

    var body: some View {
        TimelineView(.aomPeriodic(by: interval, paused: !activity.isActive), content: content)
    }
}
