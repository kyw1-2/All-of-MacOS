import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// Opt-in visual review: the real overlay layers over a synthetic screen
/// (light content, a dark sidebar, a photo-like gradient), and the settings
/// detail, written as PNGs. Set AOM_UI_RENDER_PATH to a folder to run it;
/// nothing is shown on screen and nothing is read or clicked.
@MainActor
final class ClickHintsRenderTests: XCTestCase {
    private func outputFolder() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AOM_UI_RENDER_PATH"] else {
            throw XCTSkip("Set AOM_UI_RENDER_PATH for the visual review")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 640 × 400 pt "screen" at 2×: a light window with a toolbar and a
    /// form, a dark sidebar, and a colourful image area.
    private func backdrop(scale: CGFloat) -> CGImage? {
        let size = CGSize(width: 640, height: 400)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Flip so the drawing reads top-down like the targets below.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        func fill(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(rect)
        }
        fill(CGRect(origin: .zero, size: size), 0.96, 0.96, 0.97)                      // window
        fill(CGRect(x: 0, y: 0, width: 640, height: 52), 0.90, 0.90, 0.92)             // toolbar
        fill(CGRect(x: 0, y: 52, width: 170, height: 348), 0.17, 0.17, 0.19)           // dark sidebar
        for row in 0..<5 { fill(CGRect(x: 16, y: 72 + CGFloat(row) * 34, width: 120 - CGFloat(row) * 10, height: 12), 0.55, 0.55, 0.6) }
        let colors = [CGColor(srgbRed: 0.95, green: 0.55, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1),
                      CGColor(srgbRed: 0.1, green: 0.75, blue: 0.4, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
            context.saveGState()
            context.clip(to: CGRect(x: 420, y: 72, width: 200, height: 300))
            context.drawLinearGradient(gradient, start: CGPoint(x: 420, y: 72), end: CGPoint(x: 620, y: 372), options: [])
            context.restoreGState()
        }
        for x in [CGFloat(16), 52, 88] {                                                   // toolbar buttons
            fill(CGRect(x: x, y: 14, width: 28, height: 24), 0.98, 0.98, 0.99)
        }
        fill(CGRect(x: 190, y: 14, width: 220, height: 24), 1, 1, 1)                     // address field
        fill(CGRect(x: 190, y: 80, width: 200, height: 22), 1, 1, 1)                     // form field
        fill(CGRect(x: 190, y: 120, width: 90, height: 24), 0.2, 0.45, 0.95)              // primary button
        fill(CGRect(x: 290, y: 120, width: 90, height: 24), 0.88, 0.88, 0.9)              // secondary button
        for line in 0..<4 { fill(CGRect(x: 190, y: 170 + CGFloat(line) * 26, width: 180, height: 10), 0.35, 0.45, 0.85) }  // links
        return context.makeImage()
    }

    /// Where the sample targets are (view points, top-left origin).
    private let anchors: [CGRect] = [
        CGRect(x: 16, y: 14, width: 28, height: 24), CGRect(x: 52, y: 14, width: 28, height: 24), CGRect(x: 88, y: 14, width: 28, height: 24),
        CGRect(x: 190, y: 14, width: 220, height: 24), CGRect(x: 190, y: 80, width: 200, height: 22),
        CGRect(x: 190, y: 120, width: 90, height: 24), CGRect(x: 290, y: 120, width: 90, height: 24),
        CGRect(x: 190, y: 170, width: 180, height: 10), CGRect(x: 190, y: 196, width: 180, height: 10),
        CGRect(x: 190, y: 222, width: 180, height: 10), CGRect(x: 190, y: 248, width: 180, height: 10),
        CGRect(x: 16, y: 68, width: 140, height: 20), CGRect(x: 16, y: 102, width: 140, height: 20),
        CGRect(x: 16, y: 136, width: 140, height: 20), CGRect(x: 440, y: 100, width: 60, height: 60),
        CGRect(x: 520, y: 220, width: 60, height: 60), CGRect(x: 440, y: 300, width: 160, height: 40)
    ]

    private enum Look { case idle, typed(String), search(String, highlight: Int) }

    private func renderOverlay(_ look: Look, dark: Bool, contrast: Bool, size: ClickHintsSize, alphabet: ClickHintsAlphabet = .homeRow,
                               to url: URL) throws {
        let scale: CGFloat = 2
        let display = ClickHintsDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 400), scale: scale)
        let style = ClickHintsPillStyle.resolve(dark: dark, increasedContrast: contrast, size: size,
                                                accent: NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1))
        // More targets than anchors so two-letter labels appear: the extra ones repeat the anchors far right.
        let labels = ClickHintsLabels.make(count: anchors.count, alphabet: alphabet)
        let sizes = labels.map { ClickHintsPillRenderer.size(for: $0, style: style, scale: scale) }
        let placed = ClickHintsPlacement.place(anchors: anchors, sizes: sizes, displays: [display])

        var state = ClickHintsInputState(labels: labels, searchTexts: ["Back", "Forward", "Share", "Address", "Name", "Save", "Cancel",
                                                                       "Report", "Notes", "Syllabus", "Grades", "Inbox", "Drafts", "Sent",
                                                                       "Photo", "Map", "Download"])
        switch look {
        case .idle: break
        case .typed(let text): for character in text { _ = state.handle(.character(character), modifiers: []) }
        case .search(let query, let highlight):
            _ = state.handle(.character("/"), modifiers: [])
            for character in query { _ = state.handle(.character(character), modifiers: []) }
            for _ in 0..<highlight { _ = state.handle(.tab, modifiers: []) }
        }

        let view = ClickHintsOverlayView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdropLayer = CALayer()
        backdropLayer.frame = view.bounds
        backdropLayer.contents = backdrop(scale: scale)
        view.layer?.insertSublayer(backdropLayer, at: 0)
        let visible = Set(state.matches)
        let typed = state.mode == .labels ? state.typed.count : 0
        for (index, pill) in placed.enumerated() {
            guard let pill else { continue }
            let image = ClickHintsPillRenderer.image(label: labels[index], typed: typed, highlighted: state.highlightedTarget == index,
                                                     style: style, scale: scale)
            view.setPill(index, frame: pill.localFrame, image: image, scale: scale, halo: style.halo)
            view.setVisible(index, visible.contains(index))
        }
        if state.mode == .search {
            let text = ClickHintsSearchBadge.text(query: state.query, matches: state.matches.count)
            let badge = ClickHintsSearchBadge.size(text, style: style, scale: scale)
            view.setSearch(image: ClickHintsSearchBadge.image(text, style: style, scale: scale),
                           frame: CGRect(x: 320 - badge.width / 2, y: 60, width: badge.width, height: badge.height), scale: scale, halo: style.halo)
        }
        XCTAssertEqual(view.pillCount, anchors.count)
        let image = try write(view, scale: scale, to: url)
        // The tree must not be mirrored: the light toolbar is at the top, the
        // dark sidebar below it on the left.
        XCTAssertGreaterThan(pixel(image, x: Int(300 * scale), y: Int(4 * scale)).red, 200, "toolbar at the top")
        XCTAssertLessThan(pixel(image, x: Int(100 * scale), y: Int(380 * scale)).red, 80, "sidebar at the bottom left")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Row y counts from the top; the context's origin is bottom-left.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (data[0], data[1], data[2])
    }

    func testRenderTheOverlay() throws {
        let folder = try outputFolder()
        try renderOverlay(.idle, dark: false, contrast: false, size: .regular, to: folder.appendingPathComponent("hints-light.png"))
        try renderOverlay(.idle, dark: true, contrast: false, size: .regular, to: folder.appendingPathComponent("hints-dark.png"))
        try renderOverlay(.typed("h"), dark: false, contrast: false, size: .regular, to: folder.appendingPathComponent("hints-typed-light.png"))
        try renderOverlay(.typed("h"), dark: true, contrast: true, size: .regular, to: folder.appendingPathComponent("hints-typed-dark-contrast.png"))
        try renderOverlay(.idle, dark: false, contrast: true, size: .large, to: folder.appendingPathComponent("hints-large-contrast-light.png"))
        try renderOverlay(.search("s", highlight: 1), dark: false, contrast: false, size: .regular,
                          to: folder.appendingPathComponent("hints-search-light.png"))
        try renderOverlay(.idle, dark: true, contrast: false, size: .small, alphabet: .numbers,
                          to: folder.appendingPathComponent("hints-numbers-small-dark.png"))
    }

    /// Draws the view's layer tree into a PNG (the overlay is layer-hosting).
    @discardableResult
    private func write(_ view: NSView, scale: CGFloat, to url: URL) throws -> CGImage {
        let layer = try XCTUnwrap(view.layer)
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The canvas layer carries the flip, so the tree renders upright as is.
        context.scaleBy(x: scale, y: scale)
        layer.layoutIfNeeded()
        layer.render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        return image
    }

    /// The detail at the Text Actions detail column of a 1320×820 window
    /// (820 pt) and of a 1000×680 window (520 pt), light and dark.
    func testRenderTheDetail() throws {
        let folder = try outputFolder()
        for (name, width, appearance, trusted) in [
            ("detail-wide-light", 820, NSAppearance.Name.aqua, true),
            ("detail-wide-dark", 820, .darkAqua, true),
            ("detail-narrow-light-no-access", 520, .aqua, false)
        ] as [(String, CGFloat, NSAppearance.Name, Bool)] {
            let content = ClickHintsDetail(accessibilityOverride: trusted)
                .frame(width: width, height: 1_760)
                .background(AOMColor.canvas)
            try writeHosting(content, size: CGSize(width: width, height: 1_760), appearance: appearance,
                             url: folder.appendingPathComponent(name + ".png"))
        }
    }

    private func writeHosting<V: View>(_ root: V, size: CGSize, appearance: NSAppearance.Name, url: URL) throws {
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
        window.close()
    }
}
