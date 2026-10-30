import SwiftUI

private let tutorialStorageKey = "AOMHasSeenTutorial"

extension UserDefaults {
    static var hasSeenTutorial: Bool {
        get { UserDefaults.standard.bool(forKey: tutorialStorageKey) }
        set { UserDefaults.standard.set(newValue, forKey: tutorialStorageKey) }
    }
}

// The 1.x seven-step `TutorialStep` tour ("Map 30+ gesture types…", "Click {{plus}}")
// was removed in 3.3: nothing referenced it, and first run is the short
// skippable welcome below (contextual help over an up-front tour).

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
            AOMFeatureColor.mediaDim
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
                .padding(.horizontal, AOMSpace.x8)
                .padding(.top, AOMSpace.x8)
                .padding(.bottom, AOMSpace.x5)
                .transition(.opacity)
                .id(page)
                AOMDivider()
                controls
            }
            .frame(width: AOMFeatureSize.welcomeWidth)
            // Glass chrome draws its own shadow; nothing is added on top (c.4).
            .aomFloatingSurface(.panel, radius: AOMRadius.panel, inWindow: true)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .aomAnimation(.standard, value: page)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if page == 1 { refresh() }
        }
        .onExitCommand { finish() }
    }

    // MARK: Pages

    private func pageTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Text(title)
                .font(AOMFont.title)
                .foregroundStyle(AOMColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(AOMFont.body).foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x5) {
            pageTitle("Welcome to All of MacOS", "Four tools that work together, one shortcut away.")
            VStack(alignment: .leading, spacing: AOMSpace.x4) {
                feature(.capture, "Capture your screen", "Screenshots, recordings and text, with a preview to copy, edit or drag.")
                feature(.clipboard, "Keep everything you copy", "A searchable clipboard shelf, encrypted on this Mac.")
                feature(.gestures, "Automate what you repeat", "Turn gestures, keys and mouse buttons into actions.")
                feature(.snapping, "Tile your windows", "Drag a window to an edge or zone and it snaps into place.")
            }
        }
    }

    /// Each tool with its module badge, the same identity the Workspace tiles use.
    private func feature(_ tab: AOMMainTab, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: AOMSpace.x3) {
            if let module = AOMModule(tab: tab) {
                AOMModuleBadge(module, size: AOMIcon.headerBadge)
            }
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(title).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                Text(detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            pageTitle("Allow what you'll use",
                      "macOS asks you to approve each kind of access in System Settings. AOM only reads whether it was given.")
            AOMSection(footer: "You can skip this and allow access later in Settings › Permissions.") {
                ForEach(AOMPermission.required) { permission in
                    permissionRow(permission)
                }
            }
        }
    }

    private func permissionRow(_ permission: AOMPermission) -> some View {
        let status = statuses[permission] ?? .notDetermined
        return AOMSettingRow(permission.title, detail: permission.explanation, symbol: permission.icon) {
            if status == .granted {
                AOMStatusPill("Allowed", tone: .success, symbol: "checkmark.circle.fill")
            } else {
                Button("Open Settings…") { _ = permission.openSettings() }
                    .controlSize(.small)
                    .help("Opens System Settings › Privacy & Security › \(permission.title)")
            }
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            pageTitle("You're set", "These shortcuts work from any app. Change them any time in Settings.")
            AOMSection {
                shortcutRow("Capture an area", symbol: "viewfinder",
                            keys: CaptureShortcuts.shared.shortcut(for: .captureArea)?.displayString)
                shortcutRow("Open the clipboard shelf", symbol: "doc.on.clipboard",
                            keys: ClipboardShortcuts.shared.shortcut(for: .history)?.displayString)
                shortcutRow("Search everything in AOM", symbol: "magnifyingglass",
                            keys: AOMPaletteShortcut.current(appState.currentPreset).displayString)
            }
            AOMSection {
                AOMToggleRow("Show AOM in the menu bar", detail: "Capture, clipboard and pause controls one click away.",
                             isOn: $showMenuBarIcon)
            }
        }
    }

    private func shortcutRow(_ title: String, symbol: String, keys: String?) -> some View {
        AOMSettingRow(title, symbol: symbol) {
            if let keys { AOMKeycap(text: keys) } else {
                Text("Not set").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: AOMSpace.x3) {
            if page == 0 {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AOMColor.textSecondary)
            } else {
                Button("Back") { page -= 1 }
                    .buttonStyle(.borderless)
            }
            Spacer()
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? AOMColor.accent : AOMColor.textTertiary)
                        .frame(width: index == page ? AOMSpace.x4 : AOMIcon.dot, height: AOMIcon.dot)
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
        .padding(.horizontal, AOMSpace.x5)
        .frame(height: AOMSize.rowDetail + AOMSpace.x1)
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
