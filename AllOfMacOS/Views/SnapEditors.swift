import SwiftUI
import UniformTypeIdentifiers

/// The tiling sheets' fixed sizes that no shared token covers.
private enum SnapEditorMetrics {
    /// The zone editor stays narrower than the main window at its minimum
    /// (`AOMSize.windowMinWidth`), so the sheet never hangs past the window.
    static let zonesSheetMinWidth: CGFloat = 860
    static let zonesSheetIdealWidth: CGFloat = 920
    /// The zone list and the zone editor beside it.
    static let bodyHeight: CGFloat = 400
    /// A zone's diagram in the list, a quick-start layout's diagram and tile.
    static let zoneDiagram: CGFloat = 34
    static let quickDiagram: CGFloat = 48
    static let quickTile: CGFloat = 80
    /// The drop-area and window-target canvases.
    static let canvasHeight: CGFloat = 200
    /// The display-profile and saved-window lists.
    static let sheetListHeight: CGFloat = 220
    /// Zones per set (`SnapLayoutProfile.isValid` allows 32).
    static let maximumZones = 32
}

/// The header the tiling sheets share (the Settings sheet pattern): the
/// title on the left in Headline, Done on the right, a hairline under it.
private struct SnapSheetHeader: View {
    let title: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x3)
            AOMDivider()
        }
    }
}

