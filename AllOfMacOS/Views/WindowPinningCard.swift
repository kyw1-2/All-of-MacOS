import AppKit
import SwiftUI

struct WindowPinningCard: View {
    @ObservedObject private var service = WindowPinningService.shared
    @State private var showsOptions = false

    var body: some View {
        AOMSection("Always on Top", detail: service.pins.isEmpty ? "Ready" : "\(service.pins.count) pinned",
                   help: "Pin a window above other apps. Move, resize and use its original window while it stays pinned.",
                   footer: "Assign pinning shortcuts in Settings → Shortcuts, or add a Window Management action to an automation.",
                   padding: AOMSpace.cardPadding) {
            Button { showsOptions = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("Window pinning options")
                .accessibilityLabel("Window pinning options")
        } content: {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                ViewThatFits(in: .horizontal) {
                    HStack { chooseButton; selectButton }
                    VStack(alignment: .leading) { chooseButton; selectButton }
                }
                .disabled(service.isChoosingWindow)
                if let error = service.lastError {
                    Text(error).font(AOMFont.caption).foregroundStyle(AOMColor.dangerText).textSelection(.enabled)
                }
                ForEach(service.pins) { pin in
                    Divider()
                    PinnedWindowRow(pin: pin)
                }
                if !service.pins.isEmpty {
                    Button("Unpin All Windows") { service.unpinAll() }.controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showsOptions) { WindowPinningOptionsView() }
    }
    private var chooseButton: some View {
        Button("Choose Window…") { service.chooseWindow() }.buttonStyle(.borderedProminent).controlSize(.small)
    }
    private var selectButton: some View {
        Button("Select on Screen…") { service.selectWindow() }.controlSize(.small)
    }
}

private struct PinnedWindowRow: View {
    @ObservedObject var pin: LivePinnedWindow
    private let service = WindowPinningService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.title).font(AOMType.body).lineLimit(1).help(pin.title)
                    Text("\(pin.appName)\(pin.isPaused ? " · Paused" : "")")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                }
                Spacer(minLength: 4)
                Button { service.togglePause(pin) } label: { Image(systemName: pin.isPaused ? "play" : "pause") }
                    .help(pin.isPaused ? "Resume pin" : "Pause pin")
                    .accessibilityLabel(pin.isPaused ? "Resume \(pin.title)" : "Pause \(pin.title)")
                Button { service.unpin(pin.id) } label: { Image(systemName: "pin.slash") }
                    .help("Unpin window").accessibilityLabel("Unpin \(pin.title)")
            }
            HStack {
                Text("Opacity").font(AOMType.caption)
                Slider(value: Binding(get: { pin.opacity }, set: { service.setOpacity($0, for: pin) }), in: 0.2...1)
                    .accessibilityLabel("Opacity of \(pin.title)")
                Text("\(Int((pin.opacity * 100).rounded()))%")
                    .font(AOMType.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct WindowPinningOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WindowPinningService.shared
    @State private var newBundleID = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Window Pinning").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Form {
                Section("Interaction") {
                    Picker("Activate Pinned Window", selection: $service.options.activation) {
                        ForEach(WindowPinningOptions.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Click modes preserve keyboard focus when the pointer passes over a pin. Activate the window first, then interact with it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Duck overlapping pins while using a pinned window", isOn: $service.options.duckOverlappingWindows)
                }
                Section("Appearance") {
                    Picker("Control Button Position", selection: $service.options.corner) {
                        ForEach(WindowPinningOptions.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Maximum Refresh Rate", selection: $service.options.maximumFPS) {
                        Text("30 Hz").tag(30); Text("60 Hz").tag(60); Text("120 Hz").tag(120); Text("Display Refresh Rate").tag(0)
                    }
                    Toggle("Border for translucent windows", isOn: $service.options.translucentBorder)
                }
                Section("App Filter") {
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
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Accessibility…") { openPrivacy("Accessibility") }
                        Button("Screen Recording…") { openPrivacy("ScreenCapture") }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 650)
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
