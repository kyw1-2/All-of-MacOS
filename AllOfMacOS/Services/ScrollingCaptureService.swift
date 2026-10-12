import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Scrolling capture: repeatedly scrolls the window under a fixed region and
/// stitches the frames into one tall image.
///
/// The approach is the one CleanShot describes in its own guidance — scroll a
/// little at a time, grab each frame, and detect where the new frame overlaps
/// the accumulated image. It is deliberately conservative: if the overlap cannot
/// be found with confidence, the scroll is retried and the capture ends rather
/// than appending a misaligned band.
///
/// The known failure modes are the ones CleanShot's own tips name: scrolling on
/// a diagonal, scrolling too fast, and scrolling back up. Each of those makes
/// the overlap ambiguous, so each is detected and the capture stops with what it
/// has instead of producing a corrupt image.
@MainActor
final class ScrollingCaptureService {
    static let shared = ScrollingCaptureService()
    private init() {}

    /// Scrolls the window under `area` and returns the stitched result.
    ///
    /// - Parameter area: the fixed screen region to capture, in global top-left
    ///   origin points. The caller picks it with the normal selection overlay.
    func capture(area: CGRect, maxFrames: Int = 60) async throws -> CaptureResult {
        guard area.height >= 40, area.width >= 40 else { throw CaptureError.areaTooSmall }

        var frames: [CGImage] = []
        var accumulator: CGImage?

        // Seed with the first frame so the overlap search always has a reference.
        let first = try await ScreenCaptureService.shared.captureArea(area)
        frames.append(first.image)
        accumulator = first.image

        var consecutiveFailures = 0
        var previousOffset: CGFloat?

        while frames.count < maxFrames {
            let scrolled = try await scrollOnce(at: area)
            guard scrolled else { break }

            // Give the window time to finish its scroll animation before reading
            // pixels, otherwise a frame catches the content mid-flight.
            try await Task.sleep(nanoseconds: 220_000_000)

            let next = try await ScreenCaptureService.shared.captureArea(area)
            guard let current = accumulator else { break }

            // A frame identical to the last one means the scroll did nothing —
            // the region is not scrollable, or it is already at the end.
            if let result = Self.appendFrame(next.image,
                                              after: frames.last ?? first.image,
                                              to: current) {
                let offset = CGFloat(result.shift)
                // Scrolling backwards is the "started scrolling up" case. Stop
                // rather than appending a band that duplicates earlier content.
                if let previousOffset, offset.sign != previousOffset.sign {
                    break
                }
                previousOffset = offset
                accumulator = result.image
                frames.append(next.image)
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                // Two frames in a row with no detectable shift means the content
                // stopped moving, which is the end of the scrollable range.
                if consecutiveFailures >= 2 { break }
            }
        }

        guard let stitched = accumulator, frames.count > 1 else {
            // Only one frame: the region did not scroll. Return it rather than
            // failing, since a single frame is still what the user selected.
            let single = frames.first ?? first.image
            return CaptureResult(image: single, globalRect: area,
                                 scale: first.scale, kind: .scrolling)
        }
        return CaptureResult(image: stitched, globalRect: area, scale: first.scale, kind: .scrolling)
    }

    /// Sends one scroll-wheel gesture to the pointer's current location.
    ///
    /// A synthetic wheel event is used rather than an AppleScript keystroke
    /// because it works on any app without accessibility scripting permission and
    /// respects the app's own scroll physics.
    private func scrollOnce(at area: CGRect) async throws -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        // Aim at the centre of the captured region so the scroll lands on the
        // intended window even if the pointer has drifted.
        let centre = CGPoint(x: area.midX, y: area.midY)

        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: centre, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)

        // A short, smooth scroll: a large jump would move past the overlap the
        // stitcher needs to find.
        guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                   wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0) else { return false }
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
        guard current.width == next.width, current.height == next.height else { return nil }
        guard let a = grayscaleRows(current), let b = grayscaleRows(next) else { return nil }

        let height = a.count
        let width = a.first?.count ?? 0
        guard height > 8, width > 8 else { return nil }

        // Probe with the top of the new frame and look for it further down the
        // accumulated one, which is where the overlap sits after a downward scroll.
        let probeHeight = min(height / 2, 200)
        let probe = Array(b[0..<probeHeight])

        var bestOffset = 0
        var bestScore = Int.max
        // Search offsets from a few rows up to nearly a full frame.
        for offset in stride(from: 4, to: height - probeHeight, by: 2) {
            let candidate = Array(a[offset..<(offset + probeHeight)])
            let score = meanAbsoluteDifference(probe, candidate)
            if score < bestScore { bestScore = score; bestOffset = offset }
        }
        guard bestScore < 6 else { return nil } // 0…255 scale; 6 is a tight match

        // Refine around the coarse winner at single-row resolution.
        var refined = bestOffset
        var refinedScore = bestScore
        for offset in max(4, bestOffset - 3)...min(height - probeHeight, bestOffset + 3) where offset != bestOffset {
            let candidate = Array(a[offset..<(offset + probeHeight)])
            let score = meanAbsoluteDifference(probe, candidate)
            if score < refinedScore { refinedScore = score; refined = offset }
        }
        // The search runs on a downsampled bitmap. Convert the detected
        // shift back to original pixels before extracting the appended band.
        let samplingScale = min(1, CGFloat(160) / CGFloat(current.width))
        return (CGFloat(refined) / samplingScale).rounded()
    }

    /// Extend the accumulated image while matching against the *most recent
    /// original viewport*, not the ever-growing accumulator. Otherwise the
    /// source and next-frame heights differ after frame two and stitching stops.
    nonisolated static func appendFrame(_ next: CGImage, after previous: CGImage,
                                        to accumulated: CGImage) -> (image: CGImage, shift: Int)? {
        guard let logicalShift = verticalShift(from: previous, to: next),
              logicalShift > 0 else { return nil }
        let shift = Int(logicalShift.rounded())
        guard shift > 0, shift < next.height,
              let joined = append(next, to: accumulated, shift: shift),
              joined.height == accumulated.height + shift else { return nil }
        return (joined, shift)
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
