import SwiftUI

private let tutorialStorageKey = "AOMHasSeenTutorial"

extension UserDefaults {
    static var hasSeenTutorial: Bool {
        get { UserDefaults.standard.bool(forKey: tutorialStorageKey) }
        set { UserDefaults.standard.set(newValue, forKey: tutorialStorageKey) }
    }
}

enum TutorialStep: Int, CaseIterable {
    case welcome = 0
    case sidebar
    case triggers
    case actions
    case config
    case tips
    case done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .sidebar: return "Applications"
        case .triggers: return "Triggers"
        case .actions: return "Actions"
        case .config: return "Configuration"
        case .tips: return "Tips & Tricks"
        case .done: return "You're set!"
        }
    }

    var bodyText: String {
        switch self {
        case .welcome:
            return "All of MacOS turns your trackpad into a programmable input surface.\n\nMap 30+ gesture types — swipes, taps, pinches, circles, edge slides — to keyboard shortcuts, window management, media controls, scripts, and more."
        case .sidebar:
            return "Choose which apps your gestures apply to.\n\n\"All Apps\" means global — gestures work everywhere.\n\nAdd specific apps (e.g. Safari, Slack, Cursor) for per-app bindings.\n\nTip: app-specific triggers override global ones."
        case .triggers:
            return "Your gesture bindings.\n\nPick from Trackpad, Keyboard, Mouse, or Drawing triggers.\n\nTrackpad offers 2–5 finger swipes, taps, pinches, TipTaps, edge slides, and corner clicks.\n\nClick {{plus}} to add a trigger."
        case .actions:
            return "What happens when a trigger fires.\n\nAdd one or more: Maximize Window, Send Keystroke, Volume Up/Down, Launch App, Run Script, Play/Pause, and 20+ more.\n\nClick {{plus}} to add an action."
        case .config:
            return "Edit the selected trigger or action here.\n\nRename triggers, enable/disable them, set \"Suppress Click\" for click-based gestures.\n\nConfigure action parameters (e.g. which key to send, which app to launch)."
        case .tips:
            return "Live Touch — finger positions for debugging.\n\nConsole — logs every detected gesture.\n\nMenu bar — click to open or toggle ON/OFF.\n\nGrant Accessibility & Automation permissions when prompted.\n\nTry: 3 Finger Swipe → Volume, Left Edge Slide → Brightness."
        case .done:
            return "Quick start: Add trigger → add actions → toggle ON.\n\nExport presets from Settings to share configs.\n\nEnjoy! 🖥️"
        }
    }

    var highlightRegion: TutorialRegion? {
        switch self {
        case .welcome: return nil
        case .sidebar: return .sidebar
        case .triggers: return .triggers
        case .actions: return .actions
        case .config: return .config
        case .tips: return nil
        case .done: return nil
        }
    }

    var isLast: Bool { self == .done }
}

enum TutorialRegion: String {
    case sidebar, triggers, actions, config
}

struct TutorialFramePreferenceKey: PreferenceKey {
    static var defaultValue: [TutorialRegion: CGRect] = [:]
    static func reduce(value: inout [TutorialRegion: CGRect], nextValue: () -> [TutorialRegion: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TutorialAnchorModifier: ViewModifier {
    let region: TutorialRegion

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFramePreferenceKey.self,
                    value: [region: geo.frame(in: .named("tutorialOverlay"))]
                )
            }
        )
    }
}

extension View {
    func tutorialAnchor(_ region: TutorialRegion) -> some View {
        modifier(TutorialAnchorModifier(region: region))
    }
}

struct CutoutMaskShape: Shape {
    let fullRect: CGRect
    let cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(fullRect)
        path.addRect(cutout)
        return path
    }
}