/// Two-step visual snapping editor. Save is atomic; Cancel discards draft zones.
///
/// It uses the Window Tiling page's words: "zones" for the list, and the
/// Drag to Snap section's labels for its three switches. One footer says
/// what Save will do.
struct CustomSnapZonesEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var zones: [CustomSnapZone]
    @State private var selectedID: UUID?
    @State private var enabled: Bool
    @State private var requiresOption: Bool
    @State private var showsPreview: Bool
    @State private var lastSet: String = "Custom"
    @State private var previousZones: [CustomSnapZone]?
    let profileID: UUID?
    let profileName: String
    init(preset: Preset, profile: SnapLayoutProfile? = nil) {
        let zones = profile?.zones ?? preset.customSnapZones
        _lastSet = State(initialValue: CustomSnapZone.Collection.allCases.first {
            $0.layouts.count == zones.count && Set($0.replacing(zones).map(\.id)) == Set(zones.map(\.id))
        }?.rawValue ?? "Custom")
        _zones = State(initialValue: zones)
        _selectedID = State(initialValue: zones.first?.id)
        _enabled = State(initialValue: preset.snappingEnabled)
        _requiresOption = State(initialValue: profile?.requiresOption ?? preset.snappingRequiresOption)
        _showsPreview = State(initialValue: profile?.showsPreview ?? preset.snappingShowsPreview)
        profileID = profile?.id; profileName = profile?.name ?? "Default layout"
    }
    private func applyCollection(_ collection: CustomSnapZone.Collection) {
        previousZones = zones
        zones = collection.replacing(zones)
        selectedID = zones.first?.id; lastSet = collection.rawValue
    }
    private var selection: Binding<CustomSnapZone>? {
        guard let id = selectedID, let index = zones.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { zones[index] }, set: { zones[index] = $0 })
    }
    private func newZone(_ layout: CustomSnapZone.Layout) {
        guard zones.count < SnapEditorMetrics.maximumZones else { return }
        let zone = layout.zone()
        zones.append(zone)
        selectedID = zone.id; lastSet = "Custom"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            header
            controlStrip
            HStack(alignment: .top, spacing: AOMSpace.x4) {
                zoneList
                    .frame(width: AOMSize.sidebarMin)
                Group {
                    if let selected = selection {
                        zoneDetail(selected)
                    } else {
                        emptyEditor
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: SnapEditorMetrics.bodyHeight)
            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                footerNote
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Changes") {
                    appState.updateSnapSettings(zones: zones, enabled: enabled, requiresOption: requiresOption,
                        showsPreview: showsPreview, profileID: profileID)
                    dismiss()
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!zones.allSatisfy(\.isValid))
            }
        }
        .padding(AOMSpace.x4)
        .frame(minWidth: SnapEditorMetrics.zonesSheetMinWidth, idealWidth: SnapEditorMetrics.zonesSheetIdealWidth)
    }

    /// What the sheet edits, how a zone is used, and the one way to add one.
    private var header: some View {
        HStack(alignment: .top, spacing: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text("Snap Zones")
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Drag a window by its title bar into a highlighted area and let go to resize it; Esc cancels.")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                Text("Editing \(profileName) · Running now: \(appState.snapStatus)")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x3)
            if let previousZones {
                Button("Undo Set Change") {
                    zones = previousZones; self.previousZones = nil; selectedID = zones.first?.id; lastSet = "Custom"
                }
            }
            Menu {
                ForEach(CustomSnapZone.Layout.allCases) { layout in
                    Button { newZone(layout) } label: { Label(layout.rawValue, systemImage: layout.symbol) }
                }
            } label: {
                Label("Add Zone", systemImage: "plus")
            }
            .fixedSize()
            .disabled(zones.count >= SnapEditorMetrics.maximumZones)
            .help("Add a zone from a ready-made position")
        }
    }

    /// The page's own switches, under the page's labels, and the ready-made sets.
    private var controlStrip: some View {
        HStack(spacing: AOMSpace.x4) {
            Toggle("Snap windows by dragging", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Require ⌥ Option", isOn: $requiresOption)
            Toggle("Show snap preview", isOn: $showsPreview)
            Spacer(minLength: AOMSpace.x2)
            Menu("Replace Set: " + lastSet) {
                ForEach(CustomSnapZone.Collection.allCases) { collection in
                    Button("\(collection.rawValue) · \(collection.layouts.count) zones") { applyCollection(collection) }
                }
            }
            .fixedSize()
            .help("Replace this list with a ready-made set of 3, 9 or 16 zones")
        }
        .padding(.horizontal, AOMSpace.x3)
        .padding(.vertical, AOMSpace.x2)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
    }

    private var zoneList: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                // Sentence case, never tracked caps (c.2).
                Text("Zones in this set")
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Turn On All") {
                    for index in zones.indices { zones[index].isEnabled = true }
                }
                .controlSize(.small)
                .disabled(zones.isEmpty)
                .help("Turn on every zone in this set")
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: AOMSpace.x1) {
                    ForEach(zones) { zone in zoneRow(zone) }
                }
                .padding(AOMSpace.x0_5)
            }
        }
    }

    /// One zone: its target as the page's layout diagram (dimmed while off),
    /// its name and size.
    private func zoneRow(_ zone: CustomSnapZone) -> some View {
        let selected = selectedID == zone.id
        let shape = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
        return Button { selectedID = zone.id } label: {
            HStack(spacing: AOMSpace.x2) {
                AOMLayoutDiagram(zone: zone, highlighted: selected)
                    .frame(width: SnapEditorMetrics.zoneDiagram)
                    .opacity(zone.isEnabled ? 1 : AOMRowControlMetrics.dependentOpacity)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(zone.name)
                        .font(AOMFont.callout.weight(.medium))
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                    Text("\(Int(zone.targetWidth * 100))% × \(Int(zone.targetHeight * 100))%\(zone.isEnabled ? "" : " · Off")")
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AOMColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, AOMSpace.x2)
            .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
            .background(selected ? AOMTone.info.wash(increasedContrast: false) : AOMColor.raised, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(zone.name), \(zone.isEnabled ? "on" : "off")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func zoneDetail(_ selected: Binding<CustomSnapZone>) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            ScrollView(showsIndicators: false) {
                SnapZoneDetailEditor(zone: selected).padding(AOMSpace.x0_5)
            }
            HStack(spacing: AOMSpace.x2) {
                Spacer()
                Button("Duplicate") {
                    guard var zone = zones.first(where: { $0.id == selectedID }) else { return }
                    zone.id = UUID(); zone.name += " Copy"
                    zones.append(zone); selectedID = zone.id
                }
                .disabled(zones.count >= SnapEditorMetrics.maximumZones)
                Button("Delete Zone", role: .destructive) {
                    zones.removeAll { $0.id == selectedID }
                    selectedID = zones.first?.id
                }
                .aomDestructive()
            }
        }
    }

    /// No zone yet: a whole set, or one of six common positions drawn the way
    /// the page's layout gallery draws them.
    private var emptyEditor: some View {
        VStack(spacing: AOMSpace.x3) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: AOMIcon.empty))
                .foregroundStyle(AOMColor.textSecondary)
                .accessibilityHidden(true)
            Text("Choose your first zone")
                .font(AOMFont.section)
                .foregroundStyle(AOMColor.text)
            Text("Pick a position below or a whole set, then set where to drop the window and where it lands.")
                .font(AOMFont.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(AOMColor.textSecondary)
            Button { applyCollection(.complete) } label: {
                Label("Use \(CustomSnapZone.Collection.complete.rawValue) · \(CustomSnapZone.Collection.complete.layouts.count) zones",
                      systemImage: "checkmark.circle.fill")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.x3), count: 3), spacing: AOMSpace.x3) {
                ForEach([CustomSnapZone.Layout.leftHalf, .rightHalf, .maximize, .topLeft, .centerThird, .nextDisplay]) { layout in
                    let tile = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                    Button { newZone(layout) } label: {
                        VStack(spacing: AOMSpace.x2) {
                            AOMLayoutDiagram(layout: layout)
                                .frame(width: SnapEditorMetrics.quickDiagram)
                            Text(layout.rawValue)
                                .font(AOMFont.caption.weight(.medium))
                                .foregroundStyle(AOMColor.text)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: SnapEditorMetrics.quickTile)
                        .background(AOMColor.sunken, in: tile)
                        .contentShape(tile)
                    }
                    .buttonStyle(.plain)
                    .help("Add a \(layout.rawValue) zone")
                }
            }
        }
        .padding(AOMSpace.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one line that says what Save does (it replaced four captions).
    @ViewBuilder private var footerNote: some View {
        if enabled {
            AOMEditorNote("\(zones.count) zones, \(zones.filter(\.isEnabled).count) on · Changes apply when you save.")
        } else {
            AOMEditorNote("Drag to Snap stays off after you save; the zones are kept.", tone: .warning)
        }
    }
}

