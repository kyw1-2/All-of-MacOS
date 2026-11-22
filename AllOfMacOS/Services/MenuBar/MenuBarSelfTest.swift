import AppKit
import ScreenCaptureKit

/// 7.10: `--aom-menubar-selftest <folder>` — runs the menu bar features on
/// the real menu bar and writes what happened: a log and captures of the
/// top of the main display after each step (collapse, the Bar, one app
/// shown for a moment, show all). Settings are put back and AOM quits.
/// For checking a build on macOS 27 without driving the UI by hand.
@MainActor
enum MenuBarSelfTest {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--aom-menubar-selftest"), arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in await run(folder) }
    }

    private static var lines: [String] = []
    private static func log(_ line: String) { lines.append(line); NSLog("AOM selftest: \(line)") }

    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func run(_ folder: URL) async {
        await wait(3)
        let hider = MenuBarHider.shared
        let model = MenuBarLayoutModel.shared
        let savedSections = UserDefaults.standard.dictionary(forKey: MenuBarSectionStore.key)
        let wasRunning = hider.isRunning
        log("native available=\(MenuBarNativeHiding.isAvailable) ax=\(AXIsProcessTrusted()) screen=\(MenuBarItemImager.hasPermission) path=\(Bundle.main.bundlePath)")
        if !wasRunning { hider.start() }
        await wait(1.5)
        model.refresh(reveal: false)
        await wait(4)
        log("items=\(model.items.count) " + model.apps.map { "\($0.bundle)[\($0.items.first?.section.rawValue ?? "")\($0.items.first?.lockedReason == nil ? "" : ",locked")]" }.joined(separator: " "))
        // Two apps to hide for the test: the first two that may be hidden.
        let candidates = model.apps.filter { $0.items.first?.lockedReason == nil }.map(\.bundle)
        let test = Array(candidates.prefix(2))
        log("hiding for the test: \(test)")
        for bundle in test { model.assign(bundle, to: .hidden, name: bundle) }
        await capture(folder, "1-start")
        hider.collapse(quiet: true)
        await wait(2)
        let ownChevron = hider.toggleWindowFrame.map { NSStringFromRect($0) } ?? "none"
        log("chevron window=\(ownChevron) occlusionVisible=\(hider.chevronOnScreen)")
        log("collapsed=\(hider.isCollapsed) holding=\(MenuBarNativeHiding.shared.isHolding) allowed=\(MenuBarNativeHiding.shared.allowed?.count ?? -1) testAllowed=\(test.map { MenuBarNativeHiding.shared.allowed?.contains($0) ?? true })")
        await capture(folder, "2-collapsed")
        model.refresh()
        await wait(5)
        log("after refresh: images=\(model.images.count) hiddenLane=\(model.lanes[.hidden]?.map(\.item.ownerBundleID) ?? []) holding=\(MenuBarNativeHiding.shared.isHolding)")
        for entry in (model.lanes[.hidden] ?? []).prefix(3) {
            if let image = model.images[entry.imageKey], let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("item-\(entry.item.ownerName).png"))
            }
        }
        MenuBarStripController.shared.show()
        await wait(1.5)
        log("bar visible=\(MenuBarStripController.shared.isVisible) entries=\(MenuBarStripController.shared.entries.map(\.item.displayName))")
        await capture(folder, "3-bar")
        MenuBarStripController.shared.dismiss()
        if let first = test.first {
            MenuBarNativeHiding.shared.showTemporarily(first) {}
            await wait(1.5)
            log("shown for a moment: \(first) allowed=\(MenuBarNativeHiding.shared.allowed?.contains(first) ?? false)")
            await capture(folder, "4-one-shown")
        }
        hider.expand(all: true)
        await wait(1.5)
        log("expanded all: holding=\(MenuBarNativeHiding.shared.isHolding)")
        await capture(folder, "5-all")
        // Put everything back.
        UserDefaults.standard.set(savedSections, forKey: MenuBarSectionStore.key)
        if !wasRunning { hider.stop() } else { hider.expand() }
        MenuBarNativeHiding.shared.release()
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        await wait(0.5)
        NSApp.terminate(nil)
    }

    /// The top 90 pt of the main display: the menu bar and the Bar under it.
    private static func capture(_ folder: URL, _ name: String) async {
        guard MenuBarItemImager.hasPermission,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            log("capture \(name): no permission or display"); return
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: 90)
        configuration.width = display.width * 2
        configuration.height = 180
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                     configuration: configuration),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            log("capture \(name): failed"); return
        }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
