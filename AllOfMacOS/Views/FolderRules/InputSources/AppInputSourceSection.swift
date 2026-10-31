import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings for per-app input sources (Input Source Pro-style): the switch,
/// "remember the last one for each app", and fixed sources per app. A self-
/// contained section; the integrator places it (see docs/folder-rules-3.4.0.md).
struct AppInputSourceSection: View {
    @ObservedObject private var memory = AppInputSourceMemory.shared
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let settings = memory.settings
        AOMSection("Input source per app", detail: settings.rules.isEmpty ? nil : "\(settings.rules.count) fixed",
                   help: "When an app comes to the front, AOM switches to its input source: a fixed one if you set it, otherwise the one you last used in that app.",
                   footer: memory.lastSwitch ?? "Nothing switches while AOM is paused or a password field is active.") {
            AOMToggleRow("Switch input sources per app",
                         detail: "For example ABC in Terminal and 2-Set Korean in KakaoTalk",
                         isOn: Binding(get: { memory.settings.isEnabled }, set: { memory.setEnabled($0) }))
            AOMToggleRow("Remember the last one in each app",
                         detail: "Apps without a fixed source get back the one you used in them last",
                         indent: true,
                         isOn: Binding(get: { memory.settings.remembersLastUsed }, set: { memory.setRemembersLastUsed($0) }))
                .aomDependentRows(enabled: settings.isEnabled)
            ForEach(settings.rules) { rule in
                AOMSettingRow(rule.appName, detail: rule.bundleID, indent: true) {
                    HStack(spacing: AOMSpace.x1) {
                        Picker(rule.appName, selection: Binding(get: { rule.sourceID }, set: { id in
                            if let source = memory.sources.first(where: { $0.id == id }) {
                                memory.setRule(bundleID: rule.bundleID, appName: rule.appName, source: source)
                            }
                        })) {
                            ForEach(sourceOptions(including: rule)) { source in Text(source.name).tag(source.id) }
                        }
                        .accessibilityLabel("Input source for \(rule.appName)")
                        AOMIconButton("minus.circle", label: "Remove \(rule.appName)") { remove(rule) }
                    }
                }
                .aomDependentRows(enabled: settings.isEnabled)
            }
            AOMSettingRow("Add an app", detail: "Choose an app, then its input source", indent: true) {
                Button("Add App…", action: addApp)
            }
            .aomDependentRows(enabled: settings.isEnabled)
        }
        .onAppear { memory.refreshSources() }
    }

    private func sourceOptions(including rule: AppInputSourceRule) -> [InputSources.Source] {
        var options = memory.sources
        if !options.contains(where: { $0.id == rule.sourceID }) {
            options.append(InputSources.Source(id: rule.sourceID, name: "\(rule.sourceName) (not enabled)"))
        }
        return options
    }

    private func remove(_ rule: AppInputSourceRule) {
        AOMUndo.perform("Remove App", undoManager: undoManager,
                        perform: { memory.removeRule(rule.id) },
                        revert: { memory.restoreRule(rule) })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose App"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                memory.refreshSources()
                let current = InputSources.currentID()
                guard let source = memory.sources.first(where: { $0.id == current }) ?? memory.sources.first else { return }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                memory.setRule(bundleID: id, appName: name, source: source)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}
