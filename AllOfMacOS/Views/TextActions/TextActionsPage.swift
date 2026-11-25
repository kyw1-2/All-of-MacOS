import AppKit
import SwiftUI

/// What the Text Actions list shows.
enum TextActionsPageItem: Hashable {
    case bar, excludedApps, clickHints, action(TextActionID)

    /// For `--aom-preview-text-actions-item <bar|excluded|actionID>`.
    init?(previewName: String) {
        switch previewName {
        case "bar": self = .bar
        case "excluded": self = .excludedApps
        case "clickHints": self = .clickHints
        default:
            guard let id = TextActionID(rawValue: previewName) else { return nil }
            self = .action(id)
        }
    }
}

/// The Text Actions page (design-3.4.0 b.2, list + detail): the list holds
/// the bar itself, the excluded apps and every action with its switch, in
/// the bar's order (drag, Move Up and Move Down reorder it; all undoable);
/// the detail edits the selected one, with a live preview of the bar.
struct TextActionsPage: View {
    @ObservedObject private var preferences = TextActionsPreferences.shared
    @AppStorage("AOMTextActionsListWidth") private var listWidth = AOMSize.moduleListIdeal
    @State private var selection: TextActionsPageItem? = Self.initialSelection()
    @State private var sample: TextActionsPreviewSample = .text
    @State private var showsPreview = true
    @State private var arrangement: AOMWorkbenchArrangement = .listDetail
    @State private var dragScope = UUID()
    @State private var dropTarget: TextActionID?
    @Environment(\.undoManager) private var undoManager

    private var settings: TextActionsSettings { preferences.settings }
    private var previewAvailable: Bool { selection == nil || selection == .bar || selectedAction != nil }
    private var previewRequested: Binding<Bool> {
        Binding(get: { showsPreview && previewAvailable }, set: { showsPreview = $0 })
    }

