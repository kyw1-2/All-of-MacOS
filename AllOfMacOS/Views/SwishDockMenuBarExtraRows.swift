import SwiftUI

/// 3.3.3 settings rows for the Dock, menu-bar and Mission Control gestures
/// (Swish parity, audit F03, P2 menu bar, Mission Control). A file of its own
/// so the existing settings views stay untouched by the swish-dock stream;
/// ModernWindowSnappingView's "Dock & menu bar" section shows
/// `SwishDockMenuBarExtraRows()` right after its "Menu-bar gestures" row.
/// The rows are the section's own `AOMToggleRow`/`AOMSettingRow`s with ⓘ
/// help. The Dock and menu-bar options are indented and dim while Dock
/// gestures or Menu-bar gestures are off (the section footer says why);
/// Mission Control gestures stand on their own.
struct SwishDockMenuBarExtraRows: View {
    @AppStorage(TrackpadUtilityGestures.dockGesturesKey) private var dockGestures = true
    @AppStorage(TrackpadUtilityGestures.menuBarGesturesKey) private var menuBarGestures = true
    @AppStorage(TrackpadUtilityGestures.dockDoublePinchKey) private var dockDoublePinch = true
    @AppStorage(TrackpadUtilityGestures.appMenuGesturesKey) private var appMenuGestures = false
    @AppStorage(TrackpadUtilityGestures.menuBarScrollToTopKey) private var scrollToTop = false
    @AppStorage(TrackpadUtilityGestures.menuBarSwitcherKey)
    private var switcher = TrackpadUtilityGestures.SwitcherMode.windows.rawValue
    @AppStorage(TrackpadUtilityGestures.missionControlGesturesKey) private var missionControlGestures = false

    private static let doublePinchHelp = "On a Dock icon, pinch in twice to minimize all of the app's windows and pinch out twice to bring them back. A single pinch then waits 0.35 s for the second one before it quits the app or sends ⌘N."
    private static let appMenuHelp = "The Dock gestures also work on the front app's own menu, its name next to the Apple menu, for that app."
    private static let scrollToTopHelp = "A two-finger tap on the empty part of the menu bar scrolls the front window's main scroll area to the top. Menu titles and status icons keep their own clicks."
    private static let switcherHelp = "What tap, hold and scroll on the menu bar opens: AOM's window switcher, or the macOS app switcher, held open until you lift. The app switcher is not available while \"Disable AOM while holding ⌘\" is on; the window switcher opens instead."
    private static let missionControlHelp = "In Mission Control and App Exposé, with the pointer on a window: pinch in to close it (twice: quit its app), swipe down to minimize it. Moving a window to another Space is not available: macOS 27 ignores synthetic input in Mission Control."

    var body: some View {
        // A stack, not a Group: a Group would attach `onChange` to every row.
        VStack(alignment: .leading, spacing: 0) {
            Group {
                AOMToggleRow("Dock: pinch twice", help: Self.doublePinchHelp, indent: true, isOn: $dockDoublePinch)
                    .help(Self.doublePinchHelp)
                AOMToggleRow("Dock gestures on the app's menu", help: Self.appMenuHelp, indent: true, isOn: $appMenuGestures)
                    .help(Self.appMenuHelp)
            }
            .dependentSetting(on: dockGestures)
            Group {
                AOMToggleRow("Menu bar: tap to scroll to the top", help: Self.scrollToTopHelp, indent: true, isOn: $scrollToTop)
                    .help(Self.scrollToTopHelp)
                AOMSettingRow("Menu bar: tap, hold and scroll", indent: true, help: Self.switcherHelp) {
                    Picker("Menu bar: tap, hold and scroll", selection: $switcher) {
                        Text("Window switcher").tag(TrackpadUtilityGestures.SwitcherMode.windows.rawValue)
                        Text("App switcher (⌘-Tab)").tag(TrackpadUtilityGestures.SwitcherMode.apps.rawValue)
                    }
                    .pickerStyle(.menu)
                }
                .help(Self.switcherHelp)
            }
            .dependentSetting(on: menuBarGestures)
            AOMToggleRow("Mission Control gestures", help: Self.missionControlHelp, isOn: $missionControlGestures)
                .help(Self.missionControlHelp)
        }
        .onChange(of: missionControlGestures) { _, _ in
            // The trackpad stream's consumers changed.
            NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        }
    }
}
