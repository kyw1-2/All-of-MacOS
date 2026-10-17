import AppKit
import SwiftUI

/// The Background Tool as a left sidebar (CleanShot `ANBackgroundSettings`):
/// Presets · Gradients · Wallpapers · Blurred · Plain color · Padding / Inset /
/// Shadow / Corners · Auto-balance · Alignment · Ratio.
struct AnnotationBackgroundPanel: View {
    @Binding var background: AnnotationBackground
    /// Opens one undo step before a discrete change (or a slider drag).
    let beginChange: () -> Void
    /// A small copy of the screenshot for the "Blurred" swatch.
    let screenshotThumbnail: CGImage?
    let onClose: () -> Void

    @State private var store = AnnotationBackgroundPresetStore.load()
    @State private var selectedPresetID: UUID?
    @State private var wallpapers: [AnnotationWallpaperLibrary.Wallpaper] = []
    @State private var showsAllWallpapers = false
    @State private var showsAllGradients = false
    @State private var namingPreset: NamingMode?
    @State private var presetName = ""

    private enum NamingMode: Identifiable {
        case add, rename(UUID)
        var id: String {
            switch self {
            case .add: return "add"
            case .rename(let id): return id.uuidString
            }
        }
    }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    presets
                    gradients
                    wallpaperSection
                    blurred
                    plainColor
                    Divider()
                    sliders
                    alignmentAndRatio
                }
                .padding(14)
            }
        }
        .frame(width: 264)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background tool")
        .task {
            let found = await Task.detached(priority: .utility) { AnnotationWallpaperLibrary.catalog() }.value
            wallpapers = found
        }
        .sheet(item: $namingPreset) { mode in namingSheet(mode) }
        .onAppear {
            // An auto-applied preset shows as the current one.
            if selectedPresetID == nil, let auto = store.autoApplyPreset, auto.background == background {
                selectedPresetID = auto.id
            }
        }
    }

    // MARK: - Header & presets

    private var header: some View {
        HStack {
            Image(systemName: "photo.artframe").foregroundStyle(.secondary)
            Text("Background").font(.headline)
            Spacer()
            Button("None") { change { $0 = AnnotationBackground() } }
                .controlSize(.small)
                .disabled(!background.isExpanded)
                .help("Remove the background")
            Button { onClose() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain)
                .help("Hide Background Tool (B)")
                .accessibilityLabel("Hide Background Tool")
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    private var selectedPreset: AnnotationBackgroundPreset? {
        selectedPresetID.flatMap { id in store.presets.first { $0.id == id } }
    }

    private var presets: some View {
        section("Presets") {
            HStack(spacing: 6) {
                Menu {
                    if store.presets.isEmpty { Text("No saved presets") }
                    ForEach(store.presets) { preset in
                        Button {
                            selectedPresetID = preset.id
                            change { $0 = preset.background }
                        } label: {
                            if preset.id == selectedPresetID { Label(preset.name, systemImage: "checkmark") }
                            else { Text(preset.name) }
                        }
                    }
                    Divider()
                    Button("Add New Preset…") { presetName = "Preset \(store.presets.count + 1)"; namingPreset = .add }
                    Button("Apply Previous Settings") {
                        if let previous = store.previous { change { $0 = previous } }
                    }
                    .disabled(store.previous == nil)
                    if let preset = selectedPreset {
                        Divider()
                        Button("Update “\(preset.name)” with Current Settings") {
                            store.update(preset.id, with: background); store.save()
                        }
                        Button("Rename “\(preset.name)”…") { presetName = preset.name; namingPreset = .rename(preset.id) }
                        Button("Delete “\(preset.name)”", role: .destructive) {
                            store.delete(preset.id); store.save(); selectedPresetID = nil
                        }
                    }
                } label: {
                    Text(selectedPreset?.name ?? "Choose Preset")
                        .lineLimit(1)
                }
                .help("Background presets")
                .accessibilityLabel("Background presets")
                Button { presetName = "Preset \(store.presets.count + 1)"; namingPreset = .add } label: {
                    Image(systemName: "plus")
                }
                .help("Save current settings as a new preset")
                .accessibilityLabel("Add New Preset")
                .disabled(!background.isExpanded)
            }
            Toggle("Automatically apply preset to new screenshots", isOn: Binding(
                get: { selectedPresetID != nil && store.autoApplyID == selectedPresetID },
                set: { on in
                    store.autoApplyID = on ? selectedPresetID : nil
                    store.save()
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(selectedPresetID == nil)
                .help(selectedPresetID == nil ? "Choose or save a preset first"
                                              : "New screenshots open with this background")
            if let auto = store.autoApplyPreset, auto.id != selectedPresetID {
                Text("Auto-applied: \(auto.name)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func namingSheet(_ mode: NamingMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text({ if case .add = mode { return "Add New Preset" } else { return "Rename Preset" } }())
                .font(.headline)
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .accessibilityLabel("Preset name")
            HStack {
                Spacer()
                Button("Cancel") { namingPreset = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    switch mode {
                    case .add:
                        if let id = store.add(name: presetName, background: background) { selectedPresetID = id }
                    case .rename(let id):
                        store.rename(id, to: presetName)
                    }
                    store.save()
                    namingPreset = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(AnnotationBackgroundPresetStore.sanitizedName(presetName) == nil)
            }
        }
        .padding(20)
    }

    // MARK: - Sources

    private var gradients: some View {
        section("Gradients") {
            let all = AnnotationBackground.GradientPreset.gallery
            LazyVGrid(columns: grid, spacing: 6) {
                ForEach(showsAllGradients ? all : Array(all.prefix(8))) { preset in
                    tile(selected: on(.gradient) && background.gradientPreset == preset,
                         label: "\(preset.displayName) gradient") {
                        LinearGradient(colors: preset.stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) },
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    } action: {
                        change(revealing: true) { $0.kind = .gradient; $0.gradientPreset = preset }
                    }
                }
                tile(selected: on(.gradient) && background.gradientPreset == .custom,
                     label: "Custom gradient") {
                    LinearGradient(colors: [Color(nsColor: background.gradientStart.nsColor),
                                            Color(nsColor: background.gradientEnd.nsColor)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(.white))
                } action: {
                    change(revealing: true) { $0.kind = .gradient; $0.gradientPreset = .custom }
                }
            }
            if all.count > 8 {
                Button(showsAllGradients ? "Show Less" : "Show More") { showsAllGradients.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            if on(.gradient) && background.gradientPreset == .custom {
                Text("From").font(.caption2).foregroundStyle(.secondary)
                swatches(selection: background.gradientStart) { color in change { $0.gradientStart = color } }
                Text("To").font(.caption2).foregroundStyle(.secondary)
                swatches(selection: background.gradientEnd) { color in change { $0.gradientEnd = color } }
            }
        }
    }

    private var wallpaperSection: some View {
        section("Wallpapers") {
            if wallpapers.isEmpty {
                Text("No system desktop pictures found.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach(showsAllWallpapers ? wallpapers : Array(wallpapers.prefix(12))) { wallpaper in
                        tile(selected: on(.wallpaper) && background.wallpaperPath == wallpaper.path,
                             label: "\(wallpaper.name) wallpaper") {
                            WallpaperThumbnail(path: wallpaper.thumbnailPath)
                        } action: {
                            change(revealing: true) { $0.kind = .wallpaper; $0.wallpaperPath = wallpaper.path }
                        }
                    }
                }
                if wallpapers.count > 12 {
                    Button(showsAllWallpapers ? "Show Less" : "Show All \(wallpapers.count)") {
                        showsAllWallpapers.toggle()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var blurred: some View {
        section("Blurred") {
            LazyVGrid(columns: grid, spacing: 6) {
                tile(selected: on(.blurred), label: "Blurred screenshot") {
                    if let screenshotThumbnail {
                        Image(decorative: screenshotThumbnail, scale: 1).resizable().scaledToFill().blur(radius: 4)
                    } else {
                        Color.gray
                    }
                } action: {
                    change(revealing: true) { $0.kind = .blurred }
                }
            }
        }
    }

    private var plainColor: some View {
        section("Plain color") {
            swatches(selection: on(.solid) && background.solidHex == nil ? background.color : nil) { color in
                change(revealing: true) { $0.kind = .solid; $0.color = color; $0.solidHex = nil }
            }
            HStack {
                ColorPicker("Custom color", selection: Binding(
                    get: { Color(nsColor: background.resolvedSolidColor) },
                    set: { value in
                        guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                        let hex = String(AnnotationColorLibrary.hex(of: rgb).prefix(6))
                        change(revealing: true) { $0.kind = .solid; $0.solidHex = hex }
                    }), supportsOpacity: false)
                    .font(.caption)
                    .help("Choose any plain colour")
            }
        }
    }

    // MARK: - Geometry

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Padding", value: $background.padding, range: 0...200, unit: "pt")
            slider("Inset", value: $background.inset, range: 0...100, unit: "pt")
            slider("Shadow", value: Binding(get: { background.shadow * 100 }, set: { background.shadow = $0 / 100 }),
                   range: 0...100, unit: "%")
            slider("Corners", value: $background.cornerRadius, range: 0...60, unit: "pt")
            Toggle("Auto-balance", isOn: Binding(get: { background.autoBalance },
                                                  set: { on in change { $0.autoBalance = on } }))
                .toggleStyle(.switch).controlSize(.small)
                .help("Centres the screenshot's visible content by treating uniform borders as padding")
        }
    }

    private var alignmentAndRatio: some View {
        HStack(alignment: .top, spacing: 18) {
            section("Alignment") {
                VStack(spacing: 3) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<3) { column in
                                let cell = row * 3 + column
                                Button { change { $0.alignment = cell } } label: {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(background.alignment == cell ? Color.accentColor : Color.primary.opacity(0.12))
                                        .frame(width: 20, height: 16)
                                }
                                .buttonStyle(.plain)
                                .help(Self.alignmentNames[cell])
                                .accessibilityLabel("Align \(Self.alignmentNames[cell])")
                                .accessibilityAddTraits(background.alignment == cell ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            section("Ratio") {
                Picker("Ratio", selection: Binding(get: { background.ratio },
                                                   set: { ratio in change { $0.ratio = ratio } })) {
                    ForEach(AnnotationBackground.Ratio.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 92)
                .help("Canvas aspect ratio")
            }
        }
    }

    /// A source is only "selected" while a background is actually shown.
    private func on(_ kind: AnnotationBackground.Kind) -> Bool {
        background.isExpanded && background.kind == kind
    }

    static let alignmentNames = ["Top Left", "Top", "Top Right", "Left", "Center", "Right",
                                 "Bottom Left", "Bottom", "Bottom Right"]

    // MARK: - Helpers

    /// One undoable change; picking a source on a bare canvas also adds padding
    /// so the choice is visible straight away.
    private func change(revealing: Bool = false, _ mutate: (inout AnnotationBackground) -> Void) {
        var updated = background
        mutate(&updated)
        if revealing, !updated.isExpanded { updated.padding = 32 }
        guard updated != background else { return }
        beginChange()
        background = updated
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }

    private func tile<Content: View>(selected: Bool, label: String, @ViewBuilder content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Overlay on a fixed-size base so scaled-to-fill thumbnails cannot
            // grow the grid cell.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .overlay(content())
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: selected ? 2.5 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatches(selection: AnnotationColor?, choose: @escaping (AnnotationColor) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(AnnotationColor.allCases) { choice in
                Button { choose(choice) } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: choice.nsColor))
                        .frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(selection == choice ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: selection == choice ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help(choice.displayName)
                .accessibilityLabel(choice.displayName)
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(unit)").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if editing { beginChange() }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(value.wrappedValue.rounded())) \(unit)")
        }
    }
}

/// Lazily decoded wallpaper thumbnail (system file, read at runtime).
private struct WallpaperThumbnail: View {
    let path: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.08)
            }
        }
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) {
                AnnotationWallpaperLibrary.image(atPath: path, maxPixelSize: 128)
            }.value
        }
    }
}
