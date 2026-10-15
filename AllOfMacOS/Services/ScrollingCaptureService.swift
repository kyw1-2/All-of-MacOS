import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Interactive scrolling capture and conservative image overlap matching.
/// The session can observe manual scrolling or generate small automatic steps.
/// Unmatched movement is never appended; the session leaves finishing to the user.
@MainActor
final class ScrollingCaptureService {
    static let shared = ScrollingCaptureService()
    private init() {}

    enum Direction: Hashable { case vertical, horizontal }

    /// The manual session keeps the target app interactive; automatic scrolling
    /// is an explicit choice in the same preview and controls surface.
    func capture(area: CGRect, maxFrames: Int = 300, direction: Direction = .vertical) async throws -> CaptureResult {
        guard area.height >= 40, area.width >= 40 else { throw CaptureError.areaTooSmall }
        let session = ScrollingCaptureSession(area: area, direction: direction,
                                             maxFrames: maxFrames)
        return try await session.run()
    }

    /// Sends one scroll-wheel gesture to the pointer's current location.
    ///
    /// A synthetic wheel event is used rather than an AppleScript keystroke
    /// because it works on any app without accessibility scripting permission and
    /// respects the app's own scroll physics.
    func scrollOnce(at area: CGRect, direction: Direction) async throws -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        // Aim at the centre of the captured region so the scroll lands on the
        // intended window even if the pointer has drifted.
        let centre = CGPoint(x: area.midX, y: area.midY)

        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: centre, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)

        // A short, smooth scroll: a large jump would move past the overlap the
        // stitcher needs to find.
        let edge = direction == .vertical ? area.height : area.width
        let step = Int32(max(8, min(120, edge / 5)))
        guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                   wheelCount: 2,
                                   wheel1: direction == .vertical ? -step : 0,
                                   wheel2: direction == .horizontal ? -step : 0,
                                   wheel3: 0) else { return false }
        scroll.location = centre
        scroll.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Stitching

    /// Finds how far `next` has scrolled relative to `current`, in pixels.
    ///
    /// After scrolling down by `shift` rows the content moves up, so the new
    /// frame's row `r` equals the old frame's row `r + shift`. The returned value
    /// is therefore the index in `current` where `next`'s first row is found.
    ///
    /// Only vertical shifts are searched, because a horizontal or diagonal scroll
    /// has no unambiguous single offset and would produce a torn image. A coarse
    /// search over candidate offsets is followed by a fine one, which is much
    /// cheaper than a full correlation over every possible shift.
    ///
    /// Not actor-isolated: this is pure work over immutable images.
    nonisolated static func verticalShift(from current: CGImage, to next: CGImage) -> CGFloat? {
        guard current.width == next.width, current.height == next.height,
              let a = grayscaleRows(current), let b = grayscaleRows(next),
              let shift = matchedShift(a, b) else { return nil }
        let samplingScale = min(1, CGFloat(160) / CGFloat(current.width))
        return (CGFloat(shift) / samplingScale).rounded()
    }

    nonisolated static func horizontalShift(from current: CGImage, to next: CGImage) -> CGFloat? {
        guard current.width == next.width, current.height == next.height,
              let a = grayscaleRows(current), let b = grayscaleRows(next),
              let width = a.first?.count else { return nil }
        let columnsA = (0..<width).map { column in a.map { $0[column] } }
        let columnsB = (0..<width).map { column in b.map { $0[column] } }
        guard let shift = matchedShift(columnsA, columnsB) else { return nil }
        let samplingScale = min(1, CGFloat(160) / CGFloat(current.width))
        return (CGFloat(shift) / samplingScale).rounded()
    }

    /// Match an interior strip so a small fixed toolbar or scrollbar does not
    /// dominate the match. A real shift must improve on the zero-shift baseline;
    /// flat or unchanged frames cannot fabricate extra rows of content.
    nonisolated private static func matchedShift(_ previous: [[UInt8]], _ next: [[UInt8]]) -> Int? {
        guard previous.count == next.count, previous.count > 16,
              let width = previous.first?.count, width > 8 else { return nil }
        let height = previous.count
        let margin = max(2, height / 6)
        let probeHeight = min(120, max(6, height / 3))
        let maximum = height - margin - probeHeight - 1
        guard maximum >= 2 else { return nil }
        let sideMargin = max(1, width / 12)
        func score(_ shift: Int) -> Double {
            var total = 0
            var count = 0
            for row in margin..<(margin + probeHeight) {
                for column in stride(from: sideMargin, to: width - sideMargin, by: 2) {
                    total += abs(Int(next[row][column]) - Int(previous[row + shift][column]))
                    count += 1
                }
            }
            return Double(total) / Double(max(1, count))
        }
        let unchangedScore = score(0)
        guard unchangedScore > 1.25 else { return nil }
        var best = 1
        var bestScore = Double.greatestFiniteMagnitude
        for shift in stride(from: 1, through: maximum, by: 2) {
            let candidate = score(shift)
            if candidate < bestScore { bestScore = candidate; best = shift }
        }
        for shift in max(1, best - 2)...min(maximum, best + 2) {
            let candidate = score(shift)
            if candidate < bestScore { bestScore = candidate; best = shift }
        }
        guard bestScore < 7, bestScore < unchangedScore * 0.65 else { return nil }
        return best
    }

    /// Extend the accumulated image while matching against the *most recent
    /// original viewport*, not the ever-growing accumulator. Otherwise the
    /// source and next-frame heights differ after frame two and stitching stops.
    nonisolated static func appendFrame(_ next: CGImage, after previous: CGImage,
                                        to accumulated: CGImage,
                                        direction: Direction = .vertical) -> (image: CGImage, shift: Int)? {
        let detected: CGFloat?
        switch direction {
        case .vertical: detected = verticalShift(from: previous, to: next)
        case .horizontal: detected = horizontalShift(from: previous, to: next)
        }
        guard let detected, detected > 0 else { return nil }
        let shift = Int(detected.rounded())
        let edge = direction == .vertical ? next.height : next.width
        guard shift > 0, shift < edge else { return nil }
        let joined: CGImage?
        switch direction {
        case .vertical: joined = append(next, to: accumulated, shift: shift)
        case .horizontal: joined = appendHorizontal(next, to: accumulated, shift: shift)
        }
        guard let joined else { return nil }
        switch direction {
        case .vertical:
            guard joined.height == accumulated.height + shift else { return nil }
        case .horizontal:
            guard joined.width == accumulated.width + shift else { return nil }
        }
        return (joined, shift)
    }

    nonisolated static func appendHorizontal(_ next: CGImage, to current: CGImage,
                                             shift: Int) -> CGImage? {
        guard shift > 0, shift < next.width, current.height == next.height else { return nil }
        let width = current.width + shift
        let height = current.height
        guard width <= 16384, height <= 16384,
              Int64(width) * Int64(height) <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.draw(current, in: CGRect(x: 0, y: 0, width: current.width, height: height))
        guard let band = next.cropping(to: CGRect(x: next.width - shift,
                                                   y: 0, width: shift, height: height)) else { return nil }
        context.draw(band, in: CGRect(x: current.width, y: 0, width: shift, height: height))
        return context.makeImage()
    }

    /// Appends the non-overlapping part of `next` below `current`.
    nonisolated static func append(_ next: CGImage, to current: CGImage, shift: Int) -> CGImage? {
        guard shift > 0, shift < current.height else { return current }
        // Scrolling down by `shift` rows moves the content up, so the rows that
        // were not already visible are the bottom `shift` rows of the new frame —
        // not the remaining height, which is what an inverted reading would give.
        let added = shift
        let width = current.width
        let newHeight = current.height + added
        guard newHeight <= 16384, width <= 16384,
              Int64(width) * Int64(newHeight) <= 100_000_000 else { return nil }
        guard let context = CGContext(data: nil, width: width, height: current.height + added,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Draw the accumulated image at the top and the new band below it. The
        // band is taken from the bottom `added` rows of the new frame, which is
        // exactly the part that was not already covered.
        context.draw(current, in: CGRect(x: 0, y: added, width: width, height: current.height))
        guard let band = next.cropping(to: CGRect(x: 0, y: next.height - added, width: width, height: added)) else {
            return current
        }
        context.draw(band, in: CGRect(x: 0, y: 0, width: width, height: added))
        return context.makeImage()
    }

    // MARK: - Pixel helpers

    /// Reduces an image to one luminance value per pixel, downsampled to a
    /// manageable width so the offset search stays fast on a Retina capture.
    ///
    /// The returned rows are in top-down order: row 0 is the top of the image.
    /// A `CGContext` bitmap is bottom-up, so the draw below flips it — the offset
    /// search compares rows directly and would silently invert if this did not.
    nonisolated private static func grayscaleRows(_ image: CGImage, targetWidth: Int = 160) -> [[UInt8]]? {
        let scale = min(1, CGFloat(targetWidth) / CGFloat(image.width))
        let width = max(8, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(8, Int((CGFloat(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).map { row in Array(buffer[(row * width)..<((row + 1) * width)]) }
    }

    nonisolated private static func meanAbsoluteDifference(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        guard a.count == b.count, let width = a.first?.count, width > 0 else { return Int.max }
        var total = 0
        for row in 0..<a.count {
            let ra = a[row], rb = b[row]
            for column in 0..<width {
                total += abs(Int(ra[column]) - Int(rb[column]))
            }
        }
        return total / (a.count * width)
    }
}
