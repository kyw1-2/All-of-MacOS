import AppKit
import SwiftUI

/// Detachable Diagnostics & Live Touch Drawer.
/// Replaces the permanent 260pt window split with an on-demand slide-in panel
/// that can also be detached into an independent floating utility window.
struct DiagnosticDrawerView: View {
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    @ObservedObject private var gestureLog = GestureLog.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("Diagnostics")
                    .font(.system(size: 11, weight: .bold))
                Spacer()

                Button {
                    openDetachedWindow()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Detach into floating window")

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showLog = false
                        showTouchVisualizer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close diagnostics panel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background.opacity(0.5))

            Divider()

            if showLog {
                LogSidePanel(entries: gestureLog.entries)
                    .frame(maxHeight: .infinity)
            }

            if showTouchVisualizer {
                if showLog { Divider() }
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "hand.point.up.braille.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.cyan)
                        Text("Live Touch Visualizer")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    LiveTouchView()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
                .frame(height: showLog ? 180 : 240)
                .background(.background.opacity(0.30))
            }
        }
        .frame(width: 270)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5),
            alignment: .leading
        )
    }

    private func openDetachedWindow() {
        withAnimation {
            showLog = false
            showTouchVisualizer = false
        }
        DiagnosticFloatingWindowController.shared.show()
    }
}

/// Floating window for diagnostics when detached from main window
final class DiagnosticFloatingWindowController: NSWindowController {
    static let shared = DiagnosticFloatingWindowController()

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "AOM Diagnostics"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: DetachedDiagnosticsView())
        self.init(window: panel)
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DetachedDiagnosticsView: View {
    @ObservedObject private var gestureLog = GestureLog.shared

    var body: some View {
        VStack(spacing: 0) {
            LogSidePanel(entries: gestureLog.entries)
                .frame(maxHeight: .infinity)

            Divider()

            VStack(spacing: 4) {
                HStack {
                    Text("Live Touch Visualizer")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                LiveTouchView()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            .frame(height: 180)
            .background(.background.opacity(0.30))
        }
        .frame(minWidth: 280, minHeight: 400)
    }
}
