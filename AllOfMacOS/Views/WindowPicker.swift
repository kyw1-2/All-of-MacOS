import AppKit
import SwiftUI
import ScreenCaptureKit

/// A grid of open windows to capture, for when pointing at the window is not
/// practical — it is behind another one, or off screen.
///
/// This is a sheet-like modal rather than a menu because each entry needs to show
/// a preview and the owning application's icon, which a menu cannot draw.
@MainActor
enum WindowPickerController {
    /// Presents the picker and returns the chosen window, or nil if cancelled.
    static func present(windows: [SCWindow]) async -> SCWindow? {
        await withCheckedContinuation { continuation in
            let controller = WindowPickerPanel(windows: windows) { chosen in
                continuation.resume(returning: chosen)
            }
            controller.present()
            // Keep the controller alive until it reports back; the panel would
            // otherwise be deallocated the moment this function returns.
            activeControllers.append(controller)
        }
    }

    private static var activeControllers: [WindowPickerPanel] = []

    fileprivate static func release(_ controller: WindowPickerPanel) {
        activeControllers.removeAll { $0 === controller }
    }
}

@MainActor
final class WindowPickerPanel: NSWindowController {
    private let completion: (SCWindow?) -> Void
    private var didFinish = false

    init(windows: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Capture Window"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: WindowPickerView(
            windows: windows,
            onSelect: { [weak self] window in self?.finish(window) },
            onCancel: { [weak self] in self?.finish(nil) }
        ))
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ window: SCWindow?) {
        guard !didFinish else { return }
        didFinish = true
        self.window?.orderOut(nil)
        completion(window)
        WindowPickerController.release(self)
    }
}

extension WindowPickerPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}

private struct WindowPickerView: View {
    let windows: [SCWindow]
    let onSelect: (SCWindow) -> Void
    let onCancel: () -> Void

    @State private var search = ""

    private var filtered: [SCWindow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter { window in
            (window.title ?? "").localizedCaseInsensitiveContains(query) ||
            (window.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search windows", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, window in
                        WindowCell(window: window) { onSelect(window) }
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Text("\(filtered.count) window\(filtered.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct WindowCell: View {
    let window: SCWindow
    let onSelect: () -> Void

    @State private var isHovering = false

    private var appName: String { window.owningApplication?.applicationName ?? "Unknown" }
    private var title: String { window.title?.isEmpty == false ? window.title! : appName }

    /// `SCRunningApplication` carries no icon, only a bundle identifier, so the
    /// icon is looked up from the installed application. A window whose owner has
    /// no discoverable bundle (a helper process) falls back to a generic symbol.
    private var appIcon: NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 96)

                Text(title)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(appName) · \(Int(window.frame.width))×\(Int(window.frame.height))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Capture window \(title) from \(appName)")
    }
}
