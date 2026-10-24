import AppKit
import SwiftUI
import WebKit

/// UI preferences live outside the encrypted archive; old Settings payloads
/// continue decoding without introducing required Codable keys.
@MainActor
final class ClipboardPreferences: ObservableObject {
    static let shared = ClipboardPreferences()
    private let defaults: UserDefaults
    enum Modifier: String, CaseIterable, Identifiable {
        case command, option, control, shift
        var id: String { rawValue }
        var symbol: String { switch self { case .command: return "⌘"; case .option: return "⌥"; case .control: return "⌃"; case .shift: return "⇧" } }
        var eventModifiers: EventModifiers { switch self { case .command: return .command; case .option: return .option; case .control: return .control; case .shift: return .shift } }
        var flags: NSEvent.ModifierFlags { switch self { case .command: return .command; case .option: return .option; case .control: return .control; case .shift: return .shift } }
    }
    @Published var quickModifier: Modifier { didSet { defaults.set(quickModifier.rawValue, forKey: "AOMClipboardQuickModifier"); if quickModifier == plainModifier { plainModifier = .shift } } }
    @Published var plainModifier: Modifier { didSet { defaults.set(plainModifier.rawValue, forKey: "AOMClipboardPlainModifier") } }
    @Published var networkPreviews: Bool { didSet { defaults.set(networkPreviews, forKey: "AOMClipboardNetworkPreviews") } }
    @Published var showInScreenCapture: Bool { didSet { defaults.set(showInScreenCapture, forKey: "AOMClipboardShowInScreenCapture"); NotificationCenter.default.post(name: Self.changed, object: nil) } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: "AOMClipboardCompact"); NotificationCenter.default.post(name: Self.changed, object: nil) } }
    static let changed = Notification.Name("AOMClipboardPresentationChanged")
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quickModifier = Modifier(rawValue: defaults.string(forKey: "AOMClipboardQuickModifier") ?? "command") ?? .command
        plainModifier = Modifier(rawValue: defaults.string(forKey: "AOMClipboardPlainModifier") ?? "shift") ?? .shift
        networkPreviews = defaults.bool(forKey: "AOMClipboardNetworkPreviews")
        showInScreenCapture = defaults.object(forKey: "AOMClipboardShowInScreenCapture") as? Bool ?? true
        compact = defaults.bool(forKey: "AOMClipboardCompact")
        if quickModifier == .shift { quickModifier = .command }
        if plainModifier == .command || plainModifier == quickModifier { plainModifier = .shift }
    }
    func isPlain(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(plainModifier.flags) }
    func isQuick(_ flags: NSEvent.ModifierFlags) -> Bool {
        let used = flags.intersection([.command, .option, .control, .shift])
        return used == quickModifier.flags || used == quickModifier.flags.union(plainModifier.flags)
    }
}

/// Every URL becomes its own native dragging item. A single NSItemProvider
/// cannot represent several public.file-url values without dropping files.
struct ClipboardNativeDragView: NSViewRepresentable {
    let entry: ClipboardEntry
    static func fileWriters(for entry: ClipboardEntry) -> [NSPasteboardItem] {
        entry.fileURLs.map { url in
            let writer = NSPasteboardItem()
            writer.setString(url.absoluteString, forType: .fileURL)
            writer.setString(entry.id.uuidString, forType: NSPasteboard.PasteboardType("com.kyw.allofmacos.clipboard-pinboard-entry"))
            return writer
        }
    }
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.entry = entry; return view }
    func updateNSView(_ view: DragView, context: Context) { view.entry = entry }
    final class DragView: NSView, NSDraggingSource {
        var entry: ClipboardEntry?
        private var monitor: Any?
        private var start: NSPoint?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window, let entry = self.entry, !entry.fileURLs.isEmpty else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseDown { self.start = self.bounds.contains(point) ? point : nil }
                if event.type == .leftMouseUp { self.start = nil }
                guard event.type == .leftMouseDragged, let start = self.start,
                      hypot(point.x - start.x, point.y - start.y) > 5 else { return event }
                self.start = nil
                let items = ClipboardNativeDragView.fileWriters(for: entry).enumerated().map { index, writer in
                    let url = entry.fileURLs[index]
                    let item = NSDraggingItem(pasteboardWriter: writer)
                    item.setDraggingFrame(NSRect(x: point.x + CGFloat(index % 4) * 4, y: point.y, width: 40, height: 40), contents: NSWorkspace.shared.icon(forFile: url.path))
                    return item
                }
                self.beginDraggingSession(with: items, event: event, source: self)
                return nil
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Explicit opt-in only. Ephemeral storage keeps history/cookies off disk;
/// scripts, popups and non-HTTP navigation are blocked.
struct ClipboardPrivateLinkPreview: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.requestedURL = url
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { if context.coordinator.requestedURL != url { context.coordinator.requestedURL = url; view.load(URLRequest(url: url)) } }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var requestedURL: URL?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
            decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
        }
    }
}

