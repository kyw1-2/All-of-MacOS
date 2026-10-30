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
    static func present(windows: [SCWindow], title: String = "Capture Window",
                        actionLabel: String = "Capture", showsThumbnails: Bool = false) async -> SCWindow? {
        await withCheckedContinuation { continuation in
            let controller = WindowPickerPanel(windows: windows, title: title, actionLabel: actionLabel, showsThumbnails: showsThumbnails) { chosen in
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

    init(windows: [SCWindow], title: String = "Capture Window", actionLabel: String = "Capture",
         showsThumbnails: Bool = false, completion: @escaping (SCWindow?) -> Void) {
        self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.applyCaptureVisibilityPreference()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: WindowPickerView(
            windows: windows, actionLabel: actionLabel, showsThumbnails: showsThumbnails,
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
        // Destroy the hosting tree so thumbnail tasks stop even if AppKit keeps
        // the closed NSWindow alive briefly.
        self.window?.contentView = nil
        self.window?.close()
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
    var actionLabel = "Capture"
    var showsThumbnails = false
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
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "magnifyingglass").foregroundStyle(AOMColor.textSecondary)
                TextField("Search windows", text: $search)
                    .textFieldStyle(.plain)
                    .font(AOMFont.body)
            }
            .padding(AOMSpace.x3)
            AOMDivider()

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMSize.tileMin - AOMSpace.x5), spacing: AOMSpace.tileGap)],
                          spacing: AOMSpace.tileGap) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, window in
                        WindowCell(window: window, actionLabel: actionLabel, showsThumbnail: showsThumbnails) { onSelect(window) }
                    }
                }
                .padding(AOMSpace.x3)
            }

            AOMDivider()
            HStack {
                Text("\(filtered.count) window\(filtered.count == 1 ? "" : "s")")
                    .font(AOMFont.caption).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(AOMSpace.x3)
        }
        .frame(minWidth: AOMFeatureSize.windowPickerMin.width, minHeight: AOMFeatureSize.windowPickerMin.height)
        .background(AOMColor.canvas)
    }
}

private struct WindowCell: View {
    let window: SCWindow
    var actionLabel = "Capture"
    var showsThumbnail = false
    @State private var thumbnail: NSImage?
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
            VStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                ZStack {
                    RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                        .fill(AOMColor.sunken)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: AOMFeatureSize.fileIcon, height: AOMFeatureSize.fileIcon)
                    } else {
                        Image(systemName: "macwindow")
                            .font(AOMFont.hero.weight(.regular))
                            .imageScale(.large)
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                }
                .frame(height: AOMFeatureSize.windowPickerThumbnail)

                Text(title)
                    .font(AOMFont.caption.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(appName) · \(Int(window.frame.width))×\(Int(window.frame.height))")
                    .font(AOMFont.badge.weight(.regular)).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            .padding(AOMSpace.x2)
            .frame(maxWidth: .infinity)
            .background(isHovering ? AOMColor.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(actionLabel) window \(title) from \(appName)")
        .task(id: window.windowID) {
            guard showsThumbnail else { return }
            // Visible cells refresh at one Hz; cancellation releases each task
            // as the picker closes or the cell leaves the lazy grid.
            while !Task.isCancelled {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(1, 400 / max(1, window.frame.width))
                configuration.width = max(2, Int(window.frame.width * scale))
                configuration.height = max(2, Int(window.frame.height * scale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), !Task.isCancelled {
                    thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }
}
