import SwiftUI

/// The last few gesture log lines in one quiet well (monospaced, a status dot
/// per line in the level's tone).
struct GestureConsoleView: View {
    let entries: [GestureLogEntry]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: "terminal.fill")
                .imageScale(.small)
                .foregroundStyle(AOMColor.textSecondary)
                .accessibilityHidden(true)

            if entries.isEmpty {
                Text("No gestures detected yet")
                    .font(AOMFont.mono)
                    .foregroundStyle(AOMColor.textTertiary)
            } else {
                let recent = entries.suffix(5)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    ForEach(Array(recent)) { entry in
                        HStack(spacing: AOMSpace.x1) {
                            Circle()
                                .fill(colorForLevel(entry.level))
                                .frame(width: AOMIcon.dot, height: AOMIcon.dot)
                                .accessibilityHidden(true)
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .foregroundStyle(AOMColor.textSecondary)
                            Text(entry.message)
                                .foregroundStyle(colorForLevel(entry.level))
                        }
                        .font(AOMFont.mono)
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .padding(.vertical, AOMSpace.x2)
        .background(AOMColor.raised, in: shape)
        .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .frame(minWidth: AOMEditorSize.console.lowerBound, maxWidth: AOMEditorSize.console.upperBound)
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .detect:  return AOMColor.info
        case .fire:    return AOMColor.successText
        case .action:  return AOMColor.warningText
        case .noMatch: return AOMColor.textTertiary
        case .error:   return AOMColor.dangerText
        }
    }
}