@MainActor
final class ClipboardColorEditor: NSObject {
    static let shared = ClipboardColorEditor()
    private var apply: ((String) -> Void)?
    func show(hex: String, apply: @escaping (String) -> Void) {
        self.apply = apply
        let panel = NSColorPanel.shared
        panel.sharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
        panel.showsAlpha = true
        if let color = Self.color(hex) { panel.color = color }
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func changed(_ sender: NSColorPanel) {
        if let value = Self.hexString(sender.color) { apply?(value) }
    }
    nonisolated static func hexString(_ input: NSColor) -> String? {
        guard let color = input.usingColorSpace(.sRGB) else { return nil }
        let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        return "#" + components.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }
    nonisolated static func color(_ hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if [3, 4].contains(value.count) { value = value.map { "\($0)\($0)" }.joined() }
        guard [6, 8].contains(value.count), let number = UInt64(value, radix: 16) else { return nil }
        let alpha = value.count == 8
        let rgb = alpha ? number >> 8 : number
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha ? CGFloat(number & 255) / 255 : 1)
    }
}

struct ClipboardCardDrag: ViewModifier {
    let entry: ClipboardEntry
    let provider: () -> NSItemProvider
    @ViewBuilder func body(content: Content) -> some View {
        if entry.fileURLs.isEmpty { content.onDrag(provider) }
        else { content.background(ClipboardNativeDragView(entry: entry)) }
    }
}

@MainActor
struct ClipboardDetachedPreview: View {
    let entry: ClipboardEntry
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var preferences = ClipboardPreferences.shared
    @State private var content: ClipboardPreviewCache.Content?
    // Paste-style rename: double-click the title to edit it in place.
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFocused: Bool
    private var current: ClipboardEntry { store.entries.first { $0.id == entry.id } ?? entry }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if isEditingTitle {
                    TextField("Title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder).font(.headline)
                        .focused($titleFocused)
                        .onSubmit { commitTitle() }
                        .onExitCommand { isEditingTitle = false }
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Title")
                } else {
                    Text(current.title.isEmpty ? current.kind.displayName : current.title)
                        .font(.headline).lineLimit(1)
                        .foregroundStyle(current.title.isEmpty ? .secondary : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editedTitle = current.title
                            isEditingTitle = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(30))
                                titleFocused = true
                            }
                        }
                        .help(current.title.isEmpty ? "Double-click to name this item" : "Double-click to rename")
                        .accessibilityLabel("Title, \(current.title.isEmpty ? current.kind.displayName : current.title). Double-click to rename.")
                }
                Spacer()
                Button("Copy") { _ = try? store.write(entryIDs: [current.id]) }
                Button("Edit") { ClipboardPanelController.shared.editEntry(current) }
            }
            if preferences.networkPreviews, current.kind == .link,
               let url = URL(string: (current.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                ClipboardPrivateLinkPreview(url: url)
            } else if !current.fileURLs.isEmpty {
                ClipboardFilesPreview(urls: current.fileURLs)
            } else if let image = content?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                ClipboardReadOnlyTextPreview(entry: current, prepared: content?.attributedText)
            }
        }.padding(16).frame(minWidth: 320, minHeight: 240)
            .task(id: current.contentVersion) { content = await ClipboardPreviewCache.shared.content(for: current) }
            .onChange(of: titleFocused) { _, focused in
                if !focused, isEditingTitle { commitTitle() }
            }
    }

    private func commitTitle() {
        isEditingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != current.title {
            store.rename(entryID: current.id, title: trimmed)
            ClipboardPanelController.shared.syncDetachedPreviewTitle(trimmed)
        }
    }
}

@MainActor
struct ClipboardSearchTokenChip: View {
    let token: String
    let update: (String) -> Void
    let remove: () -> Void
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 3) {
            Button(token) { draft = token; editing = true }
                .popover(isPresented: $editing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Edit Search Filter").font(.headline)
                        TextField("Filter", text: $draft).textFieldStyle(.roundedBorder)
                            .onSubmit { update(draft); editing = false }
                        HStack { Button("Cancel") { editing = false }; Spacer(); Button("Apply") { update(draft); editing = false }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }.padding(14).frame(width: 270)
                }
                .help("Edit filter")
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }.help("Remove filter")
        }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(Color.accentColor).background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}


// MARK: - Capture visibility

/// Paste keeps its own UI out of screen capture; AOM exposes one switch for that
/// and must honor it for every window the app presents, not only the clipboard.
extension NSWindow {
    /// Windows are always built on the main thread; the nonisolated entry point
    /// lets plain NSObject controllers share the same policy.
    nonisolated func applyCaptureVisibility(visible: Bool) {
        MainActor.assumeIsolated { sharingType = visible ? .readOnly : .none }
    }

    nonisolated func applyCaptureVisibilityPreference() {
        let visible = MainActor.assumeIsolated { ClipboardPreferences.shared.showInScreenCapture }
        applyCaptureVisibility(visible: visible)
    }
}
