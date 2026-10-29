import CoreGraphics
import Foundation

// The annotation eraser (CleanShot eraser, audit CS-23 and parity "Annotation
// eraser"). Two modes:
//  - object: deletes every annotation object the eraser touches;
//  - stroke: cuts the touched parts out of pen and highlighter strokes and
//    leaves every other object alone.
// Hit-testing follows what is painted: the stroke band of lines, arrows,
// pen strokes and outlined shapes, the area of filled shapes, redactions,
// text, counters and image layers. One drag is one undo step (the editor
// passes `registersUndo` only for the first change of a drag).
//
// Compiled into the Quick Look extensions too (Models/Annotation*.swift).

enum AnnotationEraserMode: String, CaseIterable, Identifiable, Codable {
    case object, stroke

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: return "Object Eraser"
        case .stroke: return "Stroke Eraser"
        }
    }

    var help: String {
        switch self {
        case .object: return "Deletes every annotation the eraser touches"
        case .stroke: return "Erases only the touched parts of pen and highlighter strokes"
        }
    }
}

extension AnnotationObject {
    /// Start and end of a line or arrow (canvas space). 3.3.3 stores the drag
    /// direction in `points`; older objects run from the rect's top-left to
    /// its bottom-right, which is how they were always drawn.
    var lineEndpoints: (start: CGPoint, end: CGPoint) {
        if points.count == 2 { return (points[0], points[1]) }
        return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
    }

    /// The control point of a curved arrow's bow (canvas space), matching the renderer.
    var curvedArrowControl: CGPoint {
        let (start, end) = lineEndpoints
        return CGPoint(x: (start.x + end.x) / 2 + (end.y - start.y) * 0.28,
                       y: (start.y + end.y) / 2 - (end.x - start.x) * 0.28)
    }
}

enum AnnotationEraser {
    /// Default eraser radius, in points.
    static let defaultRadius: CGFloat = 8
    static let radiusRange: ClosedRange<CGFloat> = 2...60

    // MARK: Distances

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    static func distance(segment a: CGPoint, _ b: CGPoint, toSegment c: CGPoint, _ d: CGPoint) -> CGFloat {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(distance(from: a, toSegment: c, d), distance(from: b, toSegment: c, d),
                   distance(from: c, toSegment: a, b), distance(from: d, toSegment: a, b))
    }

    static func segment(_ a: CGPoint, _ b: CGPoint, touchesPolyline points: [CGPoint], within limit: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 { return distance(from: first, toSegment: a, b) <= limit }
        for index in 1..<points.count where distance(segment: a, b, toSegment: points[index - 1], points[index]) <= limit {
            return true
        }
        return false
    }