    var body: some View {
        AOMListDetail(listWidth: $listWidth, showsInspector: previewRequested, narrowInspector: .inDetail,
                      onArrangementChange: { arrangement = $0 }) {
            AOMListColumn(rows: { list }, footer: { footer })
        } detail: {
            VStack(spacing: 0) {
                detail
                if previewRequested.wrappedValue && !arrangement.showsInspectorBeside {
                    AOMDivider()
                    previewPane
                }
            }
        } inspector: {
            previewPane.frame(maxHeight: .infinity, alignment: .top)
        }
        .aomListDetailSelection(selection)
        .aomPage("Text Actions")
        .aomPageToolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Live Preview", isOn: $showsPreview).disabled(!previewAvailable)
                    Divider()
                    Button("Turn On Every Action") { setAll(on: true) }
                    Button("Restore the Default Actions") { restoreDefaults() }
                } label: {
                    Label("Text Actions Options", systemImage: "slider.horizontal.3")
                }
                .help("Text Actions Options")
            }
        }
        .task { previewSetup() }
    }

    private var previewPane: some View {
        var previewSettings = settings
        if let id = selectedAction { previewSettings.setAction(id, isOn: true) }
        return TextActionsPreviewPane(settings: previewSettings, selectedAction: selectedAction,
                                      actionIsOn: selectedAction.map { settings.isOn($0) } ?? true,
                                      sample: selectedAction.map(TextActionsPreviewSample.best(for:)) ?? sample,
                                      barSample: $sample)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            Section {
                AOMListRow("Selection Bar", detail: settings.isOn ? "On" : "Off", dimmed: !settings.isOn) {
                    Image(systemName: "character.cursor.ibeam")
                }
                .tag(TextActionsPageItem.bar)
                AOMListRow("Excluded Apps", detail: settings.excludedApps.isEmpty ? "None"
                                                     : TextActionsExcludedAppsDetail.count(settings.excludedApps.count)) {
                    Image(systemName: "hand.raised")
                }
                .tag(TextActionsPageItem.excludedApps)
                ClickHintsListRow()
                    .tag(TextActionsPageItem.clickHints)
            }
            Section("Actions") {
                ForEach(settings.actions) { action in
                    AOMListRow(action.id.title, detail: Self.rowDetail(action), dimmed: !action.isOn) {
                        Image(systemName: action.id.symbol)
                    } trailing: {
                        Toggle(action.id.title, isOn: switchBinding(action.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help(action.isOn ? "Leave \(action.id.title) off the bar" : "Put \(action.id.title) on the bar")
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(AOMColor.textTertiary)
                            .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                            .contentShape(Rectangle())
                            .draggable("\(dragScope.uuidString):\(action.id.rawValue)")
                            .help("Drag to reorder; Option–Up or Option–Down also moves the selected action")
                            .accessibilityHidden(true)
                    }
                    .aomDropTarget(dropTarget == action.id, radius: AOMRadius.well)
                    .dropDestination(for: String.self) { values, location in
                        guard values.count == 1, let payload = values.first else { return false }
                        return drop(payload, at: action.id, after: location.y > AOMSize.rowDetail / 2)
                    } isTargeted: { targeted in
                        if targeted { dropTarget = action.id }
                        else if dropTarget == action.id { dropTarget = nil }
                    }
                    .tag(TextActionsPageItem.action(action.id))
                    .contextMenu {
                        Button(action.isOn ? "Turn Off" : "Turn On") { setAction(action.id, isOn: !action.isOn) }
                        Button("Move Up") { move(action.id, by: -1) }.disabled(!canMove(action.id, by: -1))
                        Button("Move Down") { move(action.id, by: 1) }.disabled(!canMove(action.id, by: 1))
                    }
                }
            }
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers == .option else { return .ignored }
            let offset = press.key == .upArrow ? -1 : 1
            guard canMoveSelected(by: offset) else { return .ignored }
            moveSelected(by: offset)
            return .handled
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .accessibilityLabel("Text Actions")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            AOMDivider()
            HStack(spacing: AOMSpace.x0_5) {
                AOMIconButton("arrow.up", label: "Move Up") { moveSelected(by: -1) }
                    .disabled(!canMoveSelected(by: -1))
                AOMIconButton("arrow.down", label: "Move Down") { moveSelected(by: 1) }
                    .disabled(!canMoveSelected(by: 1))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x1)
            .padding(.vertical, AOMSpace.x0_5)
        }
    }

    static func rowDetail(_ action: TextActionsSettings.Action) -> String {
        guard action.isOn else { return "Off" }
        switch action.id {
        case .cut, .paste: return "In text you can edit"
        case .openLink: return "For web addresses"
        case .newEmail: return "For email addresses"
        case .calculate: return "For sums"
        case .formatJSON: return "For JSON"
        case .askChatGPT: return "With the ChatGPT app"
        case .lookUp: return "For words"
        default: return "On"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .bar {
        case .bar:
            TextActionsBarDetail(settings: $preferences.settings)
        case .excludedApps:
            TextActionsExcludedAppsDetail(settings: $preferences.settings)
        case .clickHints:
            ClickHintsDetail()
        case .action(let id):
            TextActionDetail(id: id, settings: $preferences.settings)
                .id(id)
        }
    }

    // MARK: Editing (undoable)

    private func switchBinding(_ id: TextActionID) -> Binding<Bool> {
        Binding(get: { preferences.settings.isOn(id) }, set: { setAction(id, isOn: $0) })
    }

    private func change(_ name: String, _ edit: (inout TextActionsSettings) -> Void) {
        let before = preferences.settings
        var after = before
        edit(&after)
        guard after != before else { return }
        AOMUndo.perform(name, undoManager: undoManager,
                        perform: { preferences.settings = after }, revert: { preferences.settings = before })
    }

    private func setAction(_ id: TextActionID, isOn: Bool) {
        change(isOn ? "Turn On \(id.title)" : "Turn Off \(id.title)") { $0.setAction(id, isOn: isOn) }
    }

    private func setAll(on: Bool) {
        change("Turn On Every Action") { settings in
            for id in TextActionID.allCases { settings.setAction(id, isOn: on) }
        }
    }

    private func restoreDefaults() {
        change("Restore the Default Actions") { $0.actions = TextActionsSettings.defaultActions }
    }

    private func drop(_ payload: String, at target: TextActionID, after: Bool) -> Bool {
        let prefix = dragScope.uuidString + ":"
        guard payload.hasPrefix(prefix), let source = TextActionID(rawValue: String(payload.dropFirst(prefix.count))),
              source != target,
              let from = settings.actions.firstIndex(where: { $0.id == source }),
              let to = settings.actions.firstIndex(where: { $0.id == target }) else { return false }
        change("Move Action") { $0.actions.move(fromOffsets: IndexSet(integer: from), toOffset: to + (after ? 1 : 0)) }
        selection = .action(source)
        return true
    }

    private func canMove(_ id: TextActionID, by offset: Int) -> Bool {
        guard let index = settings.actions.firstIndex(where: { $0.id == id }) else { return false }
        return settings.actions.indices.contains(index + offset)
    }

    private func move(_ id: TextActionID, by offset: Int) {
        change("Move Action") { $0.moveAction(id, by: offset) }
    }

    private var selectedAction: TextActionID? {
        if case .action(let id) = selection { return id }
        return nil
    }

    private func canMoveSelected(by offset: Int) -> Bool {
        selectedAction.map { canMove($0, by: offset) } ?? false
    }

    private func moveSelected(by offset: Int) {
        if let id = selectedAction { move(id, by: offset) }
    }

    // MARK: Isolated UI previews

    /// The item the page opens on: Selection Bar, or in an isolated UI
    /// preview the one `--aom-preview-text-actions-item <bar|excluded|actionID>` names.
    static func initialSelection(arguments: [String] = ProcessInfo.processInfo.arguments) -> TextActionsPageItem {
        guard PresetManager.isUIPreview, let index = arguments.firstIndex(of: "--aom-preview-text-actions-item"),
              arguments.indices.contains(index + 1),
              let item = TextActionsPageItem(previewName: arguments[index + 1]) else { return .bar }
        return item
    }

    /// `--aom-preview-text-actions-on` turns the bar on (in memory: previews
    /// never save), `--aom-preview-text-actions-names` shows names and
    /// `--aom-preview-text-actions-bar` also shows the real floating bar.
    private func previewSetup() {
        guard PresetManager.isUIPreview else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--aom-preview-sample-data") { preferences.settings.actions = TextActionsSettings.defaultActions }
        if args.contains("--aom-preview-text-actions-on") { preferences.settings.isOn = true }
        if args.contains("--aom-preview-text-actions-names") { preferences.settings.showsNames = true }
        if args.contains("--aom-preview-text-actions-bar") {
            TextActionsController.shared.showPreviewBar(sample: TextActionsPreviewSample.text.text)
        }
    }
}
