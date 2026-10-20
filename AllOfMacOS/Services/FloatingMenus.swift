import AppKit
import SwiftUI

/// Native AOM format. Each item runs an ordinary action sequence, so menus use
/// the same cancellation, validation and permissions as keyboard triggers.
struct FloatingMenuItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title = "New item"
    var symbol = "bolt"
    var kind = "button" // button, variable, clock
    var variableName = ""
    var actions: [TriggerAction] = []
}
struct FloatingMenuDefinition: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "My Menu"
    var columns = 2
    var staysOpen = false
    /// Optional for archives written before anchored menus were available.
    var placement: String? = nil // pointer, center, notch
    var items: [FloatingMenuItem] = [FloatingMenuItem()]

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...6).contains(columns), items.count <= 100,
              ["pointer", "center", "notch"].contains(placement ?? "pointer"),
              Set(items.map(\.id)).count == items.count else { throw MenuError.invalid }
        for item in items {
            guard ["button", "clock", "variable"].contains(item.kind), item.title.count <= 500,
                  item.actions.count <= 100 else { throw MenuError.invalid }
            if ActionTree.problem(item.actions) != nil { throw MenuError.invalid }
            for action in item.actions {
                if ActionParameterValidation.problem(for: action) != nil { throw MenuError.invalid }
            }
        }
    }
    enum MenuError: LocalizedError {
        case invalid
        var errorDescription: String? { "Use a name, 1–6 columns, up to 100 unique items, and valid actions. Item kind must be button, clock, or variable." }
    }
}

final class FloatingMenuStore: ObservableObject {
    static let shared = FloatingMenuStore()
    @Published private(set) var menus: [FloatingMenuDefinition]
    private let defaults: UserDefaults
    private let key = "AOMFloatingMenusV1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 4_194_304,
           let decoded = try? JSONDecoder().decode([FloatingMenuDefinition].self, from: data) {
            var ids = Set<UUID>()
            menus = Array(decoded.filter { (try? $0.validate()) != nil && ids.insert($0.id).inserted }.prefix(100))
        } else { menus = [] }
    }
    func save(_ menu: FloatingMenuDefinition) throws {
        try menu.validate()
        var next = menus
        if let i = next.firstIndex(where: { $0.id == menu.id }) { next[i] = menu }
        else { guard next.count < 100 else { throw FloatingMenuDefinition.MenuError.invalid }; next.append(menu) }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4_194_304 else { throw FloatingMenuDefinition.MenuError.invalid }
        defaults.set(data, forKey: key); menus = next
    }
    func remove(_ id: UUID) { menus.removeAll { $0.id == id }; defaults.set(try? JSONEncoder().encode(menus), forKey: key) }
    func find(_ nameOrID: String) -> FloatingMenuDefinition? {
        menus.first { $0.id.uuidString == nameOrID || $0.name == nameOrID }
    }
}

final class FloatingMenuController {
    static let shared = FloatingMenuController()
    private var panels: [UUID: NSPanel] = [:]
    private var editor: NSWindow?
    @discardableResult func show(_ nameOrID: String) -> Bool {
        guard let menu = FloatingMenuStore.shared.find(nameOrID), (try? menu.validate()) != nil else { return false }
        panels.removeValue(forKey: menu.id)?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: max(230, menu.columns * 150), height: 240),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = menu.name; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatingMenuView(menu: menu, run: { [weak self] item in
            if !menu.staysOpen { self?.panels.removeValue(forKey: menu.id)?.close() }
            ActionExecutor.executeActions(item.actions)
        }))
        // Nonactivating panels keep the target application focused for keyboard/window actions.
        let pointer = NSEvent.mouseLocation
        let frame = NSScreen.screens.first { $0.frame.contains(pointer) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin: NSPoint
        switch menu.placement {
        case "notch": origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 4)
        case "center": origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2)
        default: origin = NSPoint(x: pointer.x, y: pointer.y - panel.frame.height)
        }
        panel.setFrameOrigin(NSPoint(x: max(frame.minX, min(origin.x, frame.maxX - panel.frame.width)),
                                    y: max(frame.minY, min(origin.y, frame.maxY - panel.frame.height))))
        panels[menu.id] = panel; panel.orderFrontRegardless(); return true
    }
    func hideAll() { panels.values.forEach { $0.close() }; panels.removeAll() }
    func edit() {
        if let editor { editor.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Floating Menus & Widgets"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FloatingMenuEditor())
        window.center(); editor = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FloatingMenuView: View {
    let menu: FloatingMenuDefinition
    let run: (FloatingMenuItem) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: min(6, max(1, menu.columns))), spacing: 10) {
                ForEach(menu.items) { item in
                    switch item.kind {
                    case "clock": TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack { Text(item.title).font(.caption); Text(context.date, style: .time).monospacedDigit() }.padding()
                    }
                    case "variable": TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack { Text(item.title).font(.caption); Text(WorkflowVariables.value(item.variableName) ?? "—").textSelection(.enabled) }.padding()
                    }
                    default: Button { run(item) } label: {
                        Label(item.title, systemImage: item.symbol).frame(maxWidth: .infinity, minHeight: 45)
                    }.buttonStyle(.bordered)
                    }
                }
            }.padding()
        }.frame(minWidth: 230, minHeight: 120)
    }
}

