import AppKit
import SwiftUI

struct WindowPinningCard: View {
    @ObservedObject private var service = WindowPinningService.shared
    @State private var showsOptions = false

    var body: some View {
        // The count only while something is pinned; an empty card needs no "Ready".
        AOMSection("Always on Top", detail: service.pins.isEmpty ? nil : "\(service.pins.count) pinned",
                   help: "Pin a window above other apps. Move, resize and use its original window while it stays pinned. A Window Management action in an automation can pin windows too.",
                   footer: "Set shortcuts in Settings › Shortcuts.",
                   padding: AOMSpace.cardPadding) {
            Button { showsOptions = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("Always on Top options")
                .accessibilityLabel("Always on Top options")
        } content: {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                // Two equal secondary buttons: pinning is not this page's
                // primary action, so neither one is prominent.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AOMSpace.x2) { chooseButton; selectButton }
                    VStack(alignment: .leading, spacing: AOMSpace.x2) { chooseButton; selectButton }
                }
                .buttonStyle(.bordered)
                .disabled(service.isChoosingWindow)
                if let error = service.lastError {
                    Text(error).font(AOMFont.caption).foregroundStyle(AOMColor.dangerText).textSelection(.enabled)
                }
                ForEach(service.pins) { pin in
                    AOMDivider()
                    PinnedWindowRow(pin: pin)
                }
                if !service.pins.isEmpty {
                    Button("Unpin All Windows") { service.unpinAll() }
                }
            }
        }
        .sheet(isPresented: $showsOptions) { WindowPinningOptionsView() }
    }
    private var chooseButton: some View {
        Button("Choose Window…") { service.chooseWindow() }
    }
    private var selectButton: some View {
        Button("Select on Screen…") { service.selectWindow() }
    }
}

private struct PinnedWindowRow: View {
    @ObservedObject var pin: LivePinnedWindow
    private let service = WindowPinningService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(pin.title).font(AOMFont.body).lineLimit(1).help(pin.title)
                    Text("\(pin.appName)\(pin.isPaused ? " · Paused" : "")")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x1)
                Button { service.togglePause(pin) } label: { Image(systemName: pin.isPaused ? "play" : "pause") }
                    .help(pin.isPaused ? "Resume pin" : "Pause pin")
                    .accessibilityLabel(pin.isPaused ? "Resume \(pin.title)" : "Pause \(pin.title)")
                Button { service.unpin(pin.id) } label: { Image(systemName: "pin.slash") }
                    .help("Unpin window").accessibilityLabel("Unpin \(pin.title)")
            }
            HStack(spacing: AOMSpace.x2) {
                Text("Opacity").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                Slider(value: Binding(get: { pin.opacity }, set: { service.setOpacity($0, for: pin) }), in: 0.2...1)
                    .controlSize(.small)
                    .accessibilityLabel("Opacity of \(pin.title)")
                Text("\(Int((pin.opacity * 100).rounded()))%")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMFeatureSize.sliderValue, alignment: .trailing)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct WindowPinningOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WindowPinningService.shared
    @State private var newBundleID = ""
    /// A form sheet (`AOMFeatureSize.sheetStandard` wide) that shows its four
    /// short sections without scrolling on a laptop display.
    private static let sheetHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            // The sheet header every tiling sheet shares: title left, Done right.
            HStack {
                Text("Always on Top")
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x3)
            AOMDivider()
            Form {
                Section("Interaction") {
                    Picker("Activate pinned window", selection: $service.options.activation) {
                        ForEach(WindowPinningOptions.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Click modes preserve keyboard focus when the pointer passes over a pin. Activate the window first, then interact with it.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    Toggle("Duck overlapping pins while using a pinned window", isOn: $service.options.duckOverlappingWindows)
                }
                Section("Appearance") {
                    Picker("Control button position", selection: $service.options.corner) {
                        ForEach(WindowPinningOptions.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Maximum refresh rate", selection: $service.options.maximumFPS) {
                        Text("30 Hz").tag(30); Text("60 Hz").tag(60); Text("120 Hz").tag(120); Text("Display Refresh Rate").tag(0)
                    }
                    Toggle("Border for translucent windows", isOn: $service.options.translucentBorder)
                }
                Section("App filter") {
                    Toggle("Show windows without a title", isOn: $service.options.showUntitledWindows)
                    ForEach(service.options.excludedBundleIDs, id: \.self) { bundle in
                        HStack {
                            Text(bundle).lineLimit(1)
                            Spacer()
                            Button("Remove") { service.options.excludedBundleIDs.removeAll { $0 == bundle } }
                        }
                    }
                    HStack {
                        TextField("App bundle ID (com.example.app)", text: $newBundleID)
                        Button("Exclude") { exclude(newBundleID); newBundleID = "" }
                            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Menu("Exclude a Running App") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier {
                                Button(app.localizedName ?? id) { exclude(id) }
                            }
                        }
                    }
                }
                Section("Permissions") {
                    Text("Live window pinning uses Screen Recording and Accessibility. Captured frames stay in memory and are not saved.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    HStack {
                        Button("Accessibility…") { openPrivacy("Accessibility") }
                        Button("Screen Recording…") { openPrivacy("ScreenCapture") }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: AOMFeatureSize.sheetStandard, height: Self.sheetHeight)
    }
    private func exclude(_ raw: String) {
        let bundle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, !service.options.excludedBundleIDs.contains(bundle) else { return }
        service.options.excludedBundleIDs.append(bundle)
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }
}
