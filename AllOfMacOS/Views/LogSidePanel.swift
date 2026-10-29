import SwiftUI

struct LogSidePanel: View {
    let entries: [GestureLogEntry]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "terminal.fill")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityHidden(true)
                Text("Console")
                    .font(AOMFont.callout.weight(.semibold))
                    .foregroundStyle(AOMColor.text)
                Spacer()
                Button(action: { GestureLog.shared.entries.removeAll() }) {
                    Image(systemName: "trash")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the console")
                .accessibilityLabel("Clear console")
            }
            .padding(.horizontal, AOMSpace.x3)
            .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
            .background(AOMColor.surface)

            AOMDivider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.vertical, AOMSpace.x1)
                }
                .onChange(of: entries.count) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(AOMMotion.quick) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(AOMColor.canvas)
        .overlay(alignment: .leading) {
            AOMDivider(axis: .vertical)
        }
    }
}

private struct LogEntryRow: View {
    let entry: GestureLogEntry
    @State private var ripple = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x1) {
            Circle()
                .fill(colorForLevel(entry.level))
                .frame(width: AOMIcon.dot, height: AOMIcon.dot)
                .padding(.top, AOMSpace.x1)
                .overlay(
                    Circle()
                        .stroke(colorForLevel(entry.level).opacity(ripple ? 0 : 0.6), lineWidth: 1.5)
                        .frame(width: ripple ? AOMIcon.row : AOMIcon.dot, height: ripple ? AOMIcon.row : AOMIcon.dot)
                        .opacity(entry.level == .fire ? 1 : 0)
                )

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(AOMColor.textSecondary)

            Text(entry.message)
                .foregroundStyle(colorForLevel(entry.level))
                .textSelection(.enabled)
        }
        .font(AOMFont.mono)
        .padding(.horizontal, AOMSpace.x2)
        .padding(.vertical, AOMSpace.x0_5)
        .background(
            entry.level == .fire
                ? colorForLevel(entry.level).opacity(ripple ? 0 : 0.08)
                : Color.clear
        )
        .onAppear {
            if entry.level == .fire {
                withAnimation(AOMDesign.animation(.easeOut(duration: 0.6))) {
                    ripple = true
                }
            }
        }
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .detect:  return .cyan
        case .fire:    return .green
        case .action:  return .orange
        case .noMatch: return Color(nsColor: .tertiaryLabelColor)
        case .error:   return .red
        }
    }
}