/// Structured item editor plus an explicit native JSON import/export surface.
/// JSON is staged and validated before it replaces the selected menu.
struct FloatingMenuEditor: View {
    @ObservedObject private var store = FloatingMenuStore.shared
    @State private var draft = FloatingMenuDefinition()
    @State private var selectedItem: UUID?
    @State private var json = ""
    @State private var error = ""
    var body: some View {
        HSplitView {
            VStack {
                List(store.menus) { menu in Button(menu.name) { draft = menu; selectedItem = nil; error = "" } }
                Button("New Menu") { draft = FloatingMenuDefinition(); selectedItem = nil }
                Button("Delete Menu", role: .destructive) { store.remove(draft.id); draft = FloatingMenuDefinition() }
            }.frame(minWidth: 150, idealWidth: 190)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Menu name", text: $draft.name)
                    Stepper("Columns: \(draft.columns)", value: $draft.columns, in: 1...6)
                    Toggle("Keep menu open after an action", isOn: $draft.staysOpen)
                    Picker("Placement", selection: Binding(get: { draft.placement ?? "pointer" }, set: { draft.placement = $0 })) {
                        Text("At Pointer").tag("pointer"); Text("Display Center").tag("center"); Text("Below Notch / Menu Bar").tag("notch")
                    }
                    ForEach($draft.items) { $item in
                        GroupBox {
                            VStack(alignment: .leading) {
                                HStack {
                                    TextField("Item title", text: $item.title)
                                    Picker("Kind", selection: $item.kind) {
                                        Text("Action button").tag("button"); Text("Clock").tag("clock"); Text("Variable").tag("variable")
                                    }
                                    Button(role: .destructive) { draft.items.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                }
                                if item.kind == "button" {
                                    TextField("SF Symbol", text: $item.symbol)
                                    ForEach(item.actions) { action in
                                        HStack {
                                            Text(action.actionType.rawValue)
                                            Spacer()
                                            Button("Remove") { item.actions.removeAll { $0.id == action.id } }
                                        }
                                        ActionParameterForm(action: action, triggers: ActionExecutor.registeredTriggers) { mutate in
                                            if let i = item.actions.firstIndex(where: { $0.id == action.id }) { mutate(&item.actions[i]) }
                                        }
                                        if !ActionParameterForm.handles(action.actionType) {
                                            Text("For additional parameters, export JSON, edit the action parameters, then apply JSON.").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Menu("Add Action") {
                                        ForEach(ActionCategory.allCases) { category in
                                            Menu(category.rawValue) {
                                                ForEach(ActionType.actionsForCategory(category)) { type in
                                                    Button(type.rawValue) { item.actions.append(TriggerAction(actionType: type)) }
                                                }
                                            }
                                        }
                                    }
                                } else if item.kind == "variable" { TextField("Variable name", text: $item.variableName) }
                            }
                        }
                    }
                    HStack {
                        Button("Add Item") { draft.items.append(FloatingMenuItem()) }.disabled(draft.items.count >= 100)
                        Button("Save") { save() }
                        Button("Save & Preview") { if save() { FloatingMenuController.shared.show(draft.id.uuidString) } }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    DisclosureGroup("Native menu JSON · import / export") {
                        TextEditor(text: $json).font(.system(.caption, design: .monospaced)).frame(height: 180)
                        HStack {
                            Button("Export Draft") {
                                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                json = (try? encoder.encode(draft)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            }
                            Button("Apply JSON") {
                                do {
                                    guard json.utf8.count <= 1_048_576 else { throw FloatingMenuDefinition.MenuError.invalid }
                                    let imported = try JSONDecoder().decode(FloatingMenuDefinition.self, from: Data(json.utf8))
                                    try imported.validate(); draft = imported; error = ""
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }.padding()
            }.frame(minWidth: 550)
        }
    }
    @discardableResult private func save() -> Bool {
        do { try store.save(draft); error = ""; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
