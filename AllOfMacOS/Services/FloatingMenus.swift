import AppKit
import SwiftUI

/// Native AOM format. Each item runs an ordinary action sequence, so menus use
/// the same cancellation, validation and permissions as keyboard triggers.
/// A "slider" item (3.3.3, B06) drives a continuous value instead: its
/// position is the AOM value 0…1 fed through `valueBinding`.
struct FloatingMenuItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title = "New item"
    var symbol = "bolt"
    var kind = "button" // button, variable, clock, slider
    var variableName = ""
    var actions: [TriggerAction] = []
    /// Slider items only. Optional, so archives without it still decode.
    var valueBinding: ContinuousValueBinding? = nil
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
            guard Self.itemKinds.contains(item.kind), item.title.count <= 500,
                  item.actions.count <= 100 else { throw MenuError.invalid }
            if item.kind == "slider" {
                guard let binding = item.valueBinding, binding.mappingProblem == nil else { throw MenuError.invalid }
            }
            if ActionTree.problem(item.actions) != nil { throw MenuError.invalid }
            for action in item.actions {
                if ActionParameterValidation.problem(for: action) != nil { throw MenuError.invalid }
            }
        }
    }
    static let itemKinds = ["button", "clock", "variable", "slider"]
    enum MenuError: LocalizedError {
        case invalid
        var errorDescription: String? { "Use a name, 1–6 columns, up to 100 unique items, and valid actions. Item kind must be button, clock, variable, or slider; a slider needs a valid value target and ranges." }
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: max(FloatingMenuMetrics.panelMinWidth, CGFloat(menu.columns) * 150), height: 240),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = menu.name; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.applyCaptureVisibilityPreference()
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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: FloatingMenuMetrics.editorSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Floating Menus & Widgets"; window.isReleasedWhenClosed = false
        window.applyCaptureVisibilityPreference()
        window.contentView = NSHostingView(rootView: FloatingMenuEditor())
        window.center(); editor = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FloatingMenuView: View {
    let menu: FloatingMenuDefinition
    let run: (FloatingMenuItem) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.x2), count: min(6, max(1, menu.columns))),
                      spacing: AOMSpace.x2) {
                ForEach(menu.items) { item in
                    switch item.kind {
                    case "clock": TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: AOMSpace.x0_5) {
                            Text(item.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            Text(context.date, style: .time).font(AOMFont.metric)
                        }
                        .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
                        .padding(AOMSpace.x2)
                    }
                    case "variable": TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: AOMSpace.x0_5) {
                            Text(item.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            Text(WorkflowVariables.value(item.variableName) ?? "—").font(AOMFont.body).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
                        .padding(AOMSpace.x2)
                    }
                    case "slider": FloatingValueSlider(item: item)
                    default: Button { run(item) } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(AOMFont.body)
                            .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail - AOMSpace.x1)
                    }
                    .buttonStyle(.bordered)
                    .help(item.title)
                    }
                }
            }
            .padding(AOMSpace.x3)
        }
        .frame(minWidth: FloatingMenuMetrics.panelMinWidth, minHeight: FloatingMenuMetrics.panelMinHeight)
    }
}

/// Sizes the floating menu panel and editor use that no token covers.
enum FloatingMenuMetrics {
    static let panelMinWidth: CGFloat = 230
    static let panelMinHeight: CGFloat = 120
    static let editorSize = NSSize(width: 900, height: 620)
    static let jsonHeight: CGFloat = 180
}

/// The floating menus editor (design-3.4.0 b.2 list + detail): the menus as
/// a list with + − ⋯, the selected menu as sections (menu, items, JSON),
/// Save with ⌘S, and a warning before an edited menu is left unsaved. JSON
/// stays the explicit import/export surface and is validated before it
/// replaces the draft.
struct FloatingMenuEditor: View {
    @ObservedObject private var store: FloatingMenuStore
    @State private var draft: FloatingMenuDefinition
    @State private var selectedMenuID: UUID?
    @State private var json = ""
    @State private var error = ""
    @State private var pendingSelection: UUID??
    @State private var confirmingDelete = false
    @StateObject private var toast = AOMToastModel()

    init(store: FloatingMenuStore = .shared) {
        self.store = store
        let first = store.menus.first
        _draft = State(initialValue: first ?? FloatingMenuDefinition())
        _selectedMenuID = State(initialValue: first?.id)
    }

