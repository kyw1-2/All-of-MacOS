import SwiftUI
import UniformTypeIdentifiers

/// Two-step visual snapping editor. Save is atomic; Cancel discards draft zones.
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
        guard zones.count < 32 else { return }
        let zone = layout.zone()
        zones.append(zone)
        selectedID = zone.id; lastSet = "Custom"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag-to-Snap Window Layouts").font(.title2.bold())
                    Text("Drag a window by its title bar into a highlighted area → release to resize.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(CustomSnapZone.Layout.allCases) { layout in
                        Button { newZone(layout) } label: { Label(layout.rawValue, systemImage: layout.symbol) }
                    }
                } label: { Label("Add Layout", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(zones.count >= 32)
            }
            HStack(spacing: 16) {
                Toggle("Enable snapping", isOn: $enabled).toggleStyle(.switch)
                Toggle("Require Option ⌥", isOn: $requiresOption)
                Toggle("Show preview", isOn: $showsPreview)
                Spacer()
                Menu("Replace Set: " + lastSet) {
                    ForEach(CustomSnapZone.Collection.allCases) { collection in
                        Button("\(collection.rawValue) · \(collection.layouts.count) layouts") { applyCollection(collection) }
                    }
                }
            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editing: " + profileName).font(.subheadline.bold())
                    Text("Running now: " + appState.snapStatus).font(.caption).foregroundStyle(.secondary)
                    Text(enabled ? "After Save: \(zones.filter(\.isEnabled).count) layouts enabled. AOM must also be on." : "After Save: OFF. Individual selections are remembered; no areas are monitored.")
                        .font(.caption).foregroundStyle(enabled ? Color.secondary : Color.orange)
                }
                Spacer()
                if let previousZones {
                    Button("Undo Set Change") { zones = previousZones; self.previousZones = nil; selectedID = zones.first?.id; lastSet = "Custom" }
                }
            }
            Text("Replace Set replaces this list (3 / 9 / 16). Apply with Save Changes. Drag a title bar into an area; Esc cancels.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 17) {
                VStack(spacing: 9) {
                    Text("LAYOUTS IN THIS SET").font(.caption.bold()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity,alignment: .leading)
                    Button("Select All Layouts") { for index in zones.indices { zones[index].isEnabled = true } }
                        .buttonStyle(.bordered).disabled(zones.isEmpty)
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(zones) { zone in
                                Button { selectedID = zone.id } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: zone.isEnabled ? "macwindow.on.rectangle" : "pause.circle")
                                            .font(.system(size: 20))
                                        VStack(alignment: .leading,spacing: 2) {
                                            Text(zone.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text("\(Int(zone.targetWidth*100))% × \(Int(zone.targetHeight*100))%")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedID == zone.id { Image(systemName: "checkmark.circle.fill") }
                                    }
                                    .padding(10)
                                    .background(selectedID == zone.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }.padding(2)
                    }.frame(width: 195, height: 330)
                }
                if let selected = selection {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(showsIndicators: false) { SnapZoneDetailEditor(zone: selected).padding(3) }.frame(height: 365)
                        HStack {
                            Spacer()
                            Button("Duplicate") {
                                guard var zone = zones.first(where: { $0.id == selectedID }) else { return }
                                zone.id = UUID(); zone.name += " Copy"
                                zones.append(zone); selectedID = zone.id
                            }.disabled(zones.count >= 32)
                            Button("Delete Zone", role: .destructive) {
                                zones.removeAll { $0.id == selectedID }
                                selectedID = zones.first?.id
                            }
                        }
                    }.frame(width: 760)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Choose your first window layout").font(.title3.weight(.semibold))
                        Text("Select a layout. Set where to drop the window and where it should land. Then save.")
                            .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button { applyCollection(.complete) } label: {
                            Label("Use Complete Set · 16 layouts", systemImage: "checkmark.circle.fill")
                        }.buttonStyle(.borderedProminent)
                        Text("Changes apply when you save.").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())], spacing: 12) {
                            ForEach([CustomSnapZone.Layout.leftHalf, .rightHalf, .maximize, .topLeft, .centerThird, .nextDisplay]) { layout in
                                Button { newZone(layout) } label: {
                                    VStack(spacing: 9) {
                                        Image(systemName: layout.symbol).font(.system(size: 28))
                                        Text(layout.rawValue).font(.subheadline.weight(.medium))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 93)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(25)
                    .frame(width: 760, height: 365)
                }
            }
            Divider()
            HStack {
                Text("\(zones.count) layouts · changes apply only after Save")
                    .font(.caption).foregroundStyle(.secondary)
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
        }.padding(21).frame(width: 1035)
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
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .textBackgroundColor))
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(.red.opacity(0.65)).frame(width: 7, height: 7)
                        Circle().fill(.yellow.opacity(0.65)).frame(width: 7, height: 7)
                        Circle().fill(.green.opacity(0.65)).frame(width: 7, height: 7)
                        Spacer()
                        Text("DISPLAY PREVIEW").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 23)
                    Rectangle().fill(.secondary.opacity(0.12)).frame(height: 1)
                    Spacer()
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.30))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .overlay(alignment: .center) {
                        VStack(spacing: 4) {
                            Image(systemName: destination ? "macwindow" : "cursorarrow.rays")
                                .font(.system(size: 18))
                            Text(destination ? "WINDOW" : "DROP HERE")
                                .font(.system(size: 9, weight: .bold))
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
                    .frame(width: 21,height: 21)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10,weight: .bold)).foregroundStyle(.white))
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
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.secondary.opacity(0.25)))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Zone name", text: $zone.name).font(.title3).textFieldStyle(.roundedBorder)
                Toggle("Enabled", isOn: $zone.isEnabled).toggleStyle(.switch)
            }
            Text("Move the colored rectangles, or use the ready-made positions below.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("1 · WHERE TO DROP", systemImage: "cursorarrow.rays")
                        .font(.caption.weight(.bold))
                    SnapZoneCanvas(zone: $zone, destination: false)
                        .frame(height: 208)
                        .accessibilityLabel("Drop area preview. Drag to position, use corner to resize.")
                    HStack(spacing: 5) {
                        Button("Top-left") { mode = 0; configure(x: 0,y: 0,width: 0.15,height: 0.15) }
                        Button("Top-right") { mode = 0; configure(x: 0.85,y: 0,width: 0.15,height: 0.15) }
                        Button("Bottom-right") { mode = 0; configure(x: 0.85,y: 0.85,width: 0.15,height: 0.15) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Text("Release the dragged window inside this area.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Label("2 · WHERE IT MOVES", systemImage: "macwindow")
                        .font(.caption.weight(.bold))
                    SnapZoneCanvas(zone: $zone, destination: true)
                        .frame(height: 208)
                        .accessibilityLabel("Window destination preview. Drag to position, use corner to resize.")
                    HStack(spacing: 5) {
                        Button("Left ½") { mode = 1; configure(x: 0,y: 0,width: 0.5,height: 1) }
                        Button("Right ½") { mode = 1; configure(x: 0.5,y: 0,width: 0.5,height: 1) }
                        Button("Full") { mode = 1; configure(x: 0,y: 0,width: 1,height: 1) }
                        Button("Center") { mode = 1; configure(x: 0.2,y: 0.13,width: 0.6,height: 0.74) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Text("The window is resized to this target after release.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            Picker("Target display", selection: $zone.targetDisplay) {
                Text("Display under pointer").tag("pointer")
                Text("Window's current display").tag("current")
                Text("Main display").tag("primary")
                Text("Next display").tag("next")
            }
            Divider()
            Picker("Fine tune", selection: $mode) {
                Text("Drop area coordinates").tag(0)
                Text("Window target coordinates").tag(1)
            }.pickerStyle(.segmented)
            DisclosureGroup("Precise coordinates", isExpanded: $showPrecision) {
                VStack(spacing: 5) {
                    ForEach(["X", "Y", "Width", "Height"], id: \.self) { title in
                        HStack {
                            Text(title).frame(width: 52, alignment: .leading)
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
                                .monospacedDigit().frame(width: 42)
                        }
                    }
                }.padding(.vertical, 8)
            }
            if !zone.isValid {
                Label("Keep the rectangles inside the screen and at least 5% wide/tall.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Display Profiles").font(.title2.bold())
            Toggle("Switch layouts automatically when displays change", isOn: Binding(
                get: { appState.currentPreset.automaticSnapProfiles }, set: { appState.setAutomaticSnapProfiles($0) }))
            Text("Connected: \(appState.displayIDs.count) displays · Active: \(appState.activeSnapProfile?.name ?? "Default layout")")
                .font(.subheadline)
            Text("Save the current layouts for these exact displays. Unrecognized configurations use the default layout. The master snapping switch is always respected.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Profile name (e.g. MacBook / Desk)", text: $name)
                Button("Save for These Displays") {
                    message = appState.saveDisplayProfile(name: name) ? "Profile saved. Edit its areas in Window Snapping." : "Enter a name and connect an available display."
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Saving again for the same displays updates that profile.").font(.caption).foregroundStyle(.secondary)
            List(appState.currentPreset.snapProfiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name).bold()
                        Text("\(profile.displayIDs.count) displays · \(profile.zones.count) layouts").font(.caption)
                    }
                    Spacer()
                    if appState.activeSnapProfile?.id == profile.id { Text("Active").foregroundStyle(.green) }
                    Button("Remove") { appState.removeDisplayProfile(profile.id) }
                }
            }.frame(height: 230)
            Text(message).font(.caption)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 640)
    }
}

struct WindowLayoutsEditor: View {
    @ObservedObject private var manager = WindowManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved Window Layouts").font(.title2.bold())
                Spacer()
                Button("Undo Last Placement") { manager.undoLastPlacement { _ in } }
                    .disabled(manager.historyCount == 0 || manager.layoutBusy)
            }
            Text("Save visible normal windows, then restore their positions together. Closed or ambiguous windows and disconnected displays are skipped. Undo lasts until AOM quits.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Layout name", text: $name)
                Button("Save Current Windows") { _ = manager.saveLayout(name: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.layoutBusy)
            }
            Text("Saving with an existing name updates that layout.").font(.caption).foregroundStyle(.secondary)
            List(manager.layouts) { layout in
                HStack {
                    Text(layout.name).bold()
                    Text("\(layout.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") { manager.restoreLayout(name: layout.name) { _ in } }
                    Button("Remove") { manager.removeLayout(layout.id) }
                }.disabled(manager.layoutBusy)
            }.frame(height: 230)
            Text(manager.lastLayoutResult).font(.caption)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 680)
    }
}