    /// Whether segment a→b comes within `radius` of the (rotated) rect's area.
    static func segment(_ a: CGPoint, _ b: CGPoint, touchesArea rect: CGRect, rotation: CGFloat = 0,
                        radius: CGFloat) -> Bool {
        guard rect.width >= 0, rect.height >= 0 else { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let localA = AnnotationTransformGeometry.rotate(a, around: center, by: -rotation)
        let localB = AnnotationTransformGeometry.rotate(b, around: center, by: -rotation)
        if rect.contains(localA) || rect.contains(localB) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for index in 0..<4 where distance(segment: localA, localB, toSegment: corners[index], corners[(index + 1) % 4]) <= radius {
            return true
        }
        return false
    }

    // MARK: Objects

    /// Whether the eraser moving from `a` to `b` with `radius` touches what `object` paints.
    static func touches(_ object: AnnotationObject, from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        let half = max(0.5, object.style.thickness / 2)
        switch object.kind {
        case .move, .crop, .eraser:
            return false
        case .line:
            let (start, end) = object.lineEndpoints
            return segment(a, b, touchesPolyline: [start, end], within: half + radius)
        case .arrow:
            let (start, end) = object.lineEndpoints
            // The head is wider than the shaft.
            let head = max(object.style.thickness * 1.6, 6)
            let path: [CGPoint]
            if object.style.arrowStyle == .curved {
                let control = object.curvedArrowControl
                path = (0...16).map { step in
                    let t = CGFloat(step) / 16
                    let u = 1 - t
                    return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                   y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
                }
            } else {
                path = [start, end]
            }
            return segment(a, b, touchesPolyline: path, within: max(half, head / 2) + radius)
        case .draw, .drawHighlight:
            return segment(a, b, touchesPolyline: object.points, within: half + radius)
        case .rectangle:
            let r = object.rect
            let outline = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
            return segment(a, b, touchesPolyline: outline, within: half + radius)
        case .ellipse:
            let r = object.rect
            let outline = (0...48).map { step -> CGPoint in
                let angle = CGFloat(step) / 48 * 2 * .pi
                return CGPoint(x: r.midX + cos(angle) * r.width / 2, y: r.midY + sin(angle) * r.height / 2)
            }
            return segment(a, b, touchesPolyline: outline, within: half + radius)
        case .counter:
            let diameter = max(object.rect.width, 24)
            let center = CGPoint(x: object.rect.minX + diameter / 2, y: object.rect.minY + diameter / 2)
            return distance(from: center, toSegment: a, b) <= diameter / 2 + radius
        case .image:
            return segment(a, b, touchesArea: object.rect, rotation: object.resolvedRotation, radius: radius)
        case .filledRectangle, .highlighter, .pixelate, .blur, .secureBlur, .redact, .spotlight, .text, .cursor:
            return segment(a, b, touchesArea: object.rect, radius: radius)
        }
    }

    /// What is left of a stroke after erasing near segment a→b, as separate
    /// runs of at least two points, or nil when the eraser missed it. Runs
    /// keep the original points plus one point at each cut, so repeated
    /// erasing never inflates the point count.
    static func remainingRuns(of points: [CGPoint], erasingFrom a: CGPoint, to b: CGPoint,
                              within limit: CGFloat) -> [[CGPoint]]? {
        guard !points.isEmpty, limit > 0 else { return nil }
        // Densify so a long segment is cut where the eraser crosses it, not
        // only at its ends.
        let step = max(0.5, limit / 2)
        var runs: [[CGPoint]] = []
        var current: [(point: CGPoint, original: Bool)] = []
        var touched = false
        func finish() {
            // Points added between two originals are collinear with them, so
            // only the run's ends (the cuts) are kept besides the originals.
            let last = current.count - 1
            let kept = current.enumerated()
                .filter { $0.element.original || $0.offset == 0 || $0.offset == last }
                .map(\.element.point)
            if kept.count >= 2 { runs.append(kept) }
            current.removeAll(keepingCapacity: true)
        }
        func visit(_ point: CGPoint, original: Bool) {
            if distance(from: point, toSegment: a, b) <= limit {
                touched = true
                finish()
            } else {
                current.append((point, original))
            }
        }
        for (index, point) in points.enumerated() {
            if index > 0 {
                let previous = points[index - 1]
                let length = hypot(point.x - previous.x, point.y - previous.y)
                let pieces = length.isFinite ? min(10_000, Int(ceil(length / step))) : 0
                if pieces > 1 {
                    for piece in 1..<pieces {
                        let t = CGFloat(piece) / CGFloat(pieces)
                        visit(CGPoint(x: previous.x + (point.x - previous.x) * t,
                                      y: previous.y + (point.y - previous.y) * t), original: false)
                    }
                }
            }
            visit(point, original: true)
        }
        finish()
        return touched ? runs : nil
    }

    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension AnnotationDocument {
    /// Objects the eraser touches moving from `a` to `b` (canvas points).
    func objectIDs(erasedFrom a: CGPoint, to b: CGPoint, radius: CGFloat) -> [UUID] {
        objects.filter { AnnotationEraser.touches($0, from: a, to: b, radius: radius) }.map(\.id)
    }

    /// Object eraser: deletes everything the segment touches and returns how
    /// many objects went. `registersUndo` snapshots first (the first change of a drag).
    @discardableResult
    mutating func eraseObjects(from a: CGPoint, to b: CGPoint, radius: CGFloat, registersUndo: Bool) -> Int {
        let ids = Set(objectIDs(erasedFrom: a, to: b, radius: radius))
        guard !ids.isEmpty else { return 0 }
        if registersUndo { beginChange() }
        objects.removeAll { ids.contains($0.id) }
        return ids.count
    }

    /// Stroke eraser: cuts the touched parts out of pen and highlighter
    /// strokes. A stroke cut in two becomes two objects in its z-position (the
    /// first keeps its id); a stroke erased completely is removed. Returns the
    /// number of strokes changed.
    @discardableResult
    mutating func eraseStrokes(from a: CGPoint, to b: CGPoint, radius: CGFloat, registersUndo: Bool) -> Int {
        var result: [AnnotationObject] = []
        result.reserveCapacity(objects.count)
        var changed = 0
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        for object in objects {
            let limit = radius + max(0.5, object.style.thickness / 2)
            guard object.kind.isFreehand,
                  object.rect.insetBy(dx: -limit, dy: -limit).intersects(sweep.insetBy(dx: -1, dy: -1)),
                  let runs = AnnotationEraser.remainingRuns(of: object.points, erasingFrom: a, to: b, within: limit) else {
                result.append(object)
                continue
            }
            changed += 1
            for (index, run) in runs.enumerated() {
                var piece = index == 0 ? object : AnnotationObject(kind: object.kind, rect: .zero, style: object.style)
                piece.points = run
                piece.rect = AnnotationEraser.boundingRect(of: run)
                result.append(piece)
            }
        }
        guard changed > 0 else { return 0 }
        if registersUndo { beginChange() }
        objects = result
        return changed
    }
}