    /// The saved copy of the menu being edited, if it has been saved.
    private var stored: FloatingMenuDefinition? { store.menus.first { $0.id == draft.id } }
    private var isEdited: Bool { stored.map { $0 != draft } ?? true }
    /// A new menu nobody has touched yet (its item ids are random, so it is
    /// compared by content).
    private var isPristineNew: Bool {
        stored == nil && draft.name == FloatingMenuDefinition().name && draft.columns == 2 && !draft.staysOpen
            && draft.items.count == 1 && draft.items[0].title == FloatingMenuItem().title && draft.items[0].actions.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            AOMListColumn(rows: {
                List(selection: Binding<UUID?>(get: { selectedMenuID }, set: { select($0) })) {
                    ForEach(store.menus) { menu in
                        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                            Text(menu.name).font(AOMFont.body).lineLimit(1)
                            Text("\(menu.items.count) item\(menu.items.count == 1 ? "" : "s") · \(Self.placementTitle(menu.placement))")
                                .font(AOMFont.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, AOMSpace.x0_5)
                        .tag(menu.id)
                        .contextMenu {
                            Button("Show Menu") { FloatingMenuController.shared.show(menu.id.uuidString) }
                            Button("Duplicate") { duplicate(menu) }
                            Divider()
                            Button("Delete…", role: .destructive) { select(menu.id); confirmingDelete = true }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, AOMSize.listRowDouble)
                .overlay {
                    if store.menus.isEmpty {
                        Text("No menus yet").font(AOMFont.body).foregroundStyle(AOMColor.textSecondary)
                    }
                }
            }, footer: {
                AOMAddRemoveBar(addLabel: "New Menu", add: { select(nil, makingNew: true) },
                                removeLabel: "Delete Menu", remove: stored == nil ? nil : { confirmingDelete = true }) {
                    if let stored {
                        Button("Duplicate") { duplicate(stored) }
                        Button("Show Menu") { FloatingMenuController.shared.show(stored.id.uuidString) }
                    }
                }
            })
            .frame(width: CGFloat(AOMSize.moduleListIdeal))
            AOMDivider(axis: .vertical)
            detail
                .frame(minWidth: AOMSize.detailMinimum + AOMSpace.x10 * 2, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AOMColor.canvas)
        .aomToast(toast)
        .confirmationDialog("Save changes to “\(draft.name)”?", isPresented: Binding(
            get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Save") {
                let next = pendingSelection ?? nil
                pendingSelection = nil
                if save() { load(next) }
            }
            Button("Don't Save", role: .destructive) {
                let next = pendingSelection ?? nil
                pendingSelection = nil
                load(next)
            }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("This menu has changes that aren't saved yet.")
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Menu", role: .destructive) {
                let name = draft.name
                store.remove(draft.id)
                load(store.menus.first?.id)
                toast.show("Deleted “\(name)”")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The menu and its items are removed. Automations that show it by name stop finding it.")
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                    Text(draft.name.isEmpty ? "Untitled Menu" : draft.name)
                        .font(AOMFont.title).foregroundStyle(AOMColor.text).lineLimit(1)
                    if isEdited { AOMStatusPill(stored == nil ? "Not Saved" : "Edited", tone: .neutral) }
                    Spacer(minLength: AOMSpace.x2)
                    Button("Show") { if save() { FloatingMenuController.shared.show(draft.id.uuidString) } }
                        .help("Save and show this menu over the current app")
                    Button("Save") { if save() { toast.show("Saved “\(draft.name)”") } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isEdited)
                        .help("Save (⌘S)")
                }
                if !error.isEmpty {
                    AOMNotice(.error, "Couldn't save this menu", detail: error)
                }
                AOMSection("Menu") {
                    AOMSettingRow("Name") {
                        TextField("Menu name", text: $draft.name).textFieldStyle(.roundedBorder)
                            .frame(maxWidth: AOMEditorSize.rowField)
                    }
                    AOMSettingRow("Columns") {
                        Stepper("\(draft.columns)", value: $draft.columns, in: 1...6).fixedSize()
                    }
                    AOMToggleRow("Keep open after an action", isOn: $draft.staysOpen)
                    AOMSettingRow("Placement") {
                        Picker("Placement", selection: Binding(get: { draft.placement ?? "pointer" }, set: { draft.placement = $0 })) {
                            Text("At the Pointer").tag("pointer"); Text("Display Center").tag("center"); Text("Below the Menu Bar").tag("notch")
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                AOMSection("Items", detail: "\(draft.items.count) of 100", accessory: {
                    Button { draft.items.append(FloatingMenuItem()) } label: { Label("Add Item", systemImage: "plus") }
                        .disabled(draft.items.count >= 100)
                }) {
                    if draft.items.isEmpty {
                        AOMInlineEmpty(symbol: "square.grid.2x2", message: "No items. A menu shows its items as buttons, clocks, values or sliders.",
                                       actionTitle: "Add Item") { draft.items.append(FloatingMenuItem()) }
                    }
                    ForEach($draft.items) { $item in
                        itemRows($item)
                    }
                }
                DisclosureGroup("Menu as JSON (import and export)") {
                    VStack(alignment: .leading, spacing: AOMSpace.x2) {
                        TextEditor(text: $json).font(AOMFont.mono).frame(height: FloatingMenuMetrics.jsonHeight)
                            .scrollContentBackground(.hidden)
                            .background(AOMColor.field, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                            .accessibilityLabel("Menu JSON")
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
                                    toast.show("Applied the JSON to the draft; Save keeps it")
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    .padding(.top, AOMSpace.x2)
                }
                .font(AOMFont.body)
            }
            .padding(AOMSpace.pageMargin)
            .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One item: its kind, title and symbol, then what it does.
    @ViewBuilder private func itemRows(_ item: Binding<FloatingMenuItem>) -> some View {
        let value = item.wrappedValue
        AOMSettingRow(value.title.isEmpty ? "Untitled item" : value.title, symbol: value.kind == "button" ? value.symbol : Self.kindSymbol(value.kind)) {
            HStack(spacing: AOMSpace.x2) {
                Picker("Kind", selection: item.kind) {
                    Text("Action Button").tag("button"); Text("Clock").tag("clock"); Text("Variable").tag("variable")
                    Text("Slider").tag("slider")
                }
                .labelsHidden().fixedSize()
                .onChange(of: value.kind) { _, kind in
                    if kind == "slider", item.wrappedValue.valueBinding == nil { item.wrappedValue.valueBinding = ContinuousValueBinding() }
                }
                AOMIconButton("trash", label: "Remove Item", role: .destructive) {
                    draft.items.removeAll { $0.id == value.id }
                }
            }
        }
        AOMSettingRow("Title", indent: true) {
            TextField("Item title", text: item.title).textFieldStyle(.roundedBorder).frame(maxWidth: AOMEditorSize.rowField)
        }
        if value.kind == "button" {
            AOMSettingRow("Symbol", indent: true, help: "An SF Symbols name, for example bolt, star or keyboard") {
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil) == nil ? "questionmark.square.dashed" : value.symbol)
                        .font(AOMFont.body).foregroundStyle(AOMColor.textSecondary)
                        .help(NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil) == nil ? "No symbol has this name" : value.symbol)
                    TextField("SF Symbol", text: item.symbol).textFieldStyle(.roundedBorder).frame(width: AOMEditorSize.rowField * 0.6)
                }
            }
            ForEach(value.actions) { action in
                AOMSettingRow(action.displayName, indent: true) {
                    AOMIconButton("minus.circle", label: "Remove \(action.displayName)") {
                        item.wrappedValue.actions.removeAll { $0.id == action.id }
                    }
                }
                ActionParameterForm(action: action, triggers: ActionExecutor.registeredTriggers) { mutate in
                    if let i = item.wrappedValue.actions.firstIndex(where: { $0.id == action.id }) { mutate(&item.wrappedValue.actions[i]) }
                }
                .padding(.horizontal, AOMSpace.rowInset)
                if !ActionParameterForm.handles(action.actionType) {
                    Text("This action's other settings are edited in the menu's JSON below.")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, AOMSpace.rowInset).padding(.bottom, AOMSpace.x2)
                }
            }
            AOMSettingRow(value.actions.isEmpty ? "No actions yet" : "Then", indent: true) {
                Menu("Add Action") {
                    ForEach(ActionCategory.allCases) { category in
                        Menu(category.rawValue) {
                            ForEach(ActionType.actionsForCategory(category)) { type in
                                Button(type.rawValue) { item.wrappedValue.actions.append(TriggerAction(actionType: type)) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
        } else if value.kind == "variable" {
            AOMSettingRow("Variable", indent: true) {
                TextField("Variable name", text: item.variableName).textFieldStyle(.roundedBorder).frame(maxWidth: AOMEditorSize.rowField)
            }
        } else if value.kind == "slider" {
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                FloatingSliderBindingFields(binding: item.valueBinding)
            }
            .padding(.horizontal, AOMSpace.rowInset).padding(.vertical, AOMSpace.x2)
        }
    }

    private static func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "clock": return "clock"
        case "variable": return "textformat.abc"
        case "slider": return "slider.horizontal.3"
        default: return "bolt"
        }
    }

    private static func placementTitle(_ placement: String?) -> String {
        switch placement {
        case "center": return "display center"
        case "notch": return "below the menu bar"
        default: return "at the pointer"
        }
    }

    // MARK: Actions

    /// Selecting another menu (or New Menu) asks first when the draft has
    /// unsaved changes, so nothing is dropped without a word.
    private func select(_ id: UUID?, makingNew: Bool = false) {
        guard makingNew || id != selectedMenuID else { return }
        if isEdited, !isPristineNew {
            pendingSelection = .some(makingNew ? nil : id)
            return
        }
        load(makingNew ? nil : id)
    }

    private func load(_ id: UUID?) {
        if let id, let menu = store.menus.first(where: { $0.id == id }) {
            draft = menu
            selectedMenuID = id
        } else {
            draft = FloatingMenuDefinition()
            selectedMenuID = nil
        }
        error = ""
    }

    private func duplicate(_ menu: FloatingMenuDefinition) {
        var copy = menu
        copy.id = UUID()
        copy.name = menu.name + " Copy"
        copy.items = menu.items.map { var item = $0; item.id = UUID(); return item }
        do {
            try store.save(copy)
            load(copy.id)
            toast.show("Duplicated “\(menu.name)”")
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult private func save() -> Bool {
        do {
            try store.save(draft)
            selectedMenuID = draft.id
            error = ""
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

// MARK: - Slider widget (3.3.3, B06)

/// A floating-menu slider bound to a continuous action. It starts at the
/// target's current level and writes through the same rate-limited sink as
/// MIDI and scroll bindings, so dragging never floods the output.
struct FloatingValueSlider: View {
    let item: FloatingMenuItem
    var engine: ContinuousValueEngine = .shared
    @State private var value: Double = 0
    @State private var level: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(item.title, systemImage: item.symbol).font(.caption)
                Spacer()
                Text(level.map { "\(Int(($0 * 100).rounded())) %" } ?? "—").font(.caption).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: { newValue in
                value = newValue
                guard let binding = item.valueBinding else { return }
                level = engine.drive(binding, input: newValue, from: item.id) ?? level
            }), in: 0...1)
            .disabled(item.valueBinding == nil)
        }
        .padding(8)
        .onAppear(perform: syncWithTarget)
    }

    private func syncWithTarget() {
        guard let binding = item.valueBinding, let target = ContinuousTargetIO.resolve(binding),
              let current = ContinuousTargetIO.currentLevel(target) else { return }
        level = current
        value = binding.input(forOutput: current)
    }
}

/// Editor fields for a slider item: what it drives and how.
struct FloatingSliderBindingFields: View {
    @Binding var binding: ContinuousValueBinding?

    var body: some View {
        Picker("Drives", selection: field(\.target)) {
            ForEach(ContinuousValueBinding.Target.allCases) { Text($0.title).tag($0) }
        }
        Text((binding ?? ContinuousValueBinding()).target.help).font(.caption).foregroundStyle(.secondary)
        if binding?.target == .appVolume {
            TextField("App bundle ID (empty = frontmost app)", text: field(\.appBundleID))
        }
        HStack {
            Text("Range")
            Slider(value: field(\.outputMinimum), in: 0...1)
            Slider(value: field(\.outputMaximum), in: 0...1)
        }
        Picker("Curve", selection: field(\.curve)) {
            ForEach(ContinuousValueBinding.Curve.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Invert", isOn: field(\.inverted))
        if let problem = binding?.mappingProblem { Text(problem).font(.caption).foregroundStyle(.red) }
    }

    private func field<T>(_ keyPath: WritableKeyPath<ContinuousValueBinding, T>) -> Binding<T> {
        Binding(get: { (binding ?? ContinuousValueBinding())[keyPath: keyPath] },
                set: { newValue in
                    var next = binding ?? ContinuousValueBinding()
                    next[keyPath: keyPath] = newValue
                    binding = next
                })
    }
}
