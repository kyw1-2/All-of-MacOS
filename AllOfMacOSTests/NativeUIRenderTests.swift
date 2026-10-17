import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// Opt-in native rendering for visual review; never uses the user's preset.
@MainActor
final class NativeUIRenderTests: XCTestCase {
    func testRenderNativeScreens() throws {
        guard let path = ProcessInfo.processInfo.environment["AOM_UI_RENDER_PATH"] else {
            throw XCTSkip("Set AOM_UI_RENDER_PATH for native visual review")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        UserDefaults.hasSeenTutorial = true
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = AppState()
        state.currentPreset = Preset(name: "UI Review")
        state.selectedAppTarget = .allApps
        let names = ["Arrange workspace", "Move to next display", "Capture a region", "Open clipboard", "Focus current window", "Show desktop", "Adjust volume", "Switch workspace", "Quick note", "Media controls", "Toggle mute", "Capture text", "Open search", "Window center", "Next tab", "Previous tab", "Quick capture", "Paste plain text"]
        state.currentPreset.triggers = names.enumerated().map { index, name in
            var trigger = Trigger(name: name, input: .trackpadGesture(.twoFingerSwipeUp))
            trigger.actions = [TriggerAction(actionType: .snapWindowLeft)]
            return trigger
        }
        state.selectedTrigger = state.currentPreset.triggers.first
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            try render(ModernGesturesWorkspace().environmentObject(state).environment(\.colorScheme, scheme),
                       size: NSSize(width: 1080, height: 700), appearance: dark ? .darkAqua : .aqua,
                       url: output.appendingPathComponent(dark ? "gestures-dark.png" : "gestures-light.png"))
        }
        for tab in AOMMainTab.allCases {
            state.selectedMainTab = tab
            try render(MainWindow().environmentObject(state), size: NSSize(width: 1320, height: 820),
                       appearance: .aqua, url: output.appendingPathComponent("main-\(tab.title.replacingOccurrences(of: " ", with: "-").lowercased()).png"))
        }
        state.selectedMainTab = .gestures
        let empty = AppState()
        empty.currentPreset = Preset(name: "Empty Review")
        empty.currentPreset.triggers = []
        empty.selectedAppTarget = .allApps
        try render(MainWindow().environmentObject(empty), size: NSSize(width: 1320, height: 820),
                   appearance: .darkAqua, url: output.appendingPathComponent("main-gestures-empty-dark.png"))
        for (name, view) in [
            ("capture", AnyView(CaptureStudioView())),
            ("window-tiling", AnyView(ModernWindowSnappingView().environmentObject(state))),
            ("clipboard", AnyView(ClipboardStudioView())),
            ("insights", AnyView(StatisticsView().environmentObject(state))),
            ("settings", AnyView(SettingsView().environmentObject(state)))
        ] {
            try render(view, size: name == "settings" ? NSSize(width: 820, height: 640) : NSSize(width: 1080, height: 700),
                       appearance: .aqua, url: output.appendingPathComponent(name + ".png"))
        }
    }

    private func render<V: View>(_ root: V, size: NSSize, appearance: NSAppearance.Name, url: URL) throws {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        AOMScrollChromePolicy.shared.attach(in: host)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
        window.close()
    }
}
