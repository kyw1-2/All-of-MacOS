import AppKit
import SwiftUI

/// 7.3: Window Tiling › Scenes — the scenes, each with its plan (what will
/// happen, what is already so, what can't run on this Mac now), Run, Run
/// Failed Steps and the last run's results; New and Edit open the editor.
struct ScenesSheet: View {
    @ObservedObject private var store = SceneStore.shared
    @ObservedObject private var runner = SceneRunner.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SceneProfile?
    @State private var previewing: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SnapSheetHeader(title: "Scenes") { dismiss() }
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                AOMEditorNote("A scene opens your apps, waits for their windows, arranges them with a saved layout, then sets the sound output, appearance, Keep Awake and Focus, and quits the apps you name — in that order. Each step says what it did; nothing that is already so is done twice.")
                if let problem = store.problem {
                    AOMNotice(problem.blocksSaving ? .error : .warning, problem.title, detail: problem.detail) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([problem.file]) }
                    }
                }
                if store.scenes.isEmpty {
                    AOMInlineEmpty(symbol: "theatermasks", message: "No scenes yet. A scene is one click for “Coding”, “Meeting” or “Writing”.")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: AOMSpace.x3) {
                        ForEach(store.scenes) { scene in sceneCard(scene) }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
                HStack {
                    if runner.isRunning, let step = runner.current {
                        ProgressView().controlSize(.small)
                        Text(step.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        Button("Cancel") { runner.cancel() }
                    }
                    Spacer()
                    Button("New Scene…") { editing = SceneProfile(name: "") }
                }
            }
            .padding(AOMSpace.x4)
        }
        .frame(width: AOMSize.readableText)
        .sheet(item: $editing) { scene in
            SceneEditor(scene: scene) { saved in
                store.save(saved)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func sceneCard(_ scene: SceneProfile) -> some View {
        let results = runner.results[scene.id]
        let failed = Set(results?.filter(\.isFailure).map(\.id) ?? [])
        return VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "theatermasks").foregroundStyle(AOMModule.tiling.hue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name).font(AOMFont.bodyEmphasis)
                    Text(ScenePlanner.steps(scene).map(\.title).joined(separator: " → "))
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(2)
                }
                Spacer(minLength: AOMSpace.x2)
                Button(previewing == scene.id ? "Hide Plan" : "Preview") { previewing = previewing == scene.id ? nil : scene.id }
                if !failed.isEmpty {
                    Button("Run Failed Steps") { runner.run(scene, only: failed) }.disabled(runner.isRunning)
                }
                Button("Run") { runner.run(scene) }.disabled(runner.isRunning)
                Menu {
                    Button("Edit…") { editing = scene }
                    Button("Delete", role: .destructive) { SceneStore.shared.delete(scene.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More for \(scene.name)")
            }
            if previewing == scene.id {
                stepList(ScenePlanner.preview(scene, state: .live()), preview: true)
            } else if let results {
                stepList(results, preview: false)
            }
        }
        .padding(AOMSpace.x3)
        .aomContentCard(radius: AOMRadius.card, padding: 0)
    }

    private func stepList(_ steps: [SceneStepResult], preview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview ? "Plan for now" : "Last run").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            ForEach(steps) { result in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(result.outcome, preview: preview))
                        .foregroundStyle(tint(result.outcome))
                        .accessibilityHidden(true)
                    Text(preview ? previewLine(result) : result.line)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func previewLine(_ result: SceneStepResult) -> String {
        switch result.outcome {
        case .already: return "\(result.step.title) — already so, skipped"
        case .skipped(let why): return "\(result.step.title) — can't run now: \(why)"
        default: return "\(result.step.stage): \(result.step.title)"
        }
    }

    private func symbol(_ outcome: SceneStepResult.Outcome, preview: Bool) -> String {
        switch outcome {
        case .done: return preview ? "circle" : "checkmark.circle.fill"
        case .already: return "equal.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private func tint(_ outcome: SceneStepResult.Outcome) -> Color {
        switch outcome {
        case .done: return AOMColor.successText
        case .already: return AOMColor.textSecondary
        case .skipped, .cancelled: return AOMColor.warningText
        case .failed: return AOMColor.dangerText
        }
    }
}

/// The scene editor: each stage in running order, the problems that stop
/// Save (an app set to open and to quit, no name, no step).
struct SceneEditor: View {
    @State var scene: SceneProfile
    let onSave: (SceneProfile) -> Void
    let onCancel: () -> Void
    @ObservedObject private var windows = WindowManager.shared
    /// Read once when the editor opens, not on every keystroke (7.3 review).
    @State private var outputs: [AudioOutputDevice] = []
    @State private var automationRevision = 0

    private static let keepAwakeChoices: [(String, Int?)] = [("Leave as it is", nil), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("Until turned off", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SnapSheetHeader(title: scene.name.isEmpty ? "New Scene" : scene.name) { onCancel() }
            Form {
                TextField("Name", text: $scene.name, prompt: Text("Coding, Meeting, Writing…"))
                Section("1 · Open apps") {
                    appList($scene.launchApps, waits: true)
                }
                Section("2 · Arrange windows") {
                    Picker("Saved layout", selection: $scene.layoutName) {
                        Text("Leave windows as they are").tag(String?.none)
                        ForEach(windows.layouts) { Text($0.name).tag(Optional($0.name)) }
                    }
                    if windows.layouts.isEmpty {
                        AOMEditorNote("Save a layout first in Window Tiling › Saved Windows.")
                    }
                }
                Section("3 · Sound, appearance, Keep Awake") {
                    HStack {
                        Text("Sound output")
                        Spacer()
                        Text(scene.audio?.name ?? "Leave as it is").foregroundStyle(AOMColor.textSecondary)
                        Menu("Choose") {
                            Button("Leave as it is") { scene.audio = nil }
                            Divider()
                            ForEach(outputs) { device in
                                Button(device.name) {
                                    scene.audio = SceneAudioTarget(uid: device.uid, name: device.name, transport: SceneAudio.transport(of: device.id))
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Picker("Appearance", selection: $scene.appearance) {
                        Text("Leave as it is").tag(SceneAppearance?.none)
                        ForEach(SceneAppearance.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Keep Awake", selection: $scene.keepAwakeMinutes) {
                        ForEach(Self.keepAwakeChoices, id: \.0) { Text($0.0).tag($0.1) }
                    }
                }
                Section("4 · Focus") {
                    Toggle("Start a Focus session (your saved length)", isOn: $scene.startsFocus)
                    AOMEditorNote("AOM's Focus timer; macOS Focus (Do Not Disturb) is separate — add a Shortcut for it in Automation if you want both.")
                }
                Section("5 · Quit apps (last)") {
                    appList($scene.quitApps, waits: false)
                    AOMEditorNote("Apps are asked to quit like ⌘Q: one with unsaved work asks you first.")
                }
                // 7.22 (DeepSeek 7.21 report §4.6): the scene runs by itself.
                Section("6 · Run by itself") {
                    let triggers = automationRevision >= 0 ? SceneAutomation.triggers(for: scene, in: AppState.current?.currentPreset.triggers ?? []) : []
                    ForEach(triggers) { trigger in
                        Label(trigger.input.displayName, systemImage: "bolt").foregroundStyle(trigger.isEnabled ? AOMColor.text : AOMColor.textSecondary)
                    }
                    Menu("Add a Trigger") {
                        ForEach(SceneAutomation.choices, id: \.title) { choice in
                            Button(choice.title) { SceneAutomation.add(choice.kind, for: scene); automationRevision += 1 }
                        }
                    }
                    .fixedSize()
                    .disabled(scene.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    AOMEditorNote("Adds an automation that runs this scene; change or remove it in Automation › Other Triggers. Save the scene first if it is new.")
                }
                if !scene.problems.isEmpty {
                    Section {
                        ForEach(scene.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(AOMColor.warningText)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave(scene) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scene.problems.isEmpty)
            }
            .padding(AOMSpace.x3)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            AudioOutputService.invalidateDeviceCache()
            outputs = AudioOutputService.devices()
        }
    }

    private func appList(_ apps: Binding<[SceneApp]>, waits: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(apps.wrappedValue) { app in
                HStack {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    }
                    Text(app.name)
                    Spacer()
                    if waits {
                        Toggle("Wait for its window", isOn: Binding(get: { app.waitsForWindow }, set: { on in
                            if let index = apps.wrappedValue.firstIndex(of: app) { apps.wrappedValue[index].waitsForWindow = on }
                        }))
                        .toggleStyle(.checkbox)
                        .help("Off for apps that have no windows (menu bar apps)")
                    }
                    Button { apps.wrappedValue.removeAll { $0.bundleID == app.bundleID } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(app.name)")
                }
            }
            Menu("Add App") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !apps.wrappedValue.map(\.bundleID).contains($0.bundleIdentifier!) }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { running in
                    Button(running.localizedName ?? running.bundleIdentifier ?? "App") {
                        apps.wrappedValue.append(SceneApp(bundleID: running.bundleIdentifier ?? "", name: running.localizedName ?? ""))
                    }
                }
                Divider()
                Button("Choose App…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                          !apps.wrappedValue.map(\.bundleID).contains(id) else { return }
                    apps.wrappedValue.append(SceneApp(bundleID: id, name: FileManager.default.displayName(atPath: url.path)
                        .replacingOccurrences(of: ".app", with: "")))
                }
            }
            .fixedSize()
        }
    }
}


/// 7.22: automations that run a scene (Run Scene action), made from the
/// scene editor.
@MainActor
enum SceneAutomation {
    struct Choice { let title: String; let kind: SystemTriggerKind }
    static let choices: [Choice] = [
        Choice(title: "When the microphone turns on", kind: .microphoneInUse(active: true)),
        Choice(title: "When the microphone turns off", kind: .microphoneInUse(active: false)),
        Choice(title: "When a display connects or disconnects", kind: .displayChanged),
        Choice(title: "When Wi-Fi connects", kind: .wifiConnected(ssid: "")),
        Choice(title: "When power is connected", kind: .powerSourceChanged(ac: true)),
        Choice(title: "When the Mac wakes", kind: .systemDidWake),
    ]

    static func triggers(for scene: SceneProfile, in triggers: [Trigger]) -> [Trigger] {
        triggers.filter { trigger in
            guard case .systemEvent = trigger.input else { return false }
            return trigger.actions.contains { $0.actionType == .runScene && $0.parameters.sceneID == scene.id.uuidString }
        }
    }

    static func add(_ kind: SystemTriggerKind, for scene: SceneProfile) {
        guard let state = AppState.current else { return }
        var parameters = ActionParameters()
        parameters.sceneID = scene.id.uuidString
        parameters.sceneName = scene.name
        var trigger = Trigger(name: "Scene: \(scene.name)", input: .systemEvent(kind))
        trigger.actions = [TriggerAction(actionType: .runScene, parameters: parameters)]
        state.addTrigger(trigger)
        GestureHUD.shared.show(title: "Automation Added", detail: "\(scene.name) runs \(kind.displayName.lowercased()).")
    }
}
