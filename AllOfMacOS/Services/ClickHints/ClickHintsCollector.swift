import ApplicationServices
import CoreGraphics

/// Reads an Accessibility tree for the collector. `ClickHintsLiveReader`
/// talks to the front app; tests read fixtures.
protocol ClickHintsTreeReader {
    associatedtype Node
    /// The element's attributes, or nil when it can't be read (gone, timed out).
    func attributes(of node: Node) -> ClickHintsAttributes?
    /// The children worth visiting: the visible rows of a table or outline,
    /// the visible children of a list, otherwise every child.
    func children(of node: Node, role: String) -> [Node]
    /// The element's actions (AXUIElementCopyActionNames).
    func actions(of node: Node) -> [String]
    /// Whether AXValue can be set: editable text inside a table row.
    func isValueSettable(_ node: Node) -> Bool
    /// The time budget is spent: stop and show what was found.
    var isExhausted: Bool { get }
    /// The live element (nil for fixtures).
    func element(of node: Node) -> AXUIElement?
    /// A number that names the node in tests (fixture id), or `index`.
    func identifier(of node: Node, index: Int) -> Int
}

/// What a walk found.
struct ClickHintsCollection {
    var targets: [ClickHintsTarget]
    /// Elements read.
    var visited: Int
    /// The walk stopped early (time budget or node cap).
    var truncated: Bool
}

/// One element waiting to be read during a walk.
struct ClickHintsPendingNode<Node> {
    let node: Node
    let depth: Int
    /// The visible area for this element (the window, cut by scroll areas).
    let clip: CGRect
    let insideRow: Bool
    /// The nearest target above it.
    let ancestor: Int?
}

/// Finds the actionable, visible, enabled elements of a window (or of the
/// menu bar or the Dock) and keeps one hint per target.
enum ClickHintsCollector {
    struct Limits {
        /// Elements read at most per walk (the time budget usually ends it first).
        var maxNodes = 6_000
        var maxDepth = 64
        /// Smaller visible parts get no hint (a 1 pt sliver at a scroll edge).
        var minimumSide: CGFloat = 4
        /// A nested target that covers at least this much of its ancestor is
        /// the same target: one hint ("a button inside a cell keeps one hint").
        var sameTargetCoverage: CGFloat = 0.5
        /// Two targets this alike (intersection over union) are one.
        var duplicateOverlap: CGFloat = 0.9
    }

    // MARK: Roles

