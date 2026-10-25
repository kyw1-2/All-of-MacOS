import AppKit
import SwiftUI

struct SwishEngineCard: View {
    @ObservedObject private var manager = SwishEmbeddedManager.shared
    @AppStorage("AOMSwishEnabled") private var swishEnabled = true

    var body: some View {
        AOMSectionCard(
            "Swish Gestures",
            symbol: "hand.draw.fill",
            detail: manager.isRunning ? "Active" : "Stopped"
        ) {
            Toggle("", isOn: $swishEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: swishEnabled) { _, enabled in
                    if enabled {
                        manager.startIfNeeded()
                    } else {
                        manager.stop()
                    }
                }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.isRunning ? AOMTheme.positive : AOMTheme.textTertiary)
                        .frame(width: 8, height: 8)
                    Text(manager.isRunning ? "Native Swish Engine Running" : "Swish Engine Stopped")
                        .font(AOMType.caption.weight(.medium))
                        .foregroundStyle(manager.isRunning ? AOMTheme.text : AOMTheme.textSecondary)
                    Spacer()
                    if manager.swishCount > 0 {
                        Text("\(manager.swishCount) swishes")
                            .font(AOMType.micro)
                            .foregroundStyle(AOMTheme.textTertiary)
                    }
                }

                Text("Trackpad window gesture suite: swipe window title bars or pinch to snap, maximize, minimize, or close.")
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    gestureRow(gesture: "2-Finger Swipe on Titlebar", action: "Snap Halves / Maximize / Minimize")
                    gestureRow(gesture: "2-Finger Swipe + Option", action: "Snap Thirds (Left/Center/Right)")
                    gestureRow(gesture: "2-Finger Pinch In / Out", action: "Close Window / Fullscreen")
                    gestureRow(gesture: "Modifier Key (\(manager.modifierName))", action: "Trigger anywhere on window")
                }

                Divider()

                HStack(spacing: 8) {
                    Button(manager.isRunning ? "Restart Engine" : "Start Engine") {
                        if manager.isRunning {
                            manager.restart()
                        } else {
                            manager.startIfNeeded()
                        }
                    }
                    .controlSize(.small)

                    Button("Swish Settings…") {
                        manager.openPreferences()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func gestureRow(gesture: String, action: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture)
                    .font(AOMType.micro.weight(.semibold))
                    .foregroundStyle(AOMTheme.text)
                Text(action)
                    .font(AOMType.micro)
                    .foregroundStyle(AOMTheme.textTertiary)
            }
        }
    }
}
