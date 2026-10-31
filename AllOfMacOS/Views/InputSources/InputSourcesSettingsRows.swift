import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › General › Input sources (3.4, Input Source Pro parity): the
/// switch, one row per app rule, Remember, and the source for other apps.
/// Every value is the stored preference; the switcher starts or stops with
/// the switch.
@MainActor
final class InputSourcesSettingsModel: ObservableObject {
    static let shared = InputSourcesSettingsModel()
    private let settings = AppInputSourcesSettings()

    @Published var isEnabled: Bool { didSet { settings.isEnabled = isEnabled; AppInputSources.shared.refresh() } }
    @Published var remembers: Bool { didSet { settings.remembers = remembers } }
    @Published var fallback: String { didSet { settings.fallback = fallback.isEmpty ? nil : fallback } }
    @Published var rules: [AppInputSourcesRule] { didSet { settings.rules = rules } }
    /// The keyboard input sources turned on in System Settings, read when
    /// the pane appears.
    @Published private(set) var sources: [InputSources.Source] = []

    private init() {
        isEnabled = settings.isEnabled
        remembers = settings.remembers
        fallback = settings.fallback ?? ""
        rules = settings.rules
    }

    func reloadSources() { sources = InputSources.enabled() }

    func name(of sourceID: String) -> String {
        sources.first { $0.id == sourceID }?.name ?? "Not Enabled (\(sourceID.components(separatedBy: ".").last ?? sourceID))"
    }

    func add(bundleID: String, name: String) {
        guard !rules.contains(where: { $0.bundleID == bundleID }) else { return }
        let source = InputSources.currentID() ?? sources.first?.id ?? ""
        rules.append(AppInputSourcesRule(bundleID: bundleID, appName: name, inputSourceID: source))
    }

    func remove(_ rule: AppInputSourcesRule) { rules.removeAll { $0.bundleID == rule.bundleID } }

    func set(_ sourceID: String, for rule: AppInputSourcesRule) {
        guard let index = rules.firstIndex(where: { $0.bundleID == rule.bundleID }) else { return }
        rules[index].inputSourceID = sourceID
    }

    /// Running apps people type in, for Add App (not AOM, not those with a rule).
    var runningCandidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !rules.map(\.bundleID).contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

/// The switch row.
struct InputSourcesSwitchRow: View {
    @ObservedObject private var model = InputSourcesSettingsModel.shared

    var body: some View {
        HubRowShell(icon: "keyboard.badge.ellipsis", tint: .indigo, title: "Switch input sources by app",
                    subtitle: "Each app types in the input source you choose, for example Terminal in English and KakaoTalk in Korean",
                    onLabelTap: { model.isEnabled.toggle() }) {
            Toggle("Switch input sources by app", isOn: $model.isEnabled)
                .labelsHidden()
                .toggleStyle(AOMRowSwitchStyle())
        }
    }
}

/// One row per app rule, then Add App.
struct InputSourcesRulesRows: View {
    @ObservedObject private var model = InputSourcesSettingsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                ruleRow(rule)
                    .overlay(alignment: .top) { if index > 0 { AOMRowDivider(inset: AOMSpace.rowSymbolInset) } }
            }
            HStack(spacing: AOMSpace.x2) {
                if model.rules.isEmpty {
                    // The empty state shares the row with Add App (one line, not two).
                    Image(systemName: "app.badge")
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row)
                        .accessibilityHidden(true)
                    Text("No apps yet. Add the apps you type in, then pick each one's input source.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AOMSpace.x3)
                Menu("Add App") {
                    ForEach(model.runningCandidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            model.add(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "")
                        }
                    }
                    if !model.runningCandidates.isEmpty { Divider() }
                    Button("Choose App…") { chooseApp() }
                }
                .fixedSize()
                .help("Add an open app, or choose one from Applications")
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .overlay(alignment: .top) { if !model.rules.isEmpty { AOMRowDivider() } }
        }
        .dependentSetting(on: model.isEnabled)
        .onAppear { model.reloadSources() }
    }

    private func ruleRow(_ rule: AppInputSourcesRule) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(nsImage: Self.icon(for: rule.bundleID))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: AOMIcon.row, height: AOMIcon.row)
                .accessibilityHidden(true)
            Text(rule.appName.isEmpty ? rule.bundleID : rule.appName)
                .font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                .help(rule.bundleID)
            Spacer(minLength: AOMSpace.x3)
            Picker("Input source for \(rule.appName)", selection: Binding(
                get: { rule.inputSourceID }, set: { model.set($0, for: rule) })) {
                ForEach(model.sources) { Text($0.name).tag($0.id) }
                if !model.sources.contains(where: { $0.id == rule.inputSourceID }) {
                    Text(model.name(of: rule.inputSourceID)).tag(rule.inputSourceID)
                }
            }
            .labelsHidden()
            .fixedSize()
            AOMIconButton("minus.circle", label: "Remove \(rule.appName)") { model.remove(rule) }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.rowStandard)
        .contextMenu {
            Button("Remove") { model.remove(rule) }
        }
    }

    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        model.add(bundleID: bundleID, name: name)
    }
}

/// Remember the last input source in apps without a rule.
struct InputSourcesRememberRow: View {
    @ObservedObject private var model = InputSourcesSettingsModel.shared

    var body: some View {
        HubRowShell(icon: "clock.arrow.circlepath", tint: .indigo, title: "Remember in other apps",
                    subtitle: "Apps without a rule get back the input source they used last",
                    onLabelTap: { model.remembers.toggle() }) {
            Toggle("Remember in other apps", isOn: $model.remembers)
                .labelsHidden()
                .toggleStyle(AOMRowSwitchStyle())
        }
        .dependentSetting(on: model.isEnabled)
    }
}

/// The input source for apps without a rule (or nothing to remember).
struct InputSourcesFallbackRow: View {
    @ObservedObject private var model = InputSourcesSettingsModel.shared

    var body: some View {
        HubRowShell(icon: "keyboard", tint: .indigo, title: "Other apps", subtitle: "") {
            Picker("Other apps", selection: $model.fallback) {
                Text("Leave As Is").tag("")
                ForEach(model.sources) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .dependentSetting(on: model.isEnabled)
        .onAppear { model.reloadSources() }
    }
}
