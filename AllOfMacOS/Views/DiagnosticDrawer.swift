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
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "terminal.fill")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityHidden(true)
                Text("Diagnostics")
                    .font(AOMFont.section)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Button {
                    openDetachedWindow()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Detach into floating window")
                .accessibilityLabel("Detach into floating window")

                Button {
                    withAnimation(AOMMotion.panel) {
                        showLog = false
                        showTouchVisualizer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(AOMFont.caption.weight(.semibold))
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close diagnostics panel")
                .accessibilityLabel("Close diagnostics panel")
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(height: AOMSize.rowStandard)

            AOMDivider()

            if showLog {
                LogSidePanel(entries: gestureLog.entries)
                    .frame(maxHeight: .infinity)
            }

            if showTouchVisualizer {
                if showLog { AOMDivider() }
                VStack(spacing: AOMSpace.x1) {
                    HStack {
                        Image(systemName: "hand.point.up.braille.fill")
                            .font(AOMFont.badge)
                            .foregroundStyle(AOMColor.textSecondary)
                            .accessibilityHidden(true)
                        Text("Live Touch Visualizer")
                            .font(AOMFont.caption.weight(.medium))
                            .foregroundStyle(AOMColor.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.top, AOMSpace.x1 + AOMSpace.x0_5)

                    LiveTouchView()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AOMSpace.x2)
                        .padding(.bottom, AOMSpace.x2)
                }
                .frame(height: showLog ? AOMFeatureSize.touchVisualizer : AOMFeatureSize.touchVisualizerTall)
                .background(AOMColor.surface)
            }
        }
        // The shell gives the drawer its width (AOMSize.drawerWidth); it is an
        // inspector, so it is opaque content with a hairline edge (c.4).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMColor.canvas)
        .overlay(alignment: .leading) {
            AOMDivider(axis: .vertical)
        }
    }

    private func openDetachedWindow() {
        withAnimation(AOMMotion.panel) {
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

            VStack(spacing: AOMSpace.x1) {
                HStack {
                    Text("Live Touch Visualizer")
                        .font(AOMFont.caption.weight(.medium))
                        .foregroundStyle(AOMColor.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, AOMSpace.x2)
                .padding(.top, AOMSpace.x1)

                LiveTouchView()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.bottom, AOMSpace.x2)
            }
            .frame(height: AOMFeatureSize.touchVisualizer)
            .background(AOMColor.surface)
        }
        .frame(minWidth: 280, minHeight: 400)
    }
}