/// Interactive display mock: drag rectangle to position, corner grip to resize.
private struct SnapZoneCanvas: View {
    @Binding var zone: CustomSnapZone
    let destination: Bool
    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?
    private var rect: CGRect {
        CGRect(x: destination ? zone.targetX : zone.hotX,
               y: destination ? zone.targetY : zone.hotY,
               width: destination ? zone.targetWidth : zone.hotWidth,
               height: destination ? zone.targetHeight : zone.hotHeight)
    }
    private func set(_ rect: CGRect) {
        if destination {
            zone.targetX = rect.minX; zone.targetY = rect.minY
            zone.targetWidth = rect.width; zone.targetHeight = rect.height
        } else {
            zone.hotX = rect.minX; zone.hotY = rect.minY
            zone.hotWidth = rect.width; zone.hotHeight = rect.height
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let frame = rect
            let screen = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
            let area = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
            ZStack(alignment: .topLeading) {
                screen.fill(AOMColor.raised)
                // A window title bar, so the mock reads as a display.
                VStack(spacing: 0) {
                    HStack(spacing: AOMSpace.x1) {
                        Circle().fill(.red.opacity(0.65)).frame(width: AOMIcon.dot, height: AOMIcon.dot)
                        Circle().fill(.yellow.opacity(0.65)).frame(width: AOMIcon.dot, height: AOMIcon.dot)
                        Circle().fill(.green.opacity(0.65)).frame(width: AOMIcon.dot, height: AOMIcon.dot)
                        Spacer()
                        Text("Preview")
                            .font(AOMFont.badge)
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                    .padding(.horizontal, AOMSpace.x3).frame(height: AOMSpace.x6)
                    AOMDivider()
                    Spacer()
                }
                area
                    .fill(Color.accentColor.opacity(0.30))
                    .overlay {
                        area.strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .overlay(alignment: .center) {
                        VStack(spacing: AOMSpace.x1) {
                            Image(systemName: destination ? "macwindow" : "cursorarrow.rays")
                                .font(AOMFont.pageStatus.weight(.regular))
                            Text(destination ? "Window" : "Drop here")
                                .font(AOMFont.badge.weight(.semibold))
                        }.foregroundStyle(Color.accentColor).allowsHitTesting(false)
                    }
                    .frame(width: geometry.size.width * frame.width,
                           height: geometry.size.height * frame.height)
                    .position(x: geometry.size.width * frame.midX, y: geometry.size.height * frame.midY)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStart == nil { dragStart = frame }
                            guard let base = dragStart else { return }
                            let x = min(1-base.width, max(0, base.minX + value.translation.width/geometry.size.width))
                            let y = min(1-base.height, max(0, base.minY + value.translation.height/geometry.size.height))
                            set(CGRect(x: x, y: y, width: base.width, height: base.height))
                        }.onEnded { _ in dragStart = nil })
                Circle().fill(Color.accentColor)
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(AOMFont.badge.weight(.bold)).foregroundStyle(.white))
                    .position(x: geometry.size.width * frame.maxX, y: geometry.size.height * frame.maxY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeStart == nil { resizeStart = frame }
                            guard let base = resizeStart else { return }
                            let width = min(1-base.minX,max(0.05,base.width+value.translation.width/geometry.size.width))
                            let height = min(1-base.minY,max(0.05,base.height+value.translation.height/geometry.size.height))
                            set(CGRect(x: base.minX,y: base.minY,width: width,height: height))
                        }.onEnded { _ in resizeStart = nil })
            }
            .overlay(screen.strokeBorder(AOMColor.hairline, lineWidth: 1))
        }
    }
}

