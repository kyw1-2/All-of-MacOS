import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// Opt-in visual review of the measuring overlay: the real overlay view and
/// layers drawn over a synthetic screen, written as PNGs. Set
/// AOM_UI_RENDER_PATH to a folder to run it; nothing is shown on screen.
@MainActor
final class ScreenRulerRenderTests: XCTestCase {
    /// A 600 × 375 pt window-like screen at 2×: a sidebar, a card with a
    /// title bar of "text", two buttons and a field.
    private func sampleScreen() -> ScreenRulerCanvas {
        var canvas = ScreenRulerCanvas(width: 1200, height: 750, color: (214, 214, 220))
        canvas.fill(ScreenRulerPixelRect(x: 0, y: 0, width: 300, height: 750), (200, 200, 208))       // sidebar
        for row in 0..<6 {
            canvas.fill(ScreenRulerPixelRect(x: 48, y: 96 + row * 72, width: 160 - row * 12, height: 20), (90, 90, 96))
        }
        canvas.fill(ScreenRulerPixelRect(x: 380, y: 80, width: 740, height: 560), (255, 255, 255))   // card
        canvas.fill(ScreenRulerPixelRect(x: 428, y: 128, width: 360, height: 28), (40, 40, 44))      // title "text"
        canvas.fill(ScreenRulerPixelRect(x: 428, y: 188, width: 520, height: 18), (140, 140, 146))   // body "text"
        canvas.fill(ScreenRulerPixelRect(x: 428, y: 220, width: 470, height: 18), (140, 140, 146))
        canvas.fill(ScreenRulerPixelRect(x: 428, y: 300, width: 600, height: 64), (246, 246, 248))   // field
        canvas.fill(ScreenRulerPixelRect(x: 812, y: 540, width: 120, height: 56), (225, 225, 230))   // Cancel
        canvas.fill(ScreenRulerPixelRect(x: 952, y: 540, width: 136, height: 56), (10, 132, 255))    // OK
        return canvas
    }

    func testRenderTheMeasuringOverlay() throws {
        guard let path = ProcessInfo.processInfo.environment["AOM_UI_RENDER_PATH"] else {
            throw XCTSkip("Set AOM_UI_RENDER_PATH for the visual review")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let canvas = sampleScreen()
        let snapshot = canvas.snapshot(id: 7, scale: 2)

        for (name, options, contrast) in [
            ("ruler-default", ScreenRulerOptions(showsColor: true), false),
            ("ruler-both-units-contrast", ScreenRulerOptions(showsBothUnits: true, showsColor: true), true),
            ("ruler-yellow-pixels", ScreenRulerOptions(unit: .pixels, guideColor: AOMRGBAColor(red: 1, green: 0.84, blue: 0)), false)
        ] as [(String, ScreenRulerOptions, Bool)] {
            var session = ScreenRulerSession(snapshots: [snapshot], options: options)
            // A box dragged loosely around the OK button, shrunk to it, kept with ⇧.
            session.press(at: CGPoint(x: 468, y: 260))
            session.release(at: CGPoint(x: 552, y: 305))
            session.hold()
            // A box around the title "text", left in focus.
            session.press(at: CGPoint(x: 205, y: 52))
            session.release(at: CGPoint(x: 410, y: 86))
            // The pointer in the gap between Cancel and OK.
            session.move(to: CGPoint(x: 471, y: 285))

            let style = ScreenRulerStyle(options: options, increasedContrast: contrast)
            let view = ScreenRulerOverlayView(display: snapshot.display, backdrop: canvas.image, style: style, hidesCursor: false)
            let unit = session.unit
            view.setHeld(session.held.map { ScreenRulerLayout.marks(for: $0, unit: unit, showsBoth: options.showsBothUnits,
                                                                     increasedContrast: contrast) })
            view.setArea(session.area.map { ScreenRulerLayout.marks(for: $0, dragging: false, unit: unit, showsBoth: options.showsBothUnits) })
            let live = try XCTUnwrap(session.live)
            view.setLive(ScreenRulerLayout.marks(for: live, unit: unit, showsBoth: options.showsBothUnits, increasedContrast: contrast),
                         color: options.showsColor ? session.pointerColorHex : nil,
                         pointer: session.pointer.map { snapshot.display.localPoint(fromGlobal: $0) })
            view.setNotice("Copied 68 × 28")
            try write(view, scale: 2, to: output.appendingPathComponent(name + ".png"))
        }

        // A box still being dragged (dashed, raw size).
        var dragging = ScreenRulerSession(snapshots: [snapshot], options: ScreenRulerOptions())
        dragging.press(at: CGPoint(x: 200, y: 140))
        dragging.move(to: CGPoint(x: 330, y: 200))
        let view = ScreenRulerOverlayView(display: snapshot.display, backdrop: canvas.image,
                                          style: ScreenRulerStyle(options: ScreenRulerOptions(), increasedContrast: false), hidesCursor: false)
        view.setArea(dragging.dragArea.map { ScreenRulerLayout.marks(for: $0, dragging: true, unit: .points, showsBoth: false) })
        view.setNotice("Drag to measure an area · ⇧ keep · ⌘C copy · Space pt/px · Esc exit")
        try write(view, scale: 2, to: output.appendingPathComponent("ruler-dragging.png"))
    }

    /// Draws the view's layer tree (the overlay is layer-hosting) into a PNG.
    private func write(_ view: NSView, scale: CGFloat, to url: URL) throws {
        let layer = try XCTUnwrap(view.layer)
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.layoutIfNeeded()
        layer.render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// The Capture page's Screen Ruler section at the two window sizes, light
    /// and dark, with and without Screen Recording (the shared defaults are
    /// only read). Increase Contrast is not rendered here: an NSAppearance
    /// name does not change SwiftUI's contrast environment.
    func testRenderTheSettingsSection() throws {
        guard let path = ProcessInfo.processInfo.environment["AOM_UI_RENDER_PATH"] else {
            throw XCTSkip("Set AOM_UI_RENDER_PATH for the visual review")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The Capture page's content width at 1320×820 and 1000×680 windows.
        for (name, width, appearance, permission) in [
            ("section-wide-light", 1052, NSAppearance.Name.aqua, true),
            ("section-wide-dark", 1052, .darkAqua, true),
            ("section-narrow-light", 732, .aqua, true),
            ("section-narrow-no-permission-dark", 732, .darkAqua, false)
        ] as [(String, CGFloat, NSAppearance.Name, Bool)] {
            let content = ScreenRulerSection(permissionOverride: permission)
                .padding(AOMSpace.pageMargin)
                .frame(width: width)
                .background(AOMColor.canvas)
                .font(AOMFont.body)
            try writeHosting(content, width: width, appearance: appearance, url: output.appendingPathComponent(name + ".png"))
        }
    }

    private func writeHosting<V: View>(_ root: V, width: CGFloat, appearance: NSAppearance.Name, url: URL) throws {
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let height = max(200, host.fittingSize.height)
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
        window.close()
    }
}
