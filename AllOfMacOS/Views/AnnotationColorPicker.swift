import AppKit
import SwiftUI

/// CleanShot-style advanced colour picker for annotations: default palette,
/// "My Colors" (persisted, limited), recent colours, hex + R/G/B/A fields, an
/// opacity slider and a screen eyedropper (NSColorSampler).
struct AnnotationColorPickerView: View {
    /// Current colour (RGB; alpha is carried separately as `opacity`).
    let color: NSColor
    let opacity: Double
    /// Applies an sRGB colour and an opacity 0…1.
    let apply: (NSColor, Double) -> Void
    /// Palette swatches apply the named colour (keeps presets portable).
    let applyPalette: (AnnotationColor) -> Void

    @State private var library = AnnotationColorLibrary.load()
    @State private var hexText = ""
    @State private var red = 0
    @State private var green = 0
    @State private var blue = 0
    @State private var alphaPercent = 100
    @State private var message: String?
    @State private var sampler: NSColorSampler?

    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Color").font(.headline)
                Spacer()
                Button { pickFromScreen() } label: {
                    Label("Pick from Screen", systemImage: "eyedropper")
                }
                .help("Pick a colour from anywhere on screen (eyedropper)")
                .accessibilityLabel("Pick color from screen")
            }

            section("Default") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(AnnotationColor.palette) { named in
                        swatch(named.nsColor, label: named.displayName,
                               selected: currentHex.prefix(6) == AnnotationColorLibrary.hex(of: named.nsColor).prefix(6)) {
                            applyPalette(named)
                            load(from: named.nsColor, opacity: opacity)
                            noteRecent()
                        }
                    }
                }
            }

            section("My Colors") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(Array(library.myColors.enumerated()), id: \.offset) { index, hex in
                        if let swatchColor = AnnotationColorLibrary.color(fromHex: hex) {
                            swatch(swatchColor, label: "My color \(index + 1), #\(hex.prefix(6))",
                                   selected: hex == currentHex) {
                                applyHex(hex)
                                noteRecent()
                            }
                            .contextMenu {
                                Button("Update with Current Color") {
                                    _ = library.replaceMyColor(at: index, with: currentHex)
                                    library.save()
                                }
                                Button("Remove", role: .destructive) {
                                    library.removeMyColor(at: index)
                                    library.save()
                                }
                            }
                        }
                    }
                    Button { addToMyColors() } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6),
                                                           style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    }
                    .buttonStyle(.plain)
                    .help("Add to My Colors (up to \(AnnotationColorLibrary.myColorsLimit))")
                    .accessibilityLabel("Add to My Colors")
                }
                if library.myColors.isEmpty {
                    Text("Click + to save the current colour. Right-click a saved colour to update or remove it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !library.recent.isEmpty {
                section("Recent") {
                    HStack(spacing: 6) {
                        ForEach(library.recent, id: \.self) { hex in
                            if let recentColor = AnnotationColorLibrary.color(fromHex: hex) {
                                swatch(recentColor, label: "Recent #\(hex.prefix(6))", selected: hex == currentHex) {
                                    applyHex(hex)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: currentColor))
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hex").font(.caption).foregroundStyle(.secondary)
                    TextField("RRGGBB", text: $hexText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 96)
                        .onSubmit { applyHex(hexText); noteRecent() }
                        .accessibilityLabel("Hex color")
                        .help("RGB, RRGGBB or RRGGBBAA")
                }
                ColorPicker("More Colors", selection: Binding(
                    get: { Color(nsColor: currentColor) },
                    set: { value in
                        guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                        load(from: rgb, opacity: Double(alphaPercent) / 100)
                        commitFields()
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .help("System colour panel")
            }

            HStack(spacing: 8) {
                componentField("R", value: $red, range: 0...255)
                componentField("G", value: $green, range: 0...255)
                componentField("B", value: $blue, range: 0...255)
                componentField("A", value: $alphaPercent, range: 0...100, suffix: "%")
            }

            HStack(spacing: 8) {
                Text("Opacity").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(alphaPercent) },
                                      set: { alphaPercent = Int($0.rounded()); commitFields() }),
                       in: 0...100)
                    .accessibilityLabel("Opacity")
                    .accessibilityValue("\(alphaPercent) percent")
                Text("\(alphaPercent)%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { load(from: color, opacity: opacity) }
        .onDisappear { noteRecent() }
    }

    // MARK: - State

    private var currentColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
                alpha: CGFloat(alphaPercent) / 100)
    }

    private var currentHex: String {
        AnnotationColorLibrary.hex(r: red, g: green, b: blue, a: Int((Double(alphaPercent) * 2.55).rounded()))
    }

    private func load(from nsColor: NSColor, opacity: Double) {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? .black
        red = Int((rgb.redComponent * 255).rounded())
        green = Int((rgb.greenComponent * 255).rounded())
        blue = Int((rgb.blueComponent * 255).rounded())
        alphaPercent = Int((min(1, max(0, opacity)) * 100).rounded())
        hexText = String(currentHex.prefix(6))
    }

    private func commitFields() {
        hexText = String(currentHex.prefix(6))
        apply(NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1),
              Double(alphaPercent) / 100)
    }

    private func applyHex(_ text: String) {
        guard let (r, g, b, a) = AnnotationColorLibrary.components(ofHex: text) else {
            message = "Enter a hex colour like FF3B30 or FF3B30CC."
            return
        }
        message = nil
        red = r; green = g; blue = b
        // 6-digit hex keeps the current opacity; 8-digit sets it.
        if text.filter(\.isHexDigit).count == 8 {
            alphaPercent = Int((Double(a) / 2.55).rounded())
        }
        commitFields()
    }

    private func addToMyColors() {
        switch library.addToMyColors(currentHex) {
        case .added: message = nil; library.save()
        case .duplicate: message = "This colour is already in My Colors."
        case .limitReached:
            message = "My Colors is full (\(AnnotationColorLibrary.myColorsLimit)). Right-click a colour to replace or remove it."
        case .invalid: message = "Invalid colour."
        }
    }

    private func noteRecent() {
        library.noteRecent(currentHex)
        library.save()
    }

    private func pickFromScreen() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { picked in
            guard let picked, let rgb = picked.usingColorSpace(.sRGB) else { return }
            DispatchQueue.main.async {
                load(from: rgb, opacity: Double(alphaPercent) / 100)
                commitFields()
                noteRecent()
                self.sampler = nil
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatch(_ swatchColor: NSColor, label: String, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(Color(nsColor: swatchColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func componentField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                                suffix: String = "") -> some View {
        VStack(spacing: 2) {
            TextField(title, value: Binding(get: { value.wrappedValue },
                                            set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0))
                                                   commitFields() }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 52)
                .accessibilityLabel(title == "A" ? "Alpha percent" : "\(title) component")
            Text(title + suffix).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
