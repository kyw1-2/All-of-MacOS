import AppKit
import ApplicationServices
import Combine
import SwiftUI

// 7.10: Bartender's Welcome window (Welcome.storyboardc): "Bartender Setup —
// With Bartender you can set up your menu items to be: …", the two
// permission cards with "Open macOS … Preferences" and the tick once granted,
// then how to reach the hidden items. The user's report: "I don't even know
// how to operate it" — so the Menu Bar page opens this the first time.

struct MenuBarSetupGuide: View {
    let done: () -> Void
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @State private var page = 0
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var screenGranted = MenuBarItemImager.hasPermission
    @State private var dontShow = true
    private let tick = Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index == page ? AOMColor.accent : AOMColor.hairline).frame(width: index == page ? 22 : 8, height: 6)
                }
            }
            .padding(.top, 16)
            Group {
                switch page {
                case 0: sections
                case 1: permissions
                default: howTo
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.top, 14)
            Divider()
            HStack {
                if page == 2 {
                    Toggle("Do not show this welcome message again", isOn: $dontShow).toggleStyle(.checkbox).font(AOMFont.caption)
                    // Gemini 7.10: without Accessibility there was no way out of this page.
                    if !axTrusted && !PresetManager.isUIPreview {
                        Button("Later") { finish(enable: false) }.buttonStyle(.borderless)
                    }
                } else {
                    Button("Skip") { finish(enable: false) }.buttonStyle(.borderless)
                }
                Spacer()
                if page > 0 { Button("Back") { withAnimation(.easeOut(duration: 0.18)) { page -= 1 } } }
                if page < 2 {
                    Button("Next") { withAnimation(.easeOut(duration: 0.18)) { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(modules.isOn(.menuBarHider) ? "Done" : "Start Hiding") { finish(enable: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!axTrusted && !PresetManager.isUIPreview)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 640, height: 540)
        .onReceive(tick) { _ in
            axTrusted = AXIsProcessTrusted()
            screenGranted = MenuBarItemImager.hasPermission
        }
    }

    private func finish(enable: Bool) {
        if enable, !modules.isOn(.menuBarHider) { _ = modules.set(.menuBarHider, on: true) }
        if dontShow { MenuBarPrefs.setupDone = true }
        if enable, axTrusted { MenuBarLayoutModel.shared.refresh() }
        done()
    }

    // MARK: Page 1 — the three sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Menu Bar Setup").font(.system(size: 22, weight: .bold))
            Text("With AOM you can set up your menu bar items to be:").font(.system(size: 14))
            VStack(spacing: 10) {
                sectionRow(.shown, icons: ["message.fill", "cloud.fill", "key.fill"],
                           text: "Always in your menu bar.")
                sectionRow(.hidden, icons: ["shippingbox.fill", "drop.fill", "pills.fill", "gauge.with.dots.needle.67percent"],
                           text: "Tucked away until you click ❮ or empty menu bar space, or open the Bar.")
                sectionRow(.alwaysHidden, icons: ["network", "keyboard.fill"],
                           text: "Out of sight until you ⌥-click ❮ or choose Show All.")
            }
            Text("You can also choose where new menu bar items go, and save layouts as presets.")
                .font(.system(size: 12.5)).foregroundStyle(AOMColor.textSecondary)
        }
    }

    private func sectionRow(_ section: MenuBarSection, icons: [String], text: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                ForEach(icons, id: \.self) { Image(systemName: $0).font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(width: 170, height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: NSColor(srgbRed: 0.16, green: 0.38, blue: 0.68, alpha: 1))))
            .opacity(section == .shown ? 1 : section == .hidden ? 0.75 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Label(section.title, systemImage: section.symbol).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(AOMColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
    }

    // MARK: Page 2 — permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow AOM to control menu bar items").font(.system(size: 22, weight: .bold))
            Text("AOM needs your permission to manage menu bar items. Follow these steps to authorize it:")
                .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            permissionCard(title: "Accessibility Permissions:", required: true,
                           detail: "AOM requires Accessibility access on your Mac so that it can show and hide your menu bar items and click them for you.",
                           granted: axTrusted, grantedText: "AOM has the required Accessibility Permissions",
                           button: "Open macOS Accessibility Settings") {
                AOMMenuShelfController.shared.requestPermission()
            }
            permissionCard(title: "Screen Recording Permissions:", required: false,
                           detail: "Optional. AOM uses Screen Recording only to draw each icon's real picture in Settings and the Bar; without it you see a symbol.",
                           granted: screenGranted, grantedText: "AOM has the Screen Recording Permissions",
                           button: "Open macOS Screen Recording Settings") {
                if !CGRequestScreenCaptureAccess(),
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("If a switch is off, turn on All of MacOS in the list. If it is missing, click + and choose All of MacOS in Applications.")
                .font(.system(size: 11.5)).foregroundStyle(AOMColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionCard(title: String, required: Bool, detail: String, granted: Bool, grantedText: String,
                                button: String, open: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle.dashed"))
                .font(.system(size: 22))
                .foregroundStyle(granted ? AOMColor.successText : (required ? AOMColor.warningText : AOMColor.textTertiary))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(AOMColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if granted {
                    Text(grantedText).font(.system(size: 12, weight: .medium)).foregroundStyle(AOMColor.successText)
                } else {
                    Button(button, action: open).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
    }

    // MARK: Page 3 — how to reach them

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to use it").font(.system(size: 22, weight: .bold))
            MenuBarSetupIllustration()
            if !axTrusted && !PresetManager.isUIPreview {
                Label("Allow Accessibility on the previous page to start hiding.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AOMColor.warningText)
            }
            VStack(alignment: .leading, spacing: 9) {
                step("cursorarrow.click", "Click ❮ in the menu bar — or empty space in the menu bar — to show your hidden icons. Click again to hide them; they also hide by themselves after 15 seconds.")
                step("option", "⌥-click ❮ to show the Always Hidden icons too.")
                step("cursorarrow.click.2", "Right-click ❮ for options: the Bar, hover, Search and Settings.")
                step("hand.draw", "In Menu Bar › Menu Bar Items, drag icons between Shown, Hidden and Always Hidden.")
                step("keyboard", "Menu Bar › Hotkeys gives keys to show icons, search them or open one directly.")
            }
        }
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(AOMColor.accent).frame(width: 20)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A drawn menu bar: app menus, the hidden icons that slide out, ❮, the
/// shown icons and the clock — the picture the How-to steps point at.
struct MenuBarSetupIllustration: View {
    @State private var expanded = false
    private let timer = Timer.publish(every: 1.6, tolerance: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo").font(.system(size: 12))
            Text("AOM").font(.system(size: 12, weight: .bold))
            Text("File  Edit  View").font(.system(size: 12))
            Spacer(minLength: 8)
            if expanded {
                HStack(spacing: 10) {
                    ForEach(["shippingbox.fill", "drop.fill", "pills.fill"], id: \.self) { Image(systemName: $0) }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Image(systemName: expanded ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .bold))
                .padding(4)
                .background(Circle().fill(Color.white.opacity(0.25)))
            ForEach(["message.fill", "cloud.fill", "battery.75percent", "wifi"], id: \.self) { Image(systemName: $0).font(.system(size: 12)) }
            Text("Sun 9:41").font(.system(size: 12))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.38, blue: 0.68), Color(red: 0.12, green: 0.30, blue: 0.56)],
                                 startPoint: .leading, endPoint: .trailing)))
        .animation(.easeInOut(duration: 0.35), value: expanded)
        .onReceive(timer) { _ in expanded.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A menu bar: clicking the chevron shows the hidden icons to its left")
    }
}
