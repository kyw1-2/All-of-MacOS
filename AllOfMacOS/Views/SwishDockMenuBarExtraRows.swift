import SwiftUI

/// 3.3.3 settings rows for the Dock, menu-bar and Mission Control gestures
/// (Swish parity, audit F03, P2 menu bar, Mission Control). A file of its own
/// so the existing settings views stay untouched by this stream; the
/// integration step places `SwishDockMenuBarExtraRows()` in
/// ModernWindowSnappingView's "Trackpad Gestures" card, right after the
/// "Menu-bar gestures" row and before "Hold still to cancel". The rows use
/// the same layout as that card's `settingRow`.
struct SwishDockMenuBarExtraRows: View {
    @AppStorage(TrackpadUtilityGestures.dockGesturesKey) private var dockGestures = true
    @AppStorage(TrackpadUtilityGestures.menuBarGesturesKey) private var menuBarGestures = true
    @AppStorage(TrackpadUtilityGestures.dockDoublePinchKey) private var dockDoublePinch = true
    @AppStorage(TrackpadUtilityGestures.appMenuGesturesKey) private var appMenuGestures = false
    @AppStorage(TrackpadUtilityGestures.menuBarScrollToTopKey) private var scrollToTop = false
    @AppStorage(TrackpadUtilityGestures.menuBarSwitcherKey)
    private var switcher = TrackpadUtilityGestures.SwitcherMode.windows.rawValue
    @AppStorage(TrackpadUtilityGestures.missionControlGesturesKey) private var missionControlGestures = false

    var body: some View {
        VStack(spacing: 0) {
            row("Dock: pinch twice") {
                Toggle("Dock: pinch twice", isOn: $dockDoublePinch)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("On a Dock icon, pinch in twice to minimize all of the app's windows and pinch out twice to bring them back. A single pinch then waits 0.35 s for the second one before it quits the app or sends ⌘N.")
            .disabled(!dockGestures)
            .opacity(dockGestures ? 1 : 0.6)
            row("Dock gestures on the app's menu") {
                Toggle("Dock gestures on the app's menu", isOn: $appMenuGestures)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("The Dock gestures also work on the front app's own menu, its name next to the Apple menu, for that app.")
            .disabled(!dockGestures)
            .opacity(dockGestures ? 1 : 0.6)
            row("Menu bar: tap to scroll to the top") {
                Toggle("Menu bar: tap to scroll to the top", isOn: $scrollToTop)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("A two-finger tap on the empty part of the menu bar scrolls the front window's main scroll area to the top. Menu titles and status icons keep their own clicks.")
            .disabled(!menuBarGestures)
            .opacity(menuBarGestures ? 1 : 0.6)
            row("Menu bar: tap, hold and scroll") {
                Picker("Menu bar: tap, hold and scroll", selection: $switcher) {
                    Text("Window switcher").tag(TrackpadUtilityGestures.SwitcherMode.windows.rawValue)
                    Text("App switcher (⌘-Tab)").tag(TrackpadUtilityGestures.SwitcherMode.apps.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            .help("What tap, hold and scroll on the menu bar opens: AOM's window switcher, or the macOS app switcher, held open until you lift. The app switcher is not available while \"Disable AOM while holding ⌘\" is on; the window switcher opens instead.")
            .disabled(!menuBarGestures)
            .opacity(menuBarGestures ? 1 : 0.6)
            row("Mission Control gestures", showsDivider: false) {
                Toggle("Mission Control gestures", isOn: $missionControlGestures)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("In Mission Control and App Exposé, with the pointer on a window: pinch in to close it (twice: quit its app), swipe down to minimize it. Moving a window to another Space is not available: macOS 27 ignores synthetic input in Mission Control.")
        }
        .onChange(of: missionControlGestures) { _, _ in
            // The trackpad stream's consumers changed.
            NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        }
    }

    private func row<Control: View>(_ title: String, showsDivider: Bool = true,
                                    @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(AOMType.body).foregroundStyle(AOMTheme.text).lineLimit(1)
                Spacer(minLength: 8)
                control()
            }
            .frame(minHeight: 38)
            if showsDivider { AOMDivider() }
        }
    }
}
