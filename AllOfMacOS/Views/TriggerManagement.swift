import SwiftUI

final class TriggerClipboard: ObservableObject {
    static let shared = TriggerClipboard()
    @Published var copied: Trigger?
    static func duplicate(_ source: Trigger) -> Trigger {
        var copy = source
        copy.id = UUID()
        copy.actions = source.actions.map(ActionTree.duplicate)
        return copy
    }
}

enum TriggerLabel {
    static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    static func color(_ label: String) -> Color {
        switch label {
        case "Red": return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green": return .green
        case "Blue": return .blue
        case "Purple": return .purple
        default:
            if label.hasPrefix("#"), label.count == 7, let value = UInt32(label.dropFirst(), radix: 16) {
                return Color(red: Double((value >> 16) & 255) / 255,
                             green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
            }
            return .gray
        }
    }
}

enum GestureSensitivity {
    static let globalVelocityKey = "AOMGlobalSwipeMinVelocity"
    static func velocity(for gesture: TrackpadGesture, defaults: UserDefaults = .standard) -> Double {
        let individual = defaults.double(forKey: "AOMSwipeMinVelocity_\(gesture.rawValue)")
        let global = defaults.double(forKey: globalVelocityKey)
        let value = individual.isFinite && individual > 0 ? individual : (global.isFinite && global > 0 ? global : 200)
        return min(2000, max(50, value))
    }
}

struct GestureSettingsView: View {
    @ObservedObject private var suppression = TriggerSuppression.shared
    @AppStorage("AOMGlobalSwipeMinVelocity") private var velocity = 200.0
    @AppStorage("AOMTipTapMinRestTime") private var tipTap = 0.12
    @AppStorage("AOMPressDragThreshold") private var drag = 300.0
    @AppStorage("AOMKeyboardLongPressMs") private var longPress = 500
    @AppStorage("AOMKeyboardQuickReleaseMaxMs") private var quickRelease = 250
    @AppStorage("AOMMouseLongPressMs") private var mouseLongPress = 500
    @AppStorage("AOMMouseDragThresholdPx") private var mouseDrag = 40

    var body: some View {
        Form {
            Section("Trackpad Sensitivity") {
                LabeledContent("Default swipe minimum speed", value: "\(Int(velocity)) pt/s")
                Slider(value: $velocity, in: 50...2000, step: 50)
                Text("Lower speeds recognize gentler swipes. Individual swipe overrides take priority; choose Use Global Default in the trigger settings to remove an override.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("TipTap resting time", value: "\(Int(tipTap * 1000)) ms")
                Slider(value: $tipTap, in: 0.05...0.5, step: 0.01)
                LabeledContent("Press-drag distance", value: "\(Int(drag)) pt")
                Slider(value: $drag, in: 50...1000, step: 25)
            }
            Section("Keyboard & Mouse") {
                Stepper("Keyboard long press: \(longPress) ms", value: $longPress, in: 100...5000, step: 50)
                Stepper("Keyboard quick release: \(quickRelease) ms", value: $quickRelease, in: 50...2000, step: 50)
                Stepper("Mouse long press: \(mouseLongPress) ms", value: $mouseLongPress, in: 100...5000, step: 50)
                Stepper("Mouse drag distance: \(mouseDrag) px", value: $mouseDrag, in: 5...500, step: 5)
            }
            Section("Prevent Accidental Gestures") {
                Toggle("Ignore trackpad gestures briefly after typing", isOn: $suppression.settings.disableTrackpadAfterKeyEnabled)
                Stepper("After typing: \(suppression.settings.disableTrackpadAfterKeyMs) ms",
                        value: $suppression.settings.disableTrackpadAfterKeyMs, in: 50...5000, step: 50)
                    .disabled(!suppression.settings.disableTrackpadAfterKeyEnabled)
                Text("Ignore trackpad, mouse and drawing gestures while holding:")
                HStack {
                    modifier("⌘", .command); modifier("⌥", .option)
                    modifier("⌃", .control); modifier("⇧", .shift); modifier("fn", .function)
                }
            }
            Button("Restore Gesture Defaults") {
                velocity = 200; tipTap = 0.12; drag = 300
                longPress = 500; quickRelease = 250; mouseLongPress = 500; mouseDrag = 40
                suppression.settings = TriggerSuppressionSettings()
            }
        }.formStyle(.grouped)
    }
    private func modifier(_ title: String, _ flag: NSEvent.ModifierFlags) -> some View {
        Toggle(title, isOn: Binding(get: { suppression.settings.disableWhileHoldingModifiers & flag.rawValue != 0 }, set: {
            if $0 { suppression.settings.disableWhileHoldingModifiers |= flag.rawValue }
            else { suppression.settings.disableWhileHoldingModifiers &= ~flag.rawValue }
        })).toggleStyle(.button)
    }
}

struct WorkflowVariableCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Automation") {
            Button("Workflow Variables…") { openWindow(id: "workflow-variables") }
        }
    }
}

struct WorkflowVariablesView: View {
    @State private var values = WorkflowVariables.snapshot()
    @State private var selection: String?
    @State private var name = ""
    @State private var value = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workflow Variables").font(.title2.bold())
            Text("Shared by your automations and saved across restarts. Do not store passwords.")
                .font(.caption).foregroundStyle(.secondary)
            List(values.keys.sorted(), id: \.self, selection: $selection) { key in
                HStack { Text(key).font(.body.monospaced()); Spacer(); Text(values[key] ?? "").lineLimit(1).foregroundStyle(.secondary) }
                    .tag(key)
            }
            HStack {
                TextField("Name", text: $name).frame(width: 180)
                TextField("Value", text: $value)
                Button("Save") {
                    if WorkflowVariables.set(name, value: value) { error = nil; refresh(); selection = name }
                    else { error = "Use 1–64 ASCII letters, digits or underscores; up to 512 characters per value and 128 variables." }
                }.disabled(name.isEmpty)
            }
            HStack {
                Button("New") { selection = nil; name = ""; value = ""; error = nil }
                Button("Delete", role: .destructive) {
                    if let selection { WorkflowVariables.remove(selection) }
                    selection = nil; name = ""; value = ""; refresh()
                }.disabled(selection == nil)
                Spacer()
                Text("\(values.count) / 128").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(minWidth: 560, minHeight: 360)
        .onChange(of: selection) { _, selected in
            if let selected { name = selected; value = values[selected] ?? ""; error = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkflowVariables.changed)) { _ in refresh() }
    }
    private func refresh() { values = WorkflowVariables.snapshot() }
}
