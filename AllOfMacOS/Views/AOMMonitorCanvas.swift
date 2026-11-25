import AppKit
import SwiftUI

// Native Workbench 2 (D21): Window Tiling starts from the real displays.
// Each display is drawn at its arrangement position; its usable area
// (`visibleFrame`, without the menu bar and the Dock) is drawn separately from
// the full frame, and the snap zones — stored normalized, 0…1 from the top
// leading corner — are laid out inside the usable area of the selected
// display, as the snapping engine places windows. The engine is unchanged.

/// One display, in AppKit global coordinates (y up).
struct AOMMonitorInfo: Equatable, Identifiable {
    var id: Int
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var isMain: Bool
}

enum AOMMonitorCanvasGeometry {
    /// Where each display is drawn in a canvas of `size` (y down), scaled
    /// uniformly so the whole arrangement fits inside `padding`.
    struct Placed: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    static func layout(_ monitors: [AOMMonitorInfo], in size: CGSize, padding: CGFloat) -> [Placed] {
        guard !monitors.isEmpty, size.width > 2 * padding, size.height > 2 * padding else { return [] }
        let union = monitors.dropFirst().reduce(monitors[0].frame) { $0.union($1.frame) }
        guard union.width > 0, union.height > 0 else { return [] }
        let scale = min((size.width - 2 * padding) / union.width, (size.height - 2 * padding) / union.height)
        let drawn = CGSize(width: union.width * scale, height: union.height * scale)
        let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        func place(_ rect: CGRect) -> CGRect {
            // Flip: AppKit's y grows up from the bottom of the union; the canvas's down from the top.
            CGRect(x: origin.x + (rect.minX - union.minX) * scale,
                   y: origin.y + (union.maxY - rect.maxY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        return monitors.map { Placed(frame: place($0.frame), visibleFrame: place($0.visibleFrame)) }
    }

    /// A normalized zone (0…1, from the top leading corner) inside a drawn
    /// usable area, clamped to it.
    static func zone(x: Double, y: Double, width: Double, height: Double, in visible: CGRect) -> CGRect {
        func unit(_ v: Double) -> CGFloat { CGFloat(v.isFinite ? min(1, max(0, v)) : 0) }
        let minX = unit(x), minY = unit(y)
        let w = min(unit(width), 1 - minX), h = min(unit(height), 1 - minY)
        return CGRect(x: visible.minX + minX * visible.width, y: visible.minY + minY * visible.height,
                      width: w * visible.width, height: h * visible.height)
    }

    /// What the menu bar and the Dock take from a display, in points.
    static func reserved(frame: CGRect, visible: CGRect) -> (top: CGFloat, bottom: CGFloat, leading: CGFloat, trailing: CGFloat) {
        (top: max(0, frame.maxY - visible.maxY), bottom: max(0, visible.minY - frame.minY),
         leading: max(0, visible.minX - frame.minX), trailing: max(0, frame.maxX - visible.maxX))
    }
}

/// The displays and the active snap zones, drawn to scale. Click a display
/// to see its zones and sizes. Reads the screens on appear and when macOS
/// reports a display change; nothing is polled.
struct AOMMonitorCanvas: View {
    let zones: [CustomSnapZone]
    @Binding var selectedID: Int?
    var onEditZones: (Int) -> Void
    @State private var monitors: [AOMMonitorInfo] = []
    private static let canvasHeight: CGFloat = 180

    static func readScreens() -> [AOMMonitorInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue else { return nil }
            return AOMMonitorInfo(id: number, name: screen.localizedName, frame: screen.frame,
                                  visibleFrame: screen.visibleFrame, isMain: index == 0)
        }
    }

    static func isConnected(_ id: Int) -> Bool {
        readScreens().contains { $0.id == id }
    }

    static let disconnectedMessage = "Display disconnected. Select a connected display to edit zones."

    private func select(_ id: Int) {
        // Keep the intended ID even if the click races the removal notification.
        selectedID = id
        if !Self.isConnected(id) { refreshScreens() }
    }

    private var selected: AOMMonitorInfo? {
        monitors.first { $0.id == selectedID }
    }

    private func refreshScreens() {
        monitors = Self.readScreens()
        // Choose an initial display once. Retain a disconnected ID until the
        // user explicitly picks a different display.
        if selectedID == nil { selectedID = (monitors.first(where: \.isMain) ?? monitors.first)?.id }
    }

    var body: some View {
        AOMSection("Displays", padding: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                GeometryReader { proxy in
                    let placed = AOMMonitorCanvasGeometry.layout(monitors, in: proxy.size, padding: AOMSpace.x2)
                    ZStack(alignment: .topLeading) {
                        if placed.count == monitors.count {
                            ForEach(monitors.indices, id: \.self) { index in
                                display(monitors[index], placed[index])
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .frame(height: Self.canvasHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Display arrangement")
                if let monitor = selected {
                    details(monitor)
                } else {
                    Text(selectedID == nil ? "No displays available." : Self.disconnectedMessage)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                }
            }
        }
        .onAppear { refreshScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreens()
        }
    }

    /// One display: its full frame, its usable area inside it and, when it
    /// is the selected one, the zones. Everything is laid out relative to the
    /// display, which is then moved into place, so its click area is the
    /// display itself.
    private func display(_ monitor: AOMMonitorInfo, _ place: AOMMonitorCanvasGeometry.Placed) -> some View {
        let isSelected = monitor.id == selected?.id
        let enabled = zones.filter(\.isEnabled)
        let usable = place.visibleFrame.offsetBy(dx: -place.frame.minX, dy: -place.frame.minY)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                .fill(AOMColor.sunken)
            Rectangle()
                .fill(AOMColor.surface)
                .frame(width: usable.width, height: usable.height)
                .offset(x: usable.minX, y: usable.minY)
            if isSelected {
                ForEach(enabled) { zone in
                    let rect = AOMMonitorCanvasGeometry.zone(x: zone.targetX, y: zone.targetY, width: zone.targetWidth,
                                                             height: zone.targetHeight, in: usable)
                    Rectangle()
                        .fill(AOMColor.accent.opacity(0.14))
                        .overlay { Rectangle().strokeBorder(AOMColor.accent.opacity(0.6), lineWidth: 1) }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .help(zone.name)
                }
            }
            RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                .strokeBorder(isSelected ? AOMColor.accent : AOMColor.hairline, lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: place.frame.width, height: place.frame.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { select(monitor.id) }
        .offset(x: place.frame.minX, y: place.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monitor.name)
        .accessibilityValue("\(Int(monitor.frame.width)) by \(Int(monitor.frame.height)) points\(monitor.isMain ? ", main display" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(monitor.id) }
    }

    private func details(_ monitor: AOMMonitorInfo) -> some View {
        let reserved = AOMMonitorCanvasGeometry.reserved(frame: monitor.frame, visible: monitor.visibleFrame)
        let enabled = zones.filter(\.isEnabled).count
        return VStack(alignment: .leading, spacing: AOMSpace.x1) {
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.name + (monitor.isMain ? " · Main" : ""))
                    .font(AOMFont.headline)
                Spacer(minLength: AOMSpace.x2)
                Button("Edit Snap Zones…") { onEditZones(monitor.id) }.controlSize(.small)
            }
            AOMInspectorRow("Display", text: "\(Int(monitor.frame.width)) × \(Int(monitor.frame.height)) pt")
            AOMInspectorRow("Usable", text: "\(Int(monitor.visibleFrame.width)) × \(Int(monitor.visibleFrame.height)) pt"
                            + (reserved.top > 0 ? " · menu bar \(Int(reserved.top))" : "")
                            + (reserved.bottom + reserved.leading + reserved.trailing > 0
                               ? " · Dock \(Int(max(reserved.bottom, reserved.leading, reserved.trailing)))" : ""))
            AOMInspectorRow("Zones", text: enabled == 0 ? "None on" : "\(enabled) on, drawn in the usable area")
        }
    }
}