/// First run: a short, skippable setup instead of a tour of the interface
/// (HIG Onboarding; Nova's and Paste's first-launch assistants). Three steps —
/// what AOM does, the access it needs (live status, asked with a reason, never
/// all at once), and how to reach it — then the app itself teaches the rest.
/// `frames` is kept for the anchor API; the welcome flow does not spotlight.
struct TutorialOverlayView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    var frames: [TutorialRegion: CGRect]
    @State private var page = 0
    @State private var statuses: [AOMPermission: AOMPermissionStatus] = [:]
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pageCount = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: permissionsPage
                    default: readyPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, 20)
                .transition(.opacity)
                .id(page)
                AOMDivider()
                controls
            }
            .frame(width: 560)
            .aomFloatingSurface(.panel, radius: 22, inWindow: true)
            .shadow(color: .black.opacity(0.28), radius: 36, y: 16)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if page == 1 { refresh() }
        }
        .onExitCommand { finish() }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to All of MacOS")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text("Four tools that work together, one shortcut away.")
                    .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature(.capture, "Capture your screen", "Screenshots, recordings and text, with a preview to copy, edit or drag.")
                feature(.clipboard, "Keep everything you copy", "A searchable clipboard shelf, encrypted on this Mac.")
                feature(.gestures, "Automate what you repeat", "Turn gestures, keys and mouse buttons into actions.")
                feature(.snapping, "Tile your windows", "Drag a window to an edge or zone and it snaps into place.")
            }
        }
    }

    private func feature(_ tab: AOMMainTab, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tab.sidebarSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tab.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AOMType.headline)
                Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow what you'll use")
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text("macOS asks you to approve each kind of access in System Settings. AOM only reads whether it was given.")
                    .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                let permissions = AOMPermission.required
                ForEach(Array(permissions.enumerated()), id: \.element.id) { index, permission in
                    permissionRow(permission)
                    if index < permissions.count - 1 { AOMDivider().padding(.leading, 44) }
                }
            }
            .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
            Text("You can skip this and allow access later in Settings › Permissions.")
                .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
        }
    }

    private func permissionRow(_ permission: AOMPermission) -> some View {
        let status = statuses[permission] ?? .notDetermined
        return HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(AOMType.body.weight(.medium))
                Text(permission.explanation).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            }
            Spacer(minLength: 8)
            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(AOMType.caption.weight(.semibold))
                    .foregroundStyle(AOMTheme.positive)
            } else {
                Button("Open Settings…") { _ = permission.openSettings() }
                    .controlSize(.small)
                    .help("Opens System Settings › Privacy & Security › \(permission.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("You're set")
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text("These shortcuts work from any app. Change them any time in Settings.")
                    .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
            }
            VStack(spacing: 0) {
                shortcutRow("Capture an area", symbol: "viewfinder",
                            keys: CaptureShortcuts.shared.shortcut(for: .captureArea)?.displayString)
                AOMDivider().padding(.leading, 44)
                shortcutRow("Open the clipboard shelf", symbol: "doc.on.clipboard",
                            keys: ClipboardShortcuts.shared.shortcut(for: .history)?.displayString)
                AOMDivider().padding(.leading, 44)
                shortcutRow("Search everything in AOM", symbol: "magnifyingglass",
                            keys: AOMPaletteShortcut.current(appState.currentPreset).displayString)
            }
            .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
            Toggle(isOn: $showMenuBarIcon) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show AOM in the menu bar").font(AOMType.body)
                    Text("Capture, clipboard and pause controls one click away.")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func shortcutRow(_ title: String, symbol: String, keys: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title).font(AOMType.body)
            Spacer(minLength: 8)
            if let keys { AOMKeycap(text: keys) } else {
                Text("Not set").font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if page == 0 {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AOMTheme.textSecondary)
            } else {
                Button("Back") { page -= 1 }
                    .buttonStyle(.borderless)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : AOMTheme.textTertiary.opacity(0.35))
                        .frame(width: index == page ? 16 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page + 1) of \(Self.pageCount)")
            Spacer()
            Button(page == Self.pageCount - 1 ? "Get Started" : "Continue") {
                if page == Self.pageCount - 1 { finish() } else { page += 1 }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private func refresh() {
        var next: [AOMPermission: AOMPermissionStatus] = [:]
        for permission in AOMPermission.required { next[permission] = permission.status }
        if next != statuses { statuses = next }
    }

    private func finish() {
        UserDefaults.hasSeenTutorial = true
        isPresented = false
    }
}
