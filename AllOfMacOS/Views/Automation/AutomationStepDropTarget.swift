import SwiftUI

/// Use SwiftUI's local-coordinate drop point to include the last insertion
/// edge. The grip is separate from controls in an expanded step.
struct AutomationStepDropTarget<Row: View>: View {
    let payload: String
    let onDrop: (String, Bool) -> Bool
    @ViewBuilder let row: () -> Row
    @State private var height: CGFloat = 0
    @State private var targeted = false

    @State private var showsGrip = false

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x1) {
            // 7.21 (iStat Menus 7 settings, Things 3): the grip shows while
            // the pointer is over its step, not as a column of handles beside
            // every card. Its slot keeps its width so cards never shift.
            Image(systemName: "line.3.horizontal")
                .font(AOMFont.callout.weight(.medium))
                .foregroundStyle(AOMColor.textSecondary)
                .opacity(showsGrip ? 1 : 0)
                .frame(width: AOMIcon.hitArea, height: AOMSize.rowSingle)
                .contentShape(Rectangle())
                .draggable(payload)
                .help("Drag to reorder this step within its group")
                .accessibilityHidden(true) // Move Up and Move Down expose the keyboard equivalent.
            row()
        }
        .onHover { showsGrip = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .dropDestination(for: String.self) { values, point in
            guard values.count == 1, let value = values.first else { return false }
            return onDrop(value, point.y > height / 2)
        } isTargeted: { targeted = $0 }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: AOMRadius.control).strokeBorder(AOMColor.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
