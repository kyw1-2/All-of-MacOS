import AppKit
import SwiftUI

/// What the Capture Text result HUD shows.
struct TextCaptureHUDModel: Equatable {
    var title: String
    var subtitle: String
    var text: String
    var links: [URL]
    var barcodes: [String]
    var languageCode: String?
    var symbol: String
}

/// TextSniper confirms with a small emoji + label HUD that fades on its own.
/// AOM keeps that rhythm (non-activating, auto-dismissing, near the
/// selection) but also previews the text and offers Copy, Edit, Speak and
/// Share, plus Open for detected links. Hovering pauses the fade.
@MainActor
final class TextCaptureHUDController {
    static let shared = TextCaptureHUDController()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var hovering = false
    private var duration: TimeInterval = 6
    private(set) var currentModel: TextCaptureHUDModel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ model: TextCaptureHUDModel, anchor: CGRect?, duration: TimeInterval) {
        guard NSApp != nil else { return }
        currentModel = model
        self.duration = duration
        let panel = panel ?? makePanel()
        self.panel = panel

        let view = TextCaptureHUDView(
            model: model,
            speech: TextCaptureSpeech.shared,
            onCopy: { [weak self] in self?.copy(model.text) },
            onEdit: { [weak self] in
                self?.dismiss()
                TextCaptureEditorWindowController.shared.open(text: model.text, languageCode: model.languageCode)
            },
            onSpeak: { TextCaptureSpeech.shared.toggle(model.text, languageCode: model.languageCode) },
            onOpen: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.dismiss()
            },
            onClose: { [weak self] in self?.dismiss() },
            onHover: { [weak self] inside in self?.setHovering(inside) })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let frame = NSRect(origin: .zero, size: NSSize(width: 380, height: max(96, size.height)))
        hosting.frame = frame

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        panel.setContentSize(frame.size)
        panel.setFrameOrigin(Self.origin(for: frame.size, anchor: anchor))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        hovering = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        GestureHUD.shared.show(title: "Copied", detail: "\(text.count) characters")
        dismiss()
    }

    private func setHovering(_ inside: Bool) {
        hovering = inside
        if inside { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let delay = duration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        return panel
    }

    /// Below the captured region (CG global coordinates, top-left origin),
    /// or above it when there is no room; otherwise bottom-centre of the
    /// screen under the pointer.
    static func origin(for size: NSSize, anchor: CGRect?, screens: [NSScreen] = NSScreen.screens,
                       mouse: NSPoint = NSEvent.mouseLocation) -> NSPoint {
        let primaryHeight = screens.first?.frame.height ?? 0
        if let anchor, anchor.width > 0, anchor.height > 0 {
            let cocoa = NSRect(x: anchor.minX, y: primaryHeight - anchor.maxY, width: anchor.width, height: anchor.height)
            let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
            if let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first {
                let visible = screen.visibleFrame
                var x = cocoa.midX - size.width / 2
                var y = cocoa.minY - size.height - 12
                if y < visible.minY + 8 { y = cocoa.maxY + 12 }
                if y + size.height > visible.maxY - 8 { y = visible.minY + 80 }
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
                y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
                return NSPoint(x: x, y: y)
            }
        }
        let screen = screens.first { $0.frame.contains(mouse) } ?? screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80)
    }
}

struct TextCaptureHUDView: View {
    let model: TextCaptureHUDModel
    @ObservedObject var speech: TextCaptureSpeech
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSpeak: () -> Void
    let onOpen: (URL) -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 13, weight: .semibold))
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }

            Text(model.text)
                .font(.system(size: 12))
                .lineLimit(8)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .accessibilityLabel("Recognized text")

            if !model.links.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.links.prefix(3), id: \.self) { url in
                        Button { onOpen(url) } label: {
                            Label(url.host ?? url.absoluteString, systemImage: "link")
                                .font(.system(size: 11)).lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help(url.absoluteString)
                    }
                }
            }

            HStack(spacing: 6) {
                hudButton("Copy", "doc.on.doc", action: onCopy)
                hudButton("Edit", "square.and.pencil", action: onEdit)
                hudButton(speech.isSpeaking ? "Stop" : "Speak",
                          speech.isSpeaking ? "stop.fill" : "speaker.wave.2", action: onSpeak)
                ShareLink(item: model.text) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 11))
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 380)
        .onHover(perform: onHover)
    }

    private func hudButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .controlSize(.small)
        .accessibilityLabel(title)
    }
}

/// Edit the recognised text before copying (the HUD's "Edit").
@MainActor
final class TextCaptureEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = TextCaptureEditorWindowController()
    private var window: NSWindow?

    func open(text: String, languageCode: String?) {
        let model = TextCaptureEditorModel(text: text, languageCode: languageCode)
        let view = TextCaptureEditorView(model: model, speech: TextCaptureSpeech.shared,
                                         onCopy: { [weak self] value in
                                             let board = NSPasteboard.general
                                             board.clearContents()
                                             board.setString(value, forType: .string)
                                             GestureHUD.shared.show(title: "Copied", detail: "\(value.count) characters")
                                             self?.window?.close()
                                         },
                                         onCancel: { [weak self] in self?.window?.close() })
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                             backing: .buffered, defer: false)
        window.title = "Recognized Text"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 520, height: 360))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        TextCaptureSpeech.shared.stop()
    }
}

@MainActor
final class TextCaptureEditorModel: ObservableObject {
    @Published var text: String
    let languageCode: String?
    init(text: String, languageCode: String?) {
        self.text = text
        self.languageCode = languageCode
    }
}

struct TextCaptureEditorView: View {
    @ObservedObject var model: TextCaptureEditorModel
    @ObservedObject var speech: TextCaptureSpeech
    let onCopy: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .frame(minWidth: 360, minHeight: 200)
                .accessibilityLabel("Recognized text")
            HStack {
                Text("\(model.text.count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(speech.isSpeaking ? "Stop" : "Speak") {
                    speech.toggle(model.text, languageCode: model.languageCode)
                }
                ShareLink(item: model.text) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Copy") { onCopy(model.text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
