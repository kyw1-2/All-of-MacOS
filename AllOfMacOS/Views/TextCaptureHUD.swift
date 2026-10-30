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

    /// Builds the panel and lays out a sample result once, off screen, so the
    /// first real result appears without SwiftUI's cold-start cost.
    func prewarm() {
        guard NSApp != nil, panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        let sample = TextCaptureHUDModel(title: "Text Copied", subtitle: "0 characters", text: "Sample", links: [],
                                         barcodes: [], languageCode: nil, symbol: "checkmark.circle.fill")
        let hosting = NSHostingView(rootView: TextCaptureHUDView(
            model: sample, speech: TextCaptureSpeech.shared, onCopy: {}, onEdit: {}, onSpeak: {},
            onOpen: { _ in }, onClose: {}, onHover: { _ in }))
        _ = hosting.fittingSize
        panel.contentView = hosting
        panel.contentView = nil
    }

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

        // The view draws the shared floating material itself (glass on
        // macOS 26+), like the Quick Access card and the recording bar.
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
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
        if board.setString(text, forType: .string) {
            GestureHUD.shared.show(title: "Copied", detail: "\(text.count) characters")
        } else {
            GestureHUD.shared.show(title: "Could Not Copy", detail: "The clipboard did not accept the text.")
        }
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
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x3 - AOMSpace.x0_5) {
                Image(systemName: model.symbol)
                    .font(AOMFont.pageStatus)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(AOMFont.bodyEmphasis).foregroundStyle(AOMColor.text)
                    Text(model.subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                }
                Spacer(minLength: AOMSpace.x1)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(AOMFont.section.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }

            Text(model.text)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.text)
                .lineLimit(8)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(AOMSpace.x2)
                .background(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous).fill(AOMColor.sunken))
                .accessibilityLabel("Recognized text")

            if !model.links.isEmpty {
                VStack(alignment: .leading, spacing: AOMSpace.x0_5 + 1) {
                    ForEach(model.links.prefix(3), id: \.self) { url in
                        Button { onOpen(url) } label: {
                            Label(url.host ?? url.absoluteString, systemImage: "link")
                                .font(AOMFont.caption).lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help(url.absoluteString)
                    }
                }
            }

            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                hudButton("Copy", "doc.on.doc", action: onCopy)
                hudButton("Edit", "square.and.pencil", action: onEdit)
                hudButton(speech.isSpeaking ? "Stop" : "Speak",
                          speech.isSpeaking ? "stop.fill" : "speaker.wave.2", action: onSpeak)
                ShareLink(item: model.text) {
                    Label("Share", systemImage: "square.and.arrow.up").font(AOMFont.caption)
                }
                .controlSize(.small)
                .aomGlassButton()
                Spacer()
            }
        }
        .padding(AOMSpace.x3)
        .frame(width: AOMFeatureSize.textHUDWidth)
        .aomFloatingSurface(.hud, radius: AOMRadius.hud)
        .onHover(perform: onHover)
    }

    /// Buttons on the HUD's glass use the glass style (c.4).
    private func hudButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(AOMFont.caption)
        }
        .controlSize(.small)
        .aomGlassButton()
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
                                             guard board.setString(value, forType: .string) else {
                                                 GestureHUD.shared.show(title: "Could Not Copy", detail: "The clipboard did not accept the text.")
                                                 return
                                             }
                                             GestureHUD.shared.show(title: "Copied", detail: "\(value.count) characters")
                                             self?.window?.close()
                                         },
                                         onCancel: { [weak self] in self?.window?.close() })
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                             backing: .buffered, defer: false)
        window.title = "Recognized Text"
        window.applyCaptureVisibilityPreference()
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
        VStack(spacing: AOMSpace.x3 - AOMSpace.x0_5) {
            TextEditor(text: $model.text)
                .font(AOMFont.body)
                .frame(minWidth: AOMFeatureSize.textEditorMin.width, minHeight: AOMFeatureSize.textEditorMin.height)
                .accessibilityLabel("Recognized text")
            HStack {
                Text("\(model.text.count) characters").font(AOMFont.caption).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                Spacer()
                Button(speech.isSpeaking ? "Stop" : "Speak") {
                    speech.toggle(model.text, languageCode: model.languageCode)
                }
                ShareLink(item: model.text) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Copy") { onCopy(model.text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(AOMSpace.x4)
    }
}