    static let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXComboBoxRole, kAXSliderRole, kAXDisclosureTriangleRole, kAXIncrementorRole, kAXColorWellRole,
        kAXMenuBarItemRole, "AXLink", ClickHintsAX.dockItem
    ].reduce(into: Set<String>()) { $0.insert($1 as String) }

    static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String]

    /// Roles checked for AXPress, AXConfirm or AXPick. Static text is left
    /// out: web engines list AXPress on text inside anything clickable.
    static let pressableRoles: Set<String> = [
        kAXGroupRole as String, kAXImageRole as String, "AXGenericElement", kAXUnknownRole as String,
        kAXLayoutItemRole as String, "AXListItem"
    ]

    /// Roles whose children never hold a target.
    static let leafRoles: Set<String> = [
        kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXSplitterRole, kAXGrowAreaRole, kAXValueIndicatorRole,
        kAXBusyIndicatorRole, kAXProgressIndicatorRole, kAXLevelIndicatorRole, kAXRelevanceIndicatorRole,
        kAXRulerRole, kAXRulerMarkerRole, kAXHandleRole, kAXHelpTagRole, kAXMenuRole
    ].reduce(into: Set<String>()) { $0.insert($1 as String) }

    static let rowRole = kAXRowRole as String
    static let cellRole = kAXCellRole as String
    static let scrollAreaRole = kAXScrollAreaRole as String

    /// What kind of target an element is, or nil. `isSettable` and
    /// `actions` are asked lazily, only for the roles that need them.
    static func classify(_ attributes: ClickHintsAttributes, insideRow: Bool,
                         isSettable: () -> Bool, actions: () -> [String]) -> ClickHintsKind? {
        let role = attributes.role
        if role == ClickHintsAX.dockItem && attributes.subrole == ClickHintsAX.separatorDockItem { return nil }
        if controlRoles.contains(role) { return .control }
        if textRoles.contains(role) {
            // Never over password fields (design-340 b.17).
            if attributes.subrole == ClickHintsAX.secureTextField { return nil }
            // Text inside a row is the row's label unless it can be edited.
            if insideRow && !isSettable() { return nil }
            return .text
        }
        if role == rowRole { return .row }
        if role == cellRole { return insideRow ? nil : .row }
        if pressableRoles.contains(role) {
            let names = actions()
            return ClickHintsAX.activationActions.contains(where: names.contains) ? .pressable : nil
        }
        return nil
    }

    /// Controls and text fields are leaves: their parts (a combo box's
    /// button, a link's text) never get hints of their own.
    static func descends(into role: String, kind: ClickHintsKind?) -> Bool {
        if kind == .control || kind == .text { return false }
        return !leafRoles.contains(role)
    }

    // MARK: Walk

    /// Walks the tree under `root` depth first. `window` is the visible
    /// frame targets must be inside; `screens` are the displays (a target
    /// must be on one). Scroll areas clip their content.
    static func collect<R: ClickHintsTreeReader>(root: R.Node, reader: R, window: CGRect, screens: [CGRect],
                                                 tier: ClickHintsTier = .window,
                                                 limits: Limits = Limits()) -> ClickHintsCollection {
        typealias Pending = ClickHintsPendingNode<R.Node>
        var candidates: [ClickHintsTarget] = []
        var ancestors: [Int?] = []
        var stack = [Pending(node: root, depth: 0, clip: window, insideRow: false, ancestor: nil)]
        var visited = 0
        var truncated = false

        while let item = stack.popLast() {
            if reader.isExhausted || visited >= limits.maxNodes {
                truncated = true
                break
            }
            visited += 1
            guard let attributes = reader.attributes(of: item.node) else { continue }

            var visible: CGRect?
            if let frame = attributes.frame, isUsable(frame) {
                visible = visiblePart(of: frame, clip: item.clip, screens: screens)
                // An element wholly outside the visible area takes its subtree with it.
                if visible == nil { continue }
            }

            let node = item.node
            // Actions cost one request; read them once, only when the role needs them.
            var actions: [String]?
            let kind = classify(attributes, insideRow: item.insideRow,
                                isSettable: { reader.isValueSettable(node) },
                                actions: {
                                    if let actions { return actions }
                                    let names = reader.actions(of: node)
                                    actions = names
                                    return names
                                })
            var ancestorForChildren = item.ancestor
            if let kind, let frame = attributes.frame, let visible,
               visible.width >= limits.minimumSide, visible.height >= limits.minimumSide,
               attributes.enabled != false {
                candidates.append(ClickHintsTarget(element: reader.element(of: node), attributes: attributes, kind: kind,
                                                   tier: tier, frame: frame, visibleFrame: visible, actions: actions,
                                                   id: reader.identifier(of: node, index: visited)))
                ancestors.append(item.ancestor)
                ancestorForChildren = candidates.count - 1
            }

            guard item.depth < limits.maxDepth, descends(into: attributes.role, kind: kind) else { continue }
            let children = reader.children(of: node, role: attributes.role)
            guard !children.isEmpty else { continue }
            var clip = item.clip
            if attributes.role == scrollAreaRole, let frame = attributes.frame, isUsable(frame) {
                clip = clip.intersection(frame)
                if clip.isNull || clip.isEmpty { continue }
            }
            let insideRow = item.insideRow || attributes.role == rowRole
            for child in children.reversed() {
                stack.append(Pending(node: child, depth: item.depth + 1, clip: clip, insideRow: insideRow,
                                     ancestor: ancestorForChildren))
            }
        }
        let kept = deduplicate(candidates, ancestors: ancestors, limits: limits)
        return ClickHintsCollection(targets: kept, visited: visited, truncated: truncated)
    }

    // MARK: Geometry

    static func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    /// The part of `frame` inside `clip` on the screen that shows most of it;
    /// nil when none is visible.
    static func visiblePart(of frame: CGRect, clip: CGRect, screens: [CGRect]) -> CGRect? {
        let clipped = frame.intersection(clip)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        var best: CGRect?
        for screen in screens {
            let part = clipped.intersection(screen)
            guard !part.isNull, part.width > 0, part.height > 0 else { continue }
            if best.map({ $0.width * $0.height < part.width * part.height }) ?? true { best = part }
        }
        return best
    }

    private static func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }

    // MARK: One hint per target

    /// Drops nested targets that are the same target as an ancestor (the
    /// more specific kind stays; for equal kinds the inner one), then
    /// near-identical frames (the more specific kind, else the first).
    static func deduplicate(_ candidates: [ClickHintsTarget], ancestors: [Int?], limits: Limits) -> [ClickHintsTarget] {
        var dropped = [Bool](repeating: false, count: candidates.count)
        for index in candidates.indices {
            var next = ancestors[index]
            while let ancestor = next {
                defer { next = ancestors[ancestor] }
                guard !dropped[ancestor], !dropped[index] else { continue }
                let outer = candidates[ancestor].visibleFrame, inner = candidates[index].visibleFrame
                let overlap = area(outer.intersection(inner))
                guard area(outer) > 0, overlap / area(outer) >= limits.sameTargetCoverage else { continue }
                if candidates[index].kind <= candidates[ancestor].kind {
                    dropped[ancestor] = true
                } else {
                    dropped[index] = true
                }
            }
        }

        // Near-identical frames that are not nested (an image laid over its
        // button), bucketed by position so this stays linear in practice.
        var buckets: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }
        for index in candidates.indices where !dropped[index] {
            let frame = candidates[index].visibleFrame
            let bx = Int((frame.minX / 16).rounded(.down)), by = Int((frame.minY / 16).rounded(.down))
            var duplicateOf: Int?
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for other in buckets[key(bx + dx, by + dy)] ?? [] where !dropped[other] {
                        let a = candidates[other].visibleFrame
                        let union = area(a) + area(frame) - area(a.intersection(frame))
                        if union > 0, area(a.intersection(frame)) / union >= limits.duplicateOverlap {
                            duplicateOf = other
                            break search
                        }
                    }
                }
            }
            if let other = duplicateOf {
                if candidates[index].kind < candidates[other].kind {
                    dropped[other] = true
                } else {
                    dropped[index] = true
                    continue
                }
            }
            buckets[key(bx, by), default: []].append(index)
        }
        return candidates.indices.filter { !dropped[$0] }.map { candidates[$0] }
    }

    // MARK: Ranking

    /// Target indices, most likely first: window content before the menu
    /// bar and the Dock, then nearest to `reference` (the pointer when it is
    /// over the window, otherwise the window's top-left corner).
    static func rank(_ targets: [ClickHintsTarget], reference: CGPoint) -> [Int] {
        targets.indices.sorted { a, b in
            let ta = targets[a], tb = targets[b]
            if ta.tier != tb.tier { return ta.tier < tb.tier }
            let da = distance(ta.visibleFrame, reference), db = distance(tb.visibleFrame, reference)
            if abs(da - db) > 0.5 { return da < db }
            if ta.visibleFrame.minY != tb.visibleFrame.minY { return ta.visibleFrame.minY < tb.visibleFrame.minY }
            if ta.visibleFrame.minX != tb.visibleFrame.minX { return ta.visibleFrame.minX < tb.visibleFrame.minX }
            return a < b
        }
    }

    /// Distance from `point` to the nearest point of `rect` (0 inside).
    static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
