import AppKit
import SwiftUI

struct LogSidePanel: View {
    let entries: [GestureLogEntry]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "terminal.fill")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityHidden(true)
                Text("Console")
                    .font(AOMFont.callout.weight(.semibold))
                    .foregroundStyle(AOMColor.text)
                Spacer()
                AOMIconButton("doc.on.doc", label: "Copy Console") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.map(LogEntryRow.line).joined(separator: "\n"), forType: .string)
                }
                .disabled(entries.isEmpty)
                AOMIconButton("trash", label: "Clear Console") { GestureLog.shared.entries.removeAll() }
                    .disabled(entries.isEmpty)
            }
            .padding(.leading, AOMSpace.rowInset)
            .padding(.trailing, AOMSpace.x1)
            .padding(.vertical, AOMSpace.x0_5)
            .background(AOMColor.surface)

            AOMDivider()

            // Log entries; an empty console says what will appear (b.6).
            if entries.isEmpty {
                AOMInlineEmpty(symbol: "waveform.path.ecg", message: "Gestures, shortcuts and the actions they run appear here as they happen.")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
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

    /// The row as one line of text (Copy, Copy Console).
    static func line(_ entry: GestureLogEntry) -> String {
        "\(timeFormatter.string(from: entry.timestamp))  \(entry.message)"
    }

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
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x0_5)
        .background(
            entry.level == .fire
                ? colorForLevel(entry.level).opacity(ripple ? 0 : 0.08)
                : Color.clear
        )
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.line(entry), forType: .string)
            }
        }
        .onAppear {
            if entry.level == .fire {
                withAnimation(AOMDesign.animation(.easeOut(duration: 0.6))) {
                    ripple = true
                }
            }
        }
    }

    /// Text colours that keep 4.5:1 on the canvas in both modes (3.4: the
    /// raw cyan and orange read poorly on white).
    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .detect:  return AOMColor.accent
        case .fire:    return AOMColor.successText
        case .action:  return AOMColor.text
        case .noMatch: return AOMColor.textTertiary
        case .error:   return AOMColor.dangerText
        }
    }
}
