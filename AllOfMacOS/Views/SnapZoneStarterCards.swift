import SwiftUI

/// 7.24 (menu bar spec §4.2, Rectangle/Moom): with no snap zones the
/// Displays card showed an empty screen. Three starter sets sit under it,
/// each drawn as the zones it adds; one click adds them and turns on Drag
/// to Snap. Zones can be edited afterwards as before.
struct SnapZoneStarterCards: View {
    @EnvironmentObject private var appState: AppState

    static let sets: [CustomSnapZone.Collection] = [.essentials, .corners, .complete]

    var body: some View {
        AOMSection("Start with snap zones", detail: "Drag a window to a zone's edge to place it there") {
            HStack(spacing: AOMSpace.x2) {
                ForEach(Self.sets) { set in
                    Button { apply(set) } label: { card(set) }
                        .buttonStyle(.plain)
                        .aomCalmHover(radius: AOMRadius.card)
                        .help("Adds \(set.layouts.count) zones and turns on Drag to Snap")
                }
            }
            .padding(AOMSpace.x3)
        }
    }

    private func card(_ set: CustomSnapZone.Collection) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Canvas { context, size in
                let screen = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                context.stroke(Path(roundedRect: screen, cornerRadius: 4), with: .color(AOMColor.hairline), lineWidth: 1)
                for layout in set.layouts.prefix(9) where layout != .nextDisplay {
                    let zone = layout.zone()
                    let rect = CGRect(x: screen.minX + zone.targetX * screen.width, y: screen.minY + zone.targetY * screen.height,
                                      width: zone.targetWidth * screen.width, height: zone.targetHeight * screen.height)
                        .insetBy(dx: 2, dy: 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(AOMColor.accent.opacity(0.12)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(AOMColor.accent.opacity(0.55)), lineWidth: 1)
                }
            }
            .frame(height: 64)
            Text(set.rawValue).font(AOMFont.headline)
            Text("\(set.layouts.count) zones").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
        }
        .padding(AOMSpace.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
    }

    private func apply(_ set: CustomSnapZone.Collection) {
        let preset = appState.currentPreset
        appState.updateSnapSettings(zones: set.replacing(preset.customSnapZones), enabled: true,
                                    requiresOption: preset.snappingRequiresOption, showsPreview: preset.snappingShowsPreview)
        GestureHUD.shared.show(title: "Drag to Snap", detail: "\(set.layouts.count) zones added · drag a window to an edge")
    }
}