private struct SnapZoneDetailEditor: View {
    @Binding var zone: CustomSnapZone
    @State private var mode = 0
    @State private var showPrecision = false
    private func configure(x: Double,y: Double,width: Double,height: Double) {
        if mode == 0 {
            zone.hotX=x; zone.hotY=y; zone.hotWidth=width; zone.hotHeight=height
        } else {
            zone.targetX=x; zone.targetY=y; zone.targetWidth=width; zone.targetHeight=height
        }
    }
    private func preciseValue(_ key: WritableKeyPath<CustomSnapZone, Double>) -> Binding<Double> {
        Binding(get: { zone[keyPath: key] }, set: { val in
            var candidate = zone
            candidate[keyPath: key] = val
            if candidate.isValid { zone = candidate }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x3) {
                TextField("Zone name", text: $zone.name).textFieldStyle(.roundedBorder)
                Toggle("Enabled", isOn: $zone.isEnabled).toggleStyle(.switch).controlSize(.small)
            }
            AOMEditorNote("Move the colored rectangles, or use the ready-made positions below.")
            HStack(alignment: .top, spacing: AOMSpace.x3) {
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    Label("1 · Where to drop", systemImage: "cursorarrow.rays")
                        .font(AOMFont.caption.weight(.semibold))
                    SnapZoneCanvas(zone: $zone, destination: false)
                        .frame(height: SnapEditorMetrics.canvasHeight)
                        .accessibilityLabel("Drop area preview. Drag to position, use corner to resize.")
                    HStack(spacing: AOMSpace.x1) {
                        Button("Top-left") { mode = 0; configure(x: 0,y: 0,width: 0.15,height: 0.15) }
                        Button("Top-right") { mode = 0; configure(x: 0.85,y: 0,width: 0.15,height: 0.15) }
                        Button("Bottom-right") { mode = 0; configure(x: 0.85,y: 0.85,width: 0.15,height: 0.15) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    AOMEditorNote("Release the dragged window inside this area.")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    Label("2 · Where it moves", systemImage: "macwindow")
                        .font(AOMFont.caption.weight(.semibold))
                    SnapZoneCanvas(zone: $zone, destination: true)
                        .frame(height: SnapEditorMetrics.canvasHeight)
                        .accessibilityLabel("Window destination preview. Drag to position, use corner to resize.")
                    HStack(spacing: AOMSpace.x1) {
                        Button("Left ½") { mode = 1; configure(x: 0,y: 0,width: 0.5,height: 1) }
                        Button("Right ½") { mode = 1; configure(x: 0.5,y: 0,width: 0.5,height: 1) }
                        Button("Full") { mode = 1; configure(x: 0,y: 0,width: 1,height: 1) }
                        Button("Center") { mode = 1; configure(x: 0.2,y: 0.13,width: 0.6,height: 0.74) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    AOMEditorNote("The window is resized to this target after release.")
                }.frame(maxWidth: .infinity)
            }
            Picker("Target display", selection: $zone.targetDisplay) {
                Text("Display under pointer").tag("pointer")
                Text("Window's current display").tag("current")
                Text("Main display").tag("primary")
                Text("Next display").tag("next")
            }
            AOMDivider()
            Picker("Fine tune", selection: $mode) {
                Text("Drop area coordinates").tag(0)
                Text("Window target coordinates").tag(1)
            }.pickerStyle(.segmented)
            DisclosureGroup("Precise coordinates", isExpanded: $showPrecision) {
                VStack(spacing: AOMSpace.x1) {
                    ForEach(["X", "Y", "Width", "Height"], id: \.self) { title in
                        HStack {
                            Text(title).frame(width: AOMSpace.x12, alignment: .leading)
                            let key: WritableKeyPath<CustomSnapZone, Double> = {
                                switch (mode,title) {
                                case (0,"X"): return \.hotX
                                case (0,"Y"): return \.hotY
                                case (0,"Width"): return \.hotWidth
                                case (0,_): return \.hotHeight
                                case (1,"X"): return \.targetX
                                case (1,"Y"): return \.targetY
                                case (1,"Width"): return \.targetWidth
                                default: return \.targetHeight
                                }
                            }()
                            Slider(value: preciseValue(key), in: 0...1, step: 0.01)
                            Text("\(Int(zone[keyPath: key]*100))%")
                                .monospacedDigit().frame(width: AOMEditorSize.valueLabel)
                        }
                    }
                }.padding(.vertical, AOMSpace.x2)
            }
            if !zone.isValid {
                AOMEditorNote("Keep the rectangles inside the screen and at least 5% wide and tall.", tone: .warning)
            }
        }
    }
}


struct SnapProfilesEditor: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""
    var body: some View {
        VStack(spacing: 0) {
            SnapSheetHeader(title: "Display Profiles") { dismiss() }
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                Toggle("Switch layouts automatically when displays change", isOn: Binding(
                    get: { appState.currentPreset.automaticSnapProfiles }, set: { appState.setAutomaticSnapProfiles($0) }))
                Text("Connected: \(appState.displayIDs.count) displays · Active: \(appState.activeSnapProfile?.name ?? "Default layout")")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                AOMEditorNote("Saves the current zones for exactly these displays; saving again updates that profile. Other display setups use the default layout, and Drag to Snap still turns snapping on or off.")
                HStack(spacing: AOMSpace.x2) {
                    TextField("Profile name (e.g. MacBook / Desk)", text: $name)
                    Button("Save for These Displays") {
                        message = appState.saveDisplayProfile(name: name) ? "Profile saved. Edit its zones in Window Tiling." : "Enter a name and connect an available display."
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                List(appState.currentPreset.snapProfiles) { profile in
                    HStack(spacing: AOMSpace.x2) {
                        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                            Text(profile.name).font(AOMFont.bodyEmphasis)
                            Text("\(profile.displayIDs.count) displays · \(profile.zones.count) zones")
                                .font(AOMFont.caption)
                                .foregroundStyle(AOMColor.textSecondary)
                        }
                        Spacer()
                        if appState.activeSnapProfile?.id == profile.id { AOMStatusPill("Active", tone: .success) }
                        Button("Remove") { appState.removeDisplayProfile(profile.id) }
                    }
                }
                .frame(height: SnapEditorMetrics.sheetListHeight)
                if !message.isEmpty { AOMEditorNote(message) }
            }
            .padding(AOMSpace.x4)
        }
        .frame(width: AOMSize.readableText)
    }
}

struct WindowLayoutsEditor: View {
    @ObservedObject private var manager = WindowManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(spacing: 0) {
            // Titled like the "Saved Windows" row that opens it.
            SnapSheetHeader(title: "Saved Windows") { dismiss() }
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                AOMEditorNote("Save where the visible windows are, then put them back together. Closed or ambiguous windows and disconnected displays are skipped; saving with an existing name updates that layout.")
                HStack(spacing: AOMSpace.x2) {
                    TextField("Layout name", text: $name)
                    Button("Save Current Windows") { _ = manager.saveLayout(name: name) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.layoutBusy)
                }
                List(manager.layouts) { layout in
                    HStack(spacing: AOMSpace.x2) {
                        Text(layout.name).font(AOMFont.bodyEmphasis)
                        Text("\(layout.windows.count) windows").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        Spacer()
                        Button("Restore") { manager.restoreLayout(name: layout.name) { _ in } }
                        Button("Remove") { manager.removeLayout(layout.id) }
                    }.disabled(manager.layoutBusy)
                }
                .frame(height: SnapEditorMetrics.sheetListHeight)
                HStack(spacing: AOMSpace.x2) {
                    if !manager.lastLayoutResult.isEmpty { AOMEditorNote(manager.lastLayoutResult) }
                    Spacer()
                    Button("Undo Last Placement") { manager.undoLastPlacement { _ in } }
                        .disabled(manager.historyCount == 0 || manager.layoutBusy)
                        .help("Put windows back where they were before the last placement. Undo lasts until AOM quits.")
                }
            }
            .padding(AOMSpace.x4)
        }
        .frame(width: AOMSize.readableText)
    }
}
