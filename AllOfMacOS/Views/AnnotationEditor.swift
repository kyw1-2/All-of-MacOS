import AppKit
import SwiftUI
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Opens the annotate editor for a capture.
///
/// The editor is a separate window rather than a sheet so several captures can be
/// annotated side by side, which is what the pin-plus-annotate workflow ends up
/// doing in practice.
@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()
    private init() {}

    private var editors: [UUID: AnnotationEditorWindow] = [:]

    func open(capture: CaptureHistoryEntry, url: URL?, onApply: ((CGImage) -> Void)? = nil) {
        let id = UUID()
        let window = AnnotationEditorWindow(capture: capture, url: url, onApply: onApply)
        window.onClose = { [weak self] in self?.editors.removeValue(forKey: id) }
        editors[id] = window
        window.present()
    }

    func openProject(at url: URL) {
        do {
            let (document, scale) = try AnnotationProject.read(from: url)
            let entry = CaptureHistoryEntry(image: document.baseImage, kind: .area, capturedAt: Date(),
                                            windowTitle: url.deletingPathExtension().lastPathComponent,
                                            fileURL: nil, scale: scale)
            let id = UUID()
            let window = AnnotationEditorWindow(capture: entry, url: nil, document: document, projectURL: url)
            window.onClose = { [weak self] in self?.editors.removeValue(forKey: id) }
            editors[id] = window
            window.present()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Open Annotation Project"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AnnotationProject.contentType]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.openProject(at: url) }
        }
    }

    /// Opens the most recent capture, for "Annotate Last Screenshot".
    func openMostRecent() {
        guard let entry = CaptureHistory.shared.mostRecent else {
            GestureHUD.shared.show(title: "Nothing to Annotate", detail: "Take a capture first.")
            return
        }
        open(capture: entry, url: entry.fileURL)
    }

    /// CleanShot "Open…": an image (or an AOM annotation project) from disk.
    func chooseImageOrProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP, .gif, .bmp, AnnotationProject.contentType]
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                for url in panel.urls { self?.openFile(at: url) }
            }
        }
    }

    /// Opens an image file for annotation; the source file is never overwritten.
    func openFile(at url: URL) {
        if url.pathExtension.lowercased() == AnnotationProject.contentType.preferredFilenameExtension {
            openProject(at: url)
            return
        }
        guard let entry = Self.entry(fromImageAt: url) else {
            GestureHUD.shared.show(title: "Could Not Open", detail: url.lastPathComponent)
            return
        }
        open(capture: entry, url: nil)
    }

    /// CleanShot "Open from Clipboard".
    func openFromClipboard() {
        guard let entry = Self.entryFromPasteboard(.general) else {
            GestureHUD.shared.show(title: "No Image on Clipboard", detail: "Copy an image or image file first.")
            return
        }
        open(capture: entry, url: nil)
    }

    static func entry(fromImageAt url: URL) -> CaptureHistoryEntry? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Honour the file's DPI so a Retina PNG opens at its on-screen size.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = max(1, min(4, (dpi / 72).rounded()))
        return CaptureHistoryEntry(image: image, kind: .area, capturedAt: Date(),
                                   windowTitle: url.deletingPathExtension().lastPathComponent,
                                   fileURL: nil, scale: CGFloat(scale))
    }

    static func entryFromPasteboard(_ pasteboard: NSPasteboard) -> CaptureHistoryEntry? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let entry = entry(fromImageAt: url) {
            return entry
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = image.size.width > 0 ? max(1, (CGFloat(cgImage.width) / image.size.width).rounded()) : 1
        return CaptureHistoryEntry(image: cgImage, kind: .area, capturedAt: Date(),
                                   windowTitle: "Clipboard Image", fileURL: nil, scale: scale)
    }
}

/// Bridges the SwiftUI editor's unsaved state to the window's close handling.
@MainActor
final class AnnotationEditorSession {
    var isDirty: () -> Bool = { false }
    /// Saves (or applies, for clipboard edits); returns false on failure.
    var commit: () -> Bool = { true }
    var close: () -> Void = {}
}

/// "Do you want to save the changes you made to the screenshot?"
enum AnnotationClosePrompt {
    enum Choice: Equatable { case save, dontSave, cancel }

    static let message = "Do you want to save the changes you made to the screenshot?"
    static let buttons = ["Save", "Don't Save", "Cancel"]

    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }
}

private final class AnnotationEditorWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let capture: CaptureHistoryEntry
    private let session = AnnotationEditorSession()
    private var closeConfirmed = false

    init(capture: CaptureHistoryEntry, url: URL?, document: AnnotationDocument? = nil, projectURL: URL? = nil, onApply: ((CGImage) -> Void)? = nil) {
        self.capture = capture
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(screen.width - 40, min(1280, max(1000, capture.pointSize.width + 48)))
        let height = min(screen.height - 60, min(900, max(640, capture.pointSize.height + 100)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Annotate — \(capture.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 480)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AnnotationEditorView(capture: capture, fileURL: url, document: document, projectURL: projectURL, onApply: onApply, session: session))
        window.delegate = self
        session.close = { [weak self] in
            self?.closeConfirmed = true
            self?.window?.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed, session.isDirty() else { return true }
        let alert = NSAlert()
        alert.messageText = AnnotationClosePrompt.message
        alert.informativeText = "Your changes will be lost if you don't save them."
        for title in AnnotationClosePrompt.buttons { alert.addButton(withTitle: title) }
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch AnnotationClosePrompt.choice(for: response) {
                case .save:
                    if self.session.commit() { self.session.close() }
                case .dontSave:
                    self.session.close()
                case .cancel:
                    break
                }
            }
        }
        return false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// An uninterrupted canvas with compact tool capsules and contextual popovers.
private struct AnnotationEditorView: View {
    let capture: CaptureHistoryEntry
    let fileURL: URL?
    let onApply: ((CGImage) -> Void)?
    @State private var projectURL: URL?
    @State private var presets = AnnotationStylePreset.load()

    @State private var document: AnnotationDocument
    private let session: AnnotationEditorSession?
    /// Snapshot at open / last save, for the unsaved-changes prompt.
    @State private var savedState: AnnotationSavedState
    @State private var redactKind: AnnotationKind = .pixelate
    @FocusState private var textFieldFocused: Bool
    @State private var tool: AnnotationKind = .arrow
    @State private var style = AnnotationStyle()
    @State private var selectedID: UUID?
    @State private var counterValue = 1
    @State private var cropMode = false
    @State private var showingResize = false
    @State private var showingSmartHighlight = false
    @State private var smartHighlightQuery = ""
    @State private var smartHighlightBusy = false
    @State private var cropRect: CGRect?
    @State private var status: String?

    @State private var colorPopover = false
    @State private var optionsPopover = false
    /// Background Tool sidebar; "Remember Background tool open state".
    @AppStorage(AnnotationBackgroundPresetStore.panelOpenKey) private var backgroundPanelOpen = false
    /// Objects selected in addition to `selectedID` (⇧-click, ⌘A).
    @State private var extraSelection: Set<UUID> = []
    /// Drop zone under an image being dragged onto the canvas.
    @State private var dropPlacement: AnnotationCombinePlacement?
    /// An image chosen with "Add Screenshot From File…" awaiting a side.
    @State private var placementRequest: AnnotationPlacementRequest?
    /// Successive pastes of the same clipboard step further away.
    @State private var pasteChangeCount = -1
    @State private var pasteRepeat = 0
    @State private var layersPopover = false
    @State private var canvasLocked = false
    @State private var zoom: CGFloat? = nil
    @State private var moveOriginals: [AnnotationObject] = []
    @State private var moveHasChanged = false
    @State private var resizeOriginal: AnnotationObject?
    @State private var cropHandleOriginal: CGRect?
    @State private var cropAspect: CGFloat = 0
    @State private var snapToEdges = true

    /// The draft object currently being dragged out.
    @State private var draft: AnnotationObject?
    @State private var dragStart: CGPoint?
    /// Which handle of a selected object is being dragged, if any.
    @State private var activeHandle: ResizeHandle?

    init(capture: CaptureHistoryEntry, fileURL: URL?, document: AnnotationDocument? = nil, projectURL: URL? = nil, onApply: ((CGImage) -> Void)? = nil,
         session: AnnotationEditorSession? = nil) {
        self.capture = capture
        self.fileURL = fileURL
        self.onApply = onApply
        self.session = session
        _projectURL = State(initialValue: projectURL)
        let initial = document ?? AnnotationDocument(baseImage: capture.image)
        // The saved-state baseline is taken *before* an automatic preset, so a
        // preset-only edit still counts as a change worth saving.
        _savedState = State(initialValue: AnnotationSavedState(initial))
        var opened = initial
        if document == nil, onApply == nil, let automatic = AnnotationBackgroundPresetStore.automaticBackground() {
            opened.background = automatic
        }
        _document = State(initialValue: opened)
    }

    private var isDirty: Bool { AnnotationSavedState(document) != savedState }

    private func markSaved() { savedState = AnnotationSavedState(document) }

    private var scale: CGFloat {
        guard capture.pointSize.width > 0, capture.image.width > 0 else {
            return capture.scale > 0 ? capture.scale : 2.0
        }
        let s = CGFloat(capture.image.width) / capture.pointSize.width
        return (s.isFinite && s > 0) ? s : 2.0
    }

    var body: some View {
        VStack(spacing: 0) {
            if cropMode { cropToolbar } else { toolbar }
            Divider()
            if !cropMode {
                propertiesBar
                Divider()
            }
            HStack(spacing: 0) {
                if backgroundPanelOpen && !cropMode {
                    AnnotationBackgroundPanel(background: $document.background,
                                              beginChange: { document.beginChange() },
                                              screenshotThumbnail: backgroundThumbnail,
                                              onClose: { backgroundPanelOpen = false })
                        .transition(.move(edge: .leading))
                    Divider()
                }
                canvas
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selectedID) { _, new in
            if let new { extraSelection.remove(new) } else { extraSelection.removeAll() }
        }
        .sheet(item: $placementRequest) { request in
            AnnotationPlacementChooser(thumbnail: request.image) { placement in
                placementRequest = nil
                if let placement { combine(request.image, imageScale: request.scale, placement: placement) }
            }
        }
        .background(CaptureKeyEventHandler(handle: handleEditorKey))
        .onAppear {
            session?.isDirty = { isDirty }
            session?.commit = { commitChanges() }
        }
        // "Apply Previous Settings" offers the last background used in an editor.
        .onDisappear { AnnotationBackgroundPresetStore.rememberPrevious(document.background) }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showingResize) {
            AnnotationResizeDialog(pixelWidth: document.croppedImage.width,
                                   pixelHeight: document.croppedImage.height) { width, height, flatten in
                if document.resize(toPixelWidth: width, height: height,
                                   scale: scale, flattenAnnotations: flatten) {
                    selectedID = nil
                    cropMode = false
                    cropRect = nil
                    tool = .move
                    zoom = nil
                    showingResize = false
                    status = "Resized to \(width) × \(height) px."
                } else {
                    status = "Resize failed. Check dimensions and memory."
                }
            }
        }
        .sheet(isPresented: $showingSmartHighlight) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Highlight Matching Text").font(.headline)
                Text("Finds text in this screenshot locally with Apple's Vision OCR and adds editable highlights.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Words to highlight", text: $smartHighlightQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Text to highlight")
                HStack {
                    Spacer()
                    Button("Cancel") { showingSmartHighlight = false }
                        .disabled(smartHighlightBusy)
                    Button("Highlight") { highlightMatchingText() }
                        .buttonStyle(.borderedProminent)
                        .disabled(smartHighlightBusy ||
                            smartHighlightQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if smartHighlightBusy { ProgressView("Recognizing text…").controlSize(.small) }
            }
            .padding(20)
            .frame(width: 430)
        }
    }

    // MARK: - Toolbar

    /// CleanShot layout: crop / background / add image on the left, the
    /// segmented tool group in the middle, output actions on the right
    /// (Drag, Pin, Copy ⇧⌘C, Save ⌘S ▾ Save As ⇧⌘S, Done).
    private var toolbar: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 32)
            capsuleButton(AnnotationToolbarItem.crop.symbol, help: AnnotationToolbarItem.crop.help,
                          active: cropMode) { selectToolbarItem(.crop) }
            capsuleButton(AnnotationToolbarItem.background.symbol, help: AnnotationToolbarItem.background.help,
                          active: backgroundPanelOpen) { selectToolbarItem(.background) }
            capsuleButton("photo.badge.plus", help: "Add Screenshot From File… (⌘I)") { addScreenshot() }
                .keyboardShortcut("i", modifiers: .command)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(AnnotationToolbarItem.segments) { item in
                        if item == .marker {
                            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 18)
                                .padding(.horizontal, 3)
                        }
                        toolButton(item)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.065), in: Capsule())
                .padding(.vertical, 2)
                .background(NativeScrollChrome(.hidden))
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            moreMenu
            outputActions
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(.regularMaterial)
    }

    private var outputActions: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .contentShape(Capsule())
                .onDrag { dragProvider() }
                .help("Drag the edited image to another app")
                .accessibilityLabel("Drag image to another app")
            capsuleButton("pin.fill", help: "Pin to the Screen") { pin() }
            capsuleButton("doc.on.doc", help: "Copy to Clipboard (⇧⌘C)") { copyToClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            HStack(spacing: 0) {
                Button { saveToExportLocation() } label: {
                    Text("Save").font(.system(size: 13, weight: .medium))
                        .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save to the export location (⌘S)")
                Menu {
                    Button("Save") { saveToExportLocation() }
                    Button("Save As…") { saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Menu("Export As") {
                        ForEach(CaptureFormat.allCases) { format in
                            Button(format.displayName) { saveAs(format: format) }
                        }
                    }
                    Divider()
                    Button("Print…") { printImage() }.keyboardShortcut("p", modifiers: .command)
                    Divider()
                    Button("Save Project") { saveProject(saveAs: false) }.keyboardShortcut("s", modifiers: [.command, .option])
                    Button("Save Project As…") { saveProject(saveAs: true) }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 8).frame(height: 32)
                .help("Save options")
                .accessibilityLabel("Save options")
            }
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            if let onApply {
                Button("Apply to Clipboard") {
                    if let image = renderedImage() { onApply(image); markSaved(); status = "Updated clipboard image." }
                }.buttonStyle(.bordered).controlSize(.large).fixedSize()
            }
            Button { done() } label: {
                Text("Done").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).padding(.horizontal, 15).frame(height: 32)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain).fixedSize()
            .help(onApply != nil ? "Apply to the clipboard and close" : "Save changes and close")
            .accessibilityLabel("Done")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Undo") { document.undo(); restoreSelectionAfterHistoryChange() }.disabled(!document.canUndo).keyboardShortcut("z", modifiers: .command)
            Button("Redo") { document.redo(); restoreSelectionAfterHistoryChange() }.disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { AnnotationEditorController.shared.chooseImageOrProject() }.keyboardShortcut("o", modifiers: .command)
            Menu("Style Presets") {
                Button("Save Current Style…") { saveStylePreset() }
                ForEach(presets) { preset in
                    Button(preset.name) { style = preset.style; applyStyleToSelection() }
                }
                if !presets.isEmpty {
                    Menu("Remove Preset") {
                        ForEach(presets) { preset in
                            Button(preset.name) { presets.removeAll { $0.id == preset.id }; AnnotationStylePreset.save(presets) }
                        }
                    }
                }
            }
            Divider()
            Button("Resize Image…") { showingResize = true }
            Menu("Rotate / Flip") {
                Button("Rotate 90° Clockwise") { transformImage(.rotateClockwise) }
                Button("Rotate 90° Counterclockwise") { transformImage(.rotateCounterclockwise) }
                Divider()
                Button("Flip Horizontally") { transformImage(.flipHorizontal) }
                Button("Flip Vertically") { transformImage(.flipVertical) }
            }
            Button("Smart Highlight Text…") { showingSmartHighlight = true }
            Divider()
            Button("Layers…") { layersPopover = true }
            // ⌘C / ⌘V / ⌘D / ⌘A are handled by the editor key monitor rather than
            // menu key equivalents, so they never steal copy/paste from a text field.
            Button("Copy Object (⌘C)") { copyObjects() }.disabled(selectedID == nil)
            Button("Paste Object (⌘V)") { pasteObjects() }
            Button("Duplicate Object (⌘D)") { duplicateObjects() }.disabled(selectedID == nil)
            Button("Select All Objects (⌘A)") { selectAllObjects() }.disabled(document.objects.isEmpty)
            Button("Delete Selected") { deleteSelection() }.disabled(selectedID == nil).keyboardShortcut(.delete, modifiers: [])
            Button("Flatten Redactions into Image") { flattenRedactions() }
                .disabled(!document.objects.contains { $0.kind.isRedaction })
                .help("Burns redactions into the pixels so even a saved project no longer contains the original")
            Divider()
            Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
            Button("Actual Size") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
        } label: { Image(systemName: "ellipsis").frame(width: 26, height: 30) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More Options").accessibilityLabel("More Options")
        .popover(isPresented: $layersPopover) { layers.padding(16).frame(width: 280) }
    }

    // MARK: - Properties bar

    /// Contextual properties for the active tool (or the selected object).
    private var propertiesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                palette
                propertyDivider
                toolProperties
                propertyDivider
                propertySlider("Opacity", value: Binding(get: { CGFloat(style.opacity) }, set: { style.opacity = Double($0) }),
                               range: 0.1...1, width: 70, label: "\(Int(style.opacity * 100))%")
                Button { optionsPopover.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 24)
                }
                .buttonStyle(.plain).help("More Tool Options").accessibilityLabel("More Tool Options")
                .popover(isPresented: $optionsPopover) { toolOptions.padding(18).frame(width: 270) }
                if inspectedKind == .draw || inspectedKind == .drawHighlight {
                    Toggle(isOn: $canvasLocked) {
                        Image(systemName: canvasLocked ? "lock.fill" : "lock.open")
                    }
                    .toggleStyle(.button).help("Lock Canvas").accessibilityLabel("Lock Canvas")
                }
            }
            .font(.system(size: 13))
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(NativeScrollChrome(.hidden))
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var propertyDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18)
    }

    private var palette: some View {
        HStack(spacing: 5) {
            ForEach(AnnotationColor.palette) { color in
                Button {
                    style.color = color
                    style.customColorHex = nil
                    applyStyleToSelection()
                } label: {
                    Circle().fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.accentColor,
                                                       lineWidth: style.customColorHex == nil && style.color == color ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(style.customColorHex == nil && style.color == color ? .isSelected : [])
            }
            Button { colorPopover.toggle() } label: {
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center))
                        .frame(width: 18, height: 18)
                    Circle().fill(Color(nsColor: style.resolvedColor)).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                }
                .padding(1)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: style.customColorHex != nil ? 2 : 0))
            }
            .buttonStyle(.plain)
            .help("More colors, My Colors, hex/RGB and eyedropper")
            .accessibilityLabel("Color picker")
            .popover(isPresented: $colorPopover, arrowEdge: .bottom) {
                AnnotationColorPickerView(color: style.resolvedColor, opacity: style.opacity,
                                          apply: { color, alpha in
                                              style.customColorHex = String(AnnotationColorLibrary.hex(of: color).prefix(6))
                                              style.opacity = max(0.05, alpha)
                                              applyStyleToSelection()
                                          },
                                          applyPalette: { named in
                                              style.color = named
                                              style.customColorHex = nil
                                              applyStyleToSelection()
                                          })
            }
        }
    }

    @ViewBuilder private var toolProperties: some View {
        let kind = inspectedKind
        switch kind {
        case .rectangle, .ellipse, .line, .arrow, .draw, .drawHighlight, .highlighter, .spotlight:
            if kind != .spotlight && kind != .highlighter {
                propertySlider("Thickness", value: $style.thickness, range: 1...20, width: 90,
                               label: "\(Int(style.thickness)) pt")
            }
            if kind == .arrow {
                Picker("Arrow style", selection: $style.arrowStyle) {
                    ForEach(ArrowStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 110)
                .help("Arrow style")
                .onChange(of: style.arrowStyle) { _, _ in applyStyleToSelection() }
            }
            if kind == .rectangle {
                propertySlider("Corners", value: $style.cornerRadius, range: 0...40, width: 70,
                               label: "\(Int(style.cornerRadius)) pt")
            }
            if kind == .spotlight || kind == .highlighter {
                Text(kind == .spotlight ? "Dims everything outside the shape" : "Rectangular marker")
                    .foregroundStyle(.secondary)
            }
        case .filledRectangle:
            propertySlider("Corners", value: $style.cornerRadius, range: 0...40, width: 70,
                           label: "\(Int(style.cornerRadius)) pt")
        case .text:
            propertySlider("Font size", value: $style.fontSize, range: 10...96, width: 90,
                           label: "\(Int(style.fontSize)) pt")
            Toggle("B", isOn: Binding(get: { style.bold ?? true }, set: { style.bold = $0; applyStyleToSelection() }))
                .toggleStyle(.button).bold().help("Bold").accessibilityLabel("Bold")
            Toggle("I", isOn: Binding(get: { style.italic ?? false }, set: { style.italic = $0; applyStyleToSelection() }))
                .toggleStyle(.button).italic().help("Italic").accessibilityLabel("Italic")
            Toggle("Outline", isOn: Binding(get: { style.textOutline ?? true }, set: { style.textOutline = $0; applyStyleToSelection() }))
                .toggleStyle(.button).help("Outlined text style")
            if let id = selectedID, let object = document.objects.first(where: { $0.id == id }), object.kind == .text {
                TextField("Text", text: Binding(
                    get: { object.text },
                    set: { newValue in
                        document.beginChange()
                        var updated = object; updated.text = newValue; document.update(updated)
                    }))
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
                .frame(width: 200)
                .accessibilityLabel("Text content")
            }
        case .counter:
            Text("Next number").foregroundStyle(.secondary)
            Stepper(value: $counterValue, in: 1...9999) {
                Text("\(counterValue)").monospacedDigit().frame(minWidth: 28)
            }
            .help("Starting number")
            Button("Reset") { counterValue = 1 }.help("Restart numbering at 1")
        case .pixelate, .blur, .redact:
            Picker("Redaction style", selection: Binding(
                get: { AnnotationRedactionStyle(kind: kind) ?? .pixelate },
                set: { selectRedaction($0) })) {
                ForEach(AnnotationRedactionStyle.allCases) { redaction in
                    Label(redaction.title, systemImage: redaction.symbol).labelStyle(.titleAndIcon)
                        .help(redaction.help).tag(redaction)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 390)
            .help((AnnotationRedactionStyle(kind: kind) ?? .pixelate).help)
            .accessibilityLabel("Redaction style")
            if kind.isSecureRedaction {
                Image(systemName: "checkmark.shield").foregroundStyle(.green)
                    .help("Exported pixels in this area are fully replaced")
                    .accessibilityLabel("Irreversible redaction")
            }
            if kind == .secureBlur {
                Picker("Block size", selection: $style.pixelBlockSize) {
                    ForEach([16, 24, 32, 48], id: \.self) { Text("\($0) px").tag(CGFloat($0)) }
                }
                .labelsHidden().frame(width: 80).help("Secure blur block size (larger hides more)")
                .onChange(of: style.pixelBlockSize) { _, _ in applyStyleToSelection() }
            }
            if kind == .pixelate {
                Picker("Pixel size", selection: $style.pixelBlockSize) {
                    ForEach([8, 16, 32], id: \.self) { Text("\($0) px").tag(CGFloat($0)) }
                }
                .labelsHidden().frame(width: 80).help("Pixel block size")
                .onChange(of: style.pixelBlockSize) { _, _ in applyStyleToSelection() }
            } else if kind == .blur {
                propertySlider("Intensity", value: $style.blurRadius, range: 1...64, width: 80,
                               label: "\(Int(style.blurRadius)) px")
            }
        case .move:
            Text(selectedID == nil ? "Select an object to edit it · Arrow keys nudge (⇧ 10 px)"
                                   : "Arrow keys nudge (⇧ 10 px) · ⌫ deletes")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func propertySlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                                width: CGFloat, label: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = CGFloat($0); applyStyleToSelection() }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: width)
                .accessibilityLabel(title)
                .accessibilityValue(label)
            Text(label).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 36, alignment: .leading)
        }
    }

    private func selectRedaction(_ redaction: AnnotationRedactionStyle) {
        redactKind = redaction.kind
        if let id = selectedID, var object = document.objects.first(where: { $0.id == id }),
           AnnotationRedactionStyle(kind: object.kind) != nil {
            document.beginChange()
            object.kind = redaction.kind
            document.update(object)
        } else {
            selectTool(redaction.kind)
        }
    }

    private func selectToolbarItem(_ item: AnnotationToolbarItem) {
        switch item {
        case .background:
            withAnimation(.easeOut(duration: 0.18)) { backgroundPanelOpen.toggle() }
        case .crop:
            selectTool(cropMode ? .move : .crop)
        case .redact:
            selectTool(redactKind)
        default:
            if let kind = item.kinds.first { selectTool(kind) }
        }
    }

    private func capsuleButton(_ symbol: String, help: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 38, height: 32)
                .background(active ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func highlightMatchingText() {
        let requested = smartHighlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, !smartHighlightBusy else { return }
        let source = document.croppedImage
        let backing = scale
        smartHighlightBusy = true
        Task {
            do {
                // Same multilingual engine as Capture Text (per-script Vision
                // passes fused with Live Text), so Korean/CJK labels match too.
                let pixelSize = CGSize(width: source.width, height: source.height)
                let boxes = try await TextRecognitionService.boxes(matching: requested, in: source)
                    .map { AnnotationSmartTextMatcher.annotationRect(from: $0, pixelSize: pixelSize, scale: backing) }
                    .filter { $0.width > 0 && $0.height > 0 }
                if boxes.isEmpty {
                    status = "No matching text found."
                } else {
                    let additions = boxes.map { rect in
                        var markerStyle = AnnotationStyle()
                        markerStyle.color = .yellow
                        markerStyle.opacity = 0.75
                        return AnnotationObject(kind: .highlighter, rect: rect, style: markerStyle)
                    }
                    document.addObjects(additions)
                    selectedID = nil
                    cropMode = false
                    tool = .move
                    status = "Highlighted \(boxes.count) matching text line(s). Undo removes all."
                    showingSmartHighlight = false
                }
            } catch {
                status = "Text recognition failed: \(error.localizedDescription)"
            }
            smartHighlightBusy = false
        }
    }

    private func transformImage(_ operation: AnnotationDocument.ImageTransform) {
        guard document.transformImage(operation, scale: scale) else {
            status = "Could not transform the screenshot."
            return
        }
        // Undo retains the source image and its editable layers.
        selectedID = nil
        draft = nil
        cropMode = false
        cropRect = nil
        tool = .move
        zoom = nil
        status = "Image transformed. Undo to restore original editable annotations."
    }

    private func selectTool(_ kind: AnnotationKind) {
        tool = kind
        cropMode = kind == .crop
        cropRect = kind == .crop ? CGRect(x: 0, y: 0,
            width: CGFloat(document.croppedImage.width) / scale,
            height: CGFloat(document.croppedImage.height) / scale) : nil
        draft = nil
        if kind != .move { selectedID = nil }
    }

    private func toolButton(_ item: AnnotationToolbarItem) -> some View {
        let active = item.kinds.contains(tool) && !cropMode
        return Button { selectToolbarItem(item) } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 33, height: 29)
                .background(active ? Color.accentColor : Color.clear, in: Capsule())
                .foregroundStyle(active ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Fit to Window") { zoom = nil }
                ForEach([25, 50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percent in
                    Button("\(percent)%") { zoom = CGFloat(percent) / 100 }
                }
            } label: {
                Text(zoom.map { "\(Int($0 * 100))%" } ?? "Fit")
                    .font(.system(size: 12, weight: .medium)).frame(width: 60, height: 30)
            }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .help("Zoom").accessibilityLabel("Zoom")
            if cropMode {
                Toggle("Snap to edges", isOn: $snapToEdges).toggleStyle(.checkbox).font(.system(size: 12))
                Text("Hold Command ⌘ to disable snapping.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(document.croppedImage.width) × \(document.croppedImage.height) px")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if !cropMode {
                AnnotationShareButton(image: renderedImage(), scale: scale).frame(width: 38, height: 32)
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(.regularMaterial)
    }

    private var cropToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
            Color.clear.frame(width: 68, height: 32)
            capsuleButton("crop", help: "Crop", active: true) { }
            Picker("Aspect Ratio", selection: $cropAspect) {
                Text("Freeform").tag(CGFloat(0))
                Text("Square").tag(CGFloat(1))
                Text("16:9").tag(CGFloat(16.0 / 9.0))
                Text("4:3").tag(CGFloat(4.0 / 3.0))
            }.labelsHidden().frame(width: 135)
                .onChange(of: cropAspect) { _, ratio in
                    guard ratio > 0, var rect = cropRect else { return }
                    rect.size.height = rect.width / ratio
                    cropRect = boundedCrop(rect)
                }
            cropDimension("Width", width: true)
            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
            cropDimension("Height", width: false)
            Divider().frame(height: 24)
            Text("Image size:").foregroundStyle(.secondary)
            Text("\(document.croppedImage.width) × \(document.croppedImage.height) px")
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            Spacer()
            Button("Cancel") { selectTool(.move) }.buttonStyle(.plain)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .keyboardShortcut(.escape, modifiers: [])
            Button { if let cropRect { applyCrop(cropRect) } } label: {
                Text("Crop").foregroundStyle(.white).fontWeight(.semibold)
                    .padding(.horizontal, 16).frame(height: 32).background(Color.accentColor, in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: [])
                .disabled(cropRect == nil || (cropRect?.width ?? 0) < 1 || (cropRect?.height ?? 0) < 1)
        }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 50)
            .background(NativeScrollChrome(.hidden))
        }
        .scrollIndicators(.hidden)
        .background(.regularMaterial)
    }

    private func cropDimension(_ label: String, width: Bool) -> some View {
        TextField(label, value: Binding<Double>(
            get: { Double((width ? cropRect?.width : cropRect?.height) ?? 0) * Double(scale) },
            set: { value in
                guard value.isFinite, var rect = cropRect else { return }
                if width { rect.size.width = CGFloat(value) / scale }
                else { rect.size.height = CGFloat(value) / scale }
                if cropAspect > 0 {
                    if width { rect.size.height = rect.width / cropAspect }
                    else { rect.size.width = rect.height * cropAspect }
                }
                cropRect = boundedCrop(rect)
            }), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel(label)
    }

    private func boundedCrop(_ rect: CGRect) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(document.croppedImage.width) / scale,
                            height: CGFloat(document.croppedImage.height) / scale)
        let clipped = rect.standardized.intersection(bounds)
        return clipped.isNull ? bounds : clipped
    }

    // MARK: - Canvas

    private var privacyDraft: AnnotationObject? {
        guard let draft, draft.kind == .blur || draft.kind == .pixelate else { return nil }
        return draft
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: CGFloat(document.croppedImage.width) / scale,
                                   height: CGFloat(document.croppedImage.height) / scale)
            let canvasSize = document.canvasSize(scale: scale)
            let fit = zoom ?? fitScale(for: canvasSize, in: geometry.size)
            let drawn = canvasSize.scaled(by: fit)
            let origin = document.imageOrigin(scale: scale).scaled(by: fit)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let rendered = document.render(scale: scale, draft: privacyDraft) {
                        Image(decorative: rendered, scale: scale).resizable()
                            .frame(width: drawn.width, height: drawn.height)
                    }
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(document.objects) { object in
                            if object.id == selectedID, tool == .move {
                                selectionHandles(for: object, fit: fit)
                            } else if extraSelection.contains(object.id), tool == .move {
                                Rectangle().path(in: object.rect.scaled(by: fit))
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .allowsHitTesting(false)
                            }
                        }
                        if let draft, draft.kind != .blur && draft.kind != .pixelate { DraftOverlay(object: draft, fit: fit, scale: scale) }
                        if cropMode, let cropRect { cropOverlay(cropRect: cropRect, fit: fit, imageSize: imageSize) }
                    }
                    .frame(width: imageSize.width * fit, height: imageSize.height * fit)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: "annotationCanvas")
                    .gesture(canvasGesture(fit: fit, imageSize: imageSize))
                    .allowsHitTesting(!canvasLocked)
                    .offset(x: origin.x, y: origin.y)
                    if let dropPlacement { AnnotationDropZoneOverlay(active: dropPlacement) }
                }
                .frame(width: drawn.width, height: drawn.height)
                .onDrop(of: AnnotationCanvasDropDelegate.acceptedTypes,
                        delegate: AnnotationCanvasDropDelegate(canvasSize: drawn, placement: $dropPlacement,
                                                               onDrop: { image, imageScale, placement in
                                                                   combine(image, imageScale: imageScale,
                                                                           placement: placement)
                                                               }))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 3)
                .padding(24)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                .background(NativeScrollChrome(.overlay))
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .bottom) {
                if let status {
                    Text(status).font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(for imageSize: CGSize, in available: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(0.01, min((available.width - 48) / imageSize.width, (available.height - 48) / imageSize.height))
    }

    private func selectionHandles(for object: AnnotationObject, fit: CGFloat) -> some View {
        let rect = object.rect.scaled(by: fit)
        return ZStack {
            Rectangle()
                .path(in: rect)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(handle.position(in: rect))
                    .highPriorityGesture(handleGesture(handle, object: object, fit: fit))
            }
        }
        .allowsHitTesting(true)
    }

    private func cropOverlay(cropRect: CGRect, fit: CGFloat, imageSize: CGSize) -> some View {
        let rect = cropRect.scaled(by: fit)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: imageSize.scaled(by: fit)))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().path(in: rect).stroke(Color.white, lineWidth: 1).allowsHitTesting(false)
            Path { path in
                for division in 1...2 {
                    let fraction = CGFloat(division) / 3
                    path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                }
            }.stroke(Color.white.opacity(0.65), lineWidth: 1).allowsHitTesting(false)
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .frame(width: 12, height: 7).position(handle.position(in: rect))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("annotationCanvas"))
                        .onChanged { value in
                            if cropHandleOriginal == nil { cropHandleOriginal = cropRect }
                            guard let original = cropHandleOriginal else { return }
                            self.cropRect = boundedCrop(handle.resize(original, to: value.location.scaled(by: 1 / fit)))
                        }
                        .onEnded { _ in cropHandleOriginal = nil })
            }
        }
    }

    // MARK: - Gestures

    private func canvasGesture(fit: CGFloat, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.startLocation.scaled(by: 1 / fit)
                let current = value.location.scaled(by: 1 / fit)

                if cropMode {
                    guard cropHandleOriginal == nil else { return }
                    var rect = CGRect(x: min(point.x, current.x), y: min(point.y, current.y),
                                      width: abs(current.x - point.x), height: abs(current.y - point.y))
                    if cropAspect > 0 { rect.size.height = rect.width / cropAspect }
                    if snapToEdges && !NSEvent.modifierFlags.contains(.command) {
                        let tolerance = 8 / fit
                        if rect.minX < tolerance { rect.size.width += rect.minX; rect.origin.x = 0 }
                        if rect.minY < tolerance { rect.size.height += rect.minY; rect.origin.y = 0 }
                        if abs(rect.maxX - imageSize.width) < tolerance { rect.size.width = imageSize.width - rect.minX }
                        if abs(rect.maxY - imageSize.height) < tolerance { rect.size.height = imageSize.height - rect.minY }
                    }
                    cropRect = boundedCrop(rect)
                    return
                }

                if tool == .move {
                    // Clicking picks the topmost object under the pointer;
                    // ⇧-click adds/removes it from a multi-selection.
                    if dragStart == nil {
                        dragStart = point
                        moveHasChanged = false
                        let hit = document.objects.last { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }
                        if NSEvent.modifierFlags.contains(.shift), let hit {
                            toggleSelection(hit.id)
                            moveOriginals = []
                        } else {
                            if let hit, selectedIDs.contains(hit.id) {
                                makePrimary(hit.id)
                            } else {
                                extraSelection.removeAll()
                                selectedID = hit?.id
                            }
                            moveOriginals = hit == nil ? [] : document.objects.filter { selectedIDs.contains($0.id) }
                        }
                        if let hit { style = hit.style }
                    }
                    if !moveOriginals.isEmpty {
                        let dx = current.x - point.x, dy = current.y - point.y
                        guard dx != 0 || dy != 0 || moveHasChanged else { return }
                        if !moveHasChanged {
                            document.beginChange()
                            moveHasChanged = true
                        }
                        for original in moveOriginals {
                            document.update(original.offsetBy(dx: dx, dy: dy))
                        }
                    }
                    return
                }

                if tool == .text || tool == .counter {
                    return // handled on tap
                }

                if tool.isFreehand {
                    if draft == nil {
                        draft = AnnotationObject(kind: tool, rect: .zero, style: style, points: [])
                    }
                    draft?.points.append(current)
                    // The bounding rect is recomputed each time so the freehand
                    // stroke stays selectable and movable like any other object.
                    if let points = draft?.points, !points.isEmpty {
                        draft?.rect = CGRect(x: points.map(\.x).min() ?? 0,
                                             y: points.map(\.y).min() ?? 0,
                                             width: (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
                                             height: (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0))
                    }
                    return
                }

                guard tool.isShape else { return }
                draft = AnnotationObject(kind: tool,
                                         rect: CGRect(x: min(point.x, current.x), y: min(point.y, current.y),
                                                      width: abs(current.x - point.x), height: abs(current.y - point.y)),
                                         style: style)
            }
            .onEnded { value in
                defer { dragStart = nil; activeHandle = nil; moveOriginals = []; moveHasChanged = false }
                if cropMode {
                    return
                }
                if tool == .move { return }
                if tool == .text || tool == .counter {
                    let point = value.location.scaled(by: 1 / fit)
                    placeTextLike(at: point)
                    return
                }
                if let draft, draft.rect.width >= 2 || !draft.points.isEmpty {
                    document.add(draft)
                    selectedID = draft.id
                }
                draft = nil
            }
    }

    private func handleGesture(_ handle: ResizeHandle, object: AnnotationObject, fit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("annotationCanvas"))
            .onChanged { value in
                if resizeOriginal == nil { resizeOriginal = object; document.beginChange() }
                guard let original = resizeOriginal else { return }
                var updated = original
                updated.rect = handle.resize(original.rect, to: value.location.scaled(by: 1 / fit))
                if original.kind.isFreehand {
                    updated.points = original.points.map { point in
                        CGPoint(x: updated.rect.minX + (point.x - original.rect.minX) * updated.rect.width / max(1, original.rect.width),
                                y: updated.rect.minY + (point.y - original.rect.minY) * updated.rect.height / max(1, original.rect.height))
                    }
                }
                document.update(updated)
            }
            .onEnded { _ in resizeOriginal = nil }
    }

    /// Places a text or counter object where the user clicked.
    private func placeTextLike(at point: CGPoint) {
        if tool == .text {
            // Text starts as a fixed-size box and grows as it is typed; an
            // empty box would be invisible and un-selectable.
            var object = AnnotationObject(kind: .text,
                                          rect: CGRect(x: point.x, y: point.y, width: 220, height: style.fontSize * 1.4),
                                          style: style, text: "Text")
            object.style.fontSize = style.fontSize
            document.add(object)
            selectedID = object.id
            // Type straight into the properties bar's text field.
            DispatchQueue.main.async { textFieldFocused = true }
        } else {
            var object = AnnotationObject(kind: .counter,
                                          rect: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28),
                                          style: style, text: "\(counterValue)")
            object.style.color = style.color
            document.add(object)
            counterValue = min(9999, counterValue + 1)
            selectedID = object.id
        }
    }

    private func applyCrop(_ rect: CGRect) {
        // Convert the canvas-space crop into image pixels for the document.
        let base = document.croppedImage
        let existing = document.cropRect ?? CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height))
        let rect = boundedCrop(rect)
        let factor = scale
        let scaled = CGRect(x: existing.minX + rect.minX * factor,
                            y: existing.minY + rect.minY * factor,
                            width: rect.width * factor,
                            height: rect.height * factor)
        document.setCrop(scaled.integral)
        for object in document.objects {
            var updated = object
            updated.rect = object.rect.offsetBy(dx: -rect.minX, dy: -rect.minY)
            updated.points = object.points.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
            document.update(updated)
        }
        cropRect = nil
        cropMode = false
        tool = .move
        // Object coordinates are relative to the cropped canvas, so a crop would
        // otherwise leave every existing annotation pointing at the wrong place.
        status = "Cropped."
    }

    // MARK: - Inspector

    private var selectedKind: AnnotationKind? { document.objects.first { $0.id == selectedID }?.kind }
    private var inspectedKind: AnnotationKind { selectedKind ?? tool }

    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool Options").font(.headline)
            section("Thickness") {
                slider(value: $style.thickness, range: 1...20, label: "\(Int(style.thickness)) pt")
            }
                if inspectedKind == .arrow {
                    section("Arrow Style") {
                        Picker("", selection: $style.arrowStyle) {
                            ForEach(ArrowStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: style.arrowStyle) { _, _ in applyStyleToSelection() }
                    }
                }

                if inspectedKind == .text || inspectedKind == .counter {
                    section("Text") {
                        slider(value: $style.fontSize, range: 10...96, label: "\(Int(style.fontSize)) pt")
                        Picker("Font", selection: Binding(get: { style.fontName ?? "" }, set: { style.fontName = $0.isEmpty ? nil : $0; applyStyleToSelection() })) {
                            Text("System").tag("")
                            ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Bold", isOn: Binding(get: { style.bold ?? true }, set: { style.bold = $0; applyStyleToSelection() }))
                        Toggle("Italic", isOn: Binding(get: { style.italic ?? false }, set: { style.italic = $0; applyStyleToSelection() }))
                        Toggle("Outline", isOn: Binding(get: { style.textOutline ?? true }, set: { style.textOutline = $0; applyStyleToSelection() }))
                        if let id = selectedID, let object = document.objects.first(where: { $0.id == id }) {
                            TextField("Text", text: Binding(
                                get: { object.text },
                                set: { newValue in
                                    document.beginChange()
                                    var updated = object; updated.text = newValue; document.update(updated)
                                }))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if tool == .counter {
                    section("Next Step") {
                        Stepper(value: $counterValue, in: 1...9999) {
                            TextField("Starting number", value: $counterValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: counterValue) { _, value in counterValue = min(9999, max(1, value)) }
                        }
                        Button("Reset to 1") { counterValue = 1 }
                        ColorSwatchRow(selection: $style.color)
                            .onChange(of: style.color) { _, _ in applyStyleToSelection() }
                    }
                }
                if inspectedKind == .pixelate {
                    section("Pixel Size") {
                        Picker("Pixel block size", selection: $style.pixelBlockSize) {
                            ForEach([8, 16, 32], id: \.self) { Text("\($0) px").tag(CGFloat($0)) }
                        }.pickerStyle(.segmented)
                            .onChange(of: style.pixelBlockSize) { _, _ in applyStyleToSelection() }
                    }
                }
                if inspectedKind == .blur {
                    section("Blur Radius") {
                        slider(value: $style.blurRadius, range: 1...64, label: "\(Int(style.blurRadius)) px")
                    }
                }

                if inspectedKind == .rectangle || inspectedKind == .filledRectangle {
                    section("Corner Radius") {
                        slider(value: $style.cornerRadius, range: 0...40, label: "\(Int(style.cornerRadius)) pt")
                    }
                }

                section("Opacity") {
                    slider(value: $style.opacity, range: 0.1...1, label: "\(Int(style.opacity * 100))%")
                }

        }
    }

    private var layers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if document.objects.isEmpty { Text("No annotations yet").foregroundStyle(.secondary) }
                if !document.objects.isEmpty {
                    section("Layers") {
                        ForEach(document.objects) { object in
                            HStack {
                                Image(systemName: object.kind.iconName).frame(width: 16)
                                Text(object.displayName).lineLimit(1).font(.caption)
                                Spacer()
                                Button { document.reorder(object.id, offset: 1) } label: { Image(systemName: "arrow.up") }
                                    .buttonStyle(.plain).help("Bring Forward")
                                Button { document.reorder(object.id, offset: -1) } label: { Image(systemName: "arrow.down") }
                                    .buttonStyle(.plain).help("Send Backward")
                                Button { document.remove(object.id); if selectedID == object.id { selectedID = nil } }
                                    label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).help("Delete")
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { selectTool(.move); selectedID = object.id; style = object.style }
                            .background(selectedID == object.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                }
            }
        }.frame(maxHeight: 360)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }

    /// A labelled slider bound to a `CGFloat` value.
    private func slider(value: Binding<CGFloat>, range: ClosedRange<CGFloat>, label: String) -> some View {
        HStack {
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = CGFloat($0); applyStyleToSelection() }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(label).font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    /// The same slider for a `Double` value, which opacity uses.
    private func slider(value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = $0; applyStyleToSelection() }),
                   in: range)
            Text(label).font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    /// Pushes the current style onto the selected object, so changing a colour
    /// after drawing updates what is already there.
    private func applyStyleToSelection() {
        guard let id = selectedID, var object = document.objects.first(where: { $0.id == id }) else { return }
        guard object.style != style else { return }
        document.beginChange()
        object.style = style
        document.update(object)
    }

    // MARK: - Output

    private func renderedImage() -> CGImage? {
        document.render(scale: scale)
    }

    private func copyToClipboard() {
        guard let image = renderedImage() else { return }
        let result = CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                                   windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
        do {
            try ScreenCaptureService.shared.copyToClipboard(result)
            status = "Copied to clipboard."
        } catch {
            status = "Copy failed: \(error.localizedDescription)"
        }
    }

    /// "Add Screenshot From File…" (⌘I): pick an image, then a side.
    private func addScreenshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add Screenshot"
        panel.message = "Choose an image, then where to place it."
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let entry = AnnotationEditorController.entry(fromImageAt: url) else {
                if response == .OK { status = "Could not add that image." }
                return
            }
            placementRequest = AnnotationPlacementRequest(image: entry.image, scale: entry.scale)
        }
    }

    private func dragProvider() -> NSItemProvider {
        guard let image = renderedImage() else { return NSItemProvider() }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = capture.displayName + " Edited.png"
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func restoreSelectionAfterHistoryChange() {
        draft = nil
        if let object = document.objects.first(where: { $0.id == selectedID }) {
            style = object.style
        } else {
            selectedID = nil
        }
    }

    private func handleEditorKey(_ event: NSEvent) -> Bool {
        guard !cropMode, !showingResize, !showingSmartHighlight, placementRequest == nil,
              !colorPopover, !optionsPopover, !layersPopover else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Object clipboard. The key monitor never sees keys while a text field
        // is being edited, so text copy/paste keeps working there.
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c": copyObjects(); return true
            case "v": return pasteObjects()
            case "d": duplicateObjects(); return true
            case "a": selectAllObjects(); return true
            default: return false
            }
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        // CleanShot single-letter tool keys (never while typing: the key
        // handler skips editable text views).
        if modifiers.isEmpty, !event.isARepeat,
           let character = event.charactersIgnoringModifiers?.first,
           let item = AnnotationToolbarItem.forShortcut(character) {
            selectToolbarItem(item)
            return true
        }
        if event.keyCode == 53 {
            guard selectedID != nil || tool != .move else { return false }
            selectedID = nil
            selectTool(.move)
            return true
        }
        guard !canvasLocked, selectedID != nil else { return false }
        if event.keyCode == 51 || event.keyCode == 117 {
            if !event.isARepeat { deleteSelection() }
            return true
        }
        guard tool == .move else { return false }
        let step: CGFloat = (modifiers == .shift ? 10 : 1) / scale
        let delta: CGPoint
        switch event.keyCode {
        case 123: delta = CGPoint(x: -step, y: 0)
        case 124: delta = CGPoint(x: step, y: 0)
        case 125: delta = CGPoint(x: 0, y: step)
        case 126: delta = CGPoint(x: 0, y: -step)
        default: return false
        }
        if !event.isARepeat { document.beginChange() }
        for object in document.objects where selectedIDs.contains(object.id) {
            document.update(object.offsetBy(dx: delta.x, dy: delta.y))
        }
        return true
    }

    private func deleteSelection() {
        guard selectedID != nil else { return }
        document.removeObjects(selectedIDs)
        selectedID = nil
    }

    // MARK: - Selection & object clipboard

    /// Primary selection plus any ⇧-click additions.
    private var selectedIDs: Set<UUID> {
        selectedID.map { extraSelection.union([$0]) } ?? []
    }

    /// Selected objects in z-order.
    private var selectedObjects: [AnnotationObject] {
        let ids = selectedIDs
        return document.objects.filter { ids.contains($0.id) }
    }

    private func toggleSelection(_ id: UUID) {
        if id == selectedID {
            selectedID = extraSelection.first
        } else if extraSelection.contains(id) {
            extraSelection.remove(id)
        } else {
            if let primary = selectedID { extraSelection.insert(primary) }
            selectedID = id
        }
    }

    private func makePrimary(_ id: UUID) {
        guard id != selectedID else { return }
        if let primary = selectedID { extraSelection.insert(primary) }
        extraSelection.remove(id)
        selectedID = id
    }

    private func select(_ ids: [UUID]) {
        if tool != .move { selectTool(.move) }
        selectedID = ids.last
        extraSelection = Set(ids.dropLast())
        if let last = ids.last, let object = document.objects.first(where: { $0.id == last }) { style = object.style }
    }

    /// ⌘C: the selected objects (editable, AOM-private) plus a PNG of them.
    /// With nothing selected, the whole image is copied instead.
    private func copyObjects() {
        let objects = selectedObjects
        guard !objects.isEmpty else {
            copyToClipboard()
            status = "No object selected — copied the whole image (⇧⌘C)."
            return
        }
        let image = document.renderObjectsImage(ids: Set(objects.map(\.id)), scale: scale)
        if AnnotationObjectClipboard.write(objects, image: image, scale: scale) {
            pasteChangeCount = NSPasteboard.general.changeCount
            pasteRepeat = 0
            status = objects.count == 1 ? "Copied object." : "Copied \(objects.count) objects."
        } else {
            status = "Could not copy the object."
        }
    }

    /// ⌘V: pastes AOM objects, offset a little further on every repeat.
    @discardableResult
    private func pasteObjects() -> Bool {
        guard let objects = AnnotationObjectClipboard.read() else {
            status = "Nothing to paste. Copy an annotation object first (⌘C)."
            return false
        }
        let changeCount = NSPasteboard.general.changeCount
        pasteRepeat = changeCount == pasteChangeCount ? pasteRepeat + 1 : 1
        pasteChangeCount = changeCount
        let ids = document.insertCopies(of: objects, offset: AnnotationObjectClipboard.pasteStep * CGFloat(pasteRepeat))
        select(ids)
        status = ids.count == 1 ? "Pasted object." : "Pasted \(ids.count) objects."
        return true
    }

    /// ⌘D: duplicates in place (offset), without touching the clipboard.
    private func duplicateObjects() {
        let objects = selectedObjects
        guard !objects.isEmpty else { status = "Select an object to duplicate."; return }
        let ids = document.insertCopies(of: objects, offset: AnnotationObjectClipboard.pasteStep)
        select(ids)
        status = ids.count == 1 ? "Duplicated object." : "Duplicated \(ids.count) objects."
    }

    private func selectAllObjects() {
        guard !document.objects.isEmpty else { return }
        select(document.objects.map(\.id))
    }

    // MARK: - Combine, print, redaction flattening

    /// Places an image next to the canvas on `placement` (drop zones / ⌘I).
    private func combine(_ image: CGImage, imageScale: CGFloat?, placement: AnnotationCombinePlacement) {
        if document.combine(image, placement: placement, scale: scale, imageScale: imageScale) {
            selectedID = nil
            zoom = nil
            status = "Image added — \(placement.title.lowercased())."
        } else {
            status = "Could not add that image (too large?)."
        }
    }

    private func printImage() {
        guard let image = renderedImage() else { status = "Nothing to print."; return }
        CapturePrintController.print(image: image, scale: scale, title: capture.displayName,
                                     window: NSApp.keyWindow)
    }

    private func flattenRedactions() {
        if document.flattenRedactions(scale: scale) {
            selectedID = nil
            status = "Redactions flattened into the image. Undo restores them."
        }
    }

    /// Small screenshot copy for the Background Tool's Blurred swatch.
    private var backgroundThumbnail: CGImage? {
        let image = document.croppedImage
        let side = 96
        let factor = CGFloat(side) / CGFloat(max(image.width, image.height, 1))
        let w = max(1, Int(CGFloat(image.width) * factor)), h = max(1, Int(CGFloat(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func saveStylePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Style Preset"
        let input = NSTextField(string: "Style \(presets.count + 1)")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        presets.insert(AnnotationStylePreset(name: String(name.prefix(80)), style: style), at: 0)
        presets = Array(presets.prefix(30))
        AnnotationStylePreset.save(presets)
    }

    private func saveProject(saveAs: Bool) {
        func write(_ url: URL) {
            do {
                try AnnotationProject(document: document, scale: scale).write(to: url)
                projectURL = url
                status = "Saved editable project. Original image is retained."
            } catch { status = "Project save failed: \(error.localizedDescription)" }
        }
        if !saveAs, let projectURL { write(projectURL); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AnnotationProject.contentType]
        panel.nameFieldStringValue = capture.displayName + ".aomannotation"
        panel.message = "Editable projects include the original image under all annotations. Export a flattened image to share redactions."
        panel.begin { response in
            if response == .OK, let url = panel.url { write(url) }
        }
    }

    private func saveAs(format: CaptureFormat = CaptureSettings.format) {
        guard let image = renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = CaptureNaming.defaultName(
            for: CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                               windowTitle: capture.windowTitle, capturedAt: capture.capturedAt))
            + " Edited." + format.fileExtension
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let result = CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                                           windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
                do {
                    let data = try ScreenCaptureService.shared.encode(result, format: format)
                    try data.write(to: url, options: .atomic)
                    markSaved()
                    status = "Saved \(url.lastPathComponent)."
                } catch {
                    status = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// ⌘S: a new "… Edited" file in the export location. Source files are
    /// never overwritten.
    @discardableResult
    private func saveToExportLocation() -> Bool {
        guard let image = renderedImage() else { status = "Nothing to save."; return false }
        let result = CaptureResult(image: image,
                                   globalRect: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
                                                      height: CGFloat(image.height) / scale),
                                   scale: scale, kind: capture.kind,
                                   windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
        do {
            let name = CaptureNaming.defaultName(for: result) + " Edited"
            let url = try ScreenCaptureService.shared.writeToDisk(result, fileName: name)
            markSaved()
            status = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Save (or apply to the clipboard for clipboard edits).
    private func commitChanges() -> Bool {
        AnnotationBackgroundPresetStore.rememberPrevious(document.background)
        if let onApply {
            guard let image = renderedImage() else { return false }
            onApply(image)
            markSaved()
            return true
        }
        return saveToExportLocation()
    }

    /// Done: keep the changes, then close.
    private func done() {
        if isDirty, !commitChanges() { return }
        session?.close()
    }

    private func pin() {
        guard let image = renderedImage() else { return }
        let entry = CaptureHistoryEntry(image: image, kind: capture.kind, capturedAt: capture.capturedAt,
                                        windowTitle: capture.windowTitle, fileURL: fileURL)
        PinnedScreenshotController.shared.pin(entry: entry, url: fileURL)
        status = "Pinned to screen."
    }
}

/// Uses the native macOS sharing picker with the rendered document.
private struct AnnotationShareButton: NSViewRepresentable {
    let image: CGImage?
    let scale: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.toolTip = "Share"
        button.setAccessibilityLabel("Share")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.image = image.map {
            NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale))
        }
        button.isEnabled = image != nil
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    final class Coordinator: NSObject {
        var image: NSImage?
        private var picker: NSSharingServicePicker?
        @objc func share(_ sender: NSButton) {
            guard let image else { return }
            let picker = NSSharingServicePicker(items: [image])
            self.picker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

/// A compact colour row used inside the background settings.
private struct ColorSwatchRow: View {
    @Binding var selection: AnnotationColor

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
            ForEach(AnnotationColor.allCases) { choice in
                Button { selection = choice } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: choice.nsColor))
                        .frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(selection == choice ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selection == choice ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(choice.displayName)
            }
        }
    }
}

/// Draws the object currently being dragged, before it is committed.
private struct DraftOverlay: View {
    let object: AnnotationObject
    let fit: CGFloat
    let scale: CGFloat

    var body: some View {
        let rect = object.rect.scaled(by: fit)
        let color = Color(nsColor: object.style.resolvedColor)
        Group {
            switch object.kind {
            case .rectangle:
                Rectangle().path(in: rect).stroke(color, lineWidth: object.style.thickness * fit)
            case .filledRectangle:
                Rectangle().path(in: rect).fill(color)
            case .ellipse:
                Ellipse().path(in: rect).stroke(color, lineWidth: object.style.thickness * fit)
            case .line:
                Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                }.stroke(color, lineWidth: object.style.thickness * fit)
            case .arrow:
                Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                }.stroke(color, style: StrokeStyle(lineWidth: object.style.thickness * fit, lineCap: .round))
            case .blur:
                Rectangle().path(in: rect).fill(Color.gray.opacity(0.25))
                    .overlay(Rectangle().path(in: rect).stroke(Color.white.opacity(0.5), lineWidth: 1))
            case .redact:
                // Preview matches the opaque export: no semi-transparent "privacy" mask.
                Rectangle().path(in: rect).fill(Color.black)
            case .secureBlur:
                // Opaque placeholder while dragging; the secure pixels render on release.
                Rectangle().path(in: rect).fill(Color(white: 0.45))
                    .overlay(Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.8))
                        .position(x: rect.midX, y: rect.midY))
            case .pixelate:
                Rectangle().path(in: rect).fill(Color.black.opacity(0.35))
                    .overlay(Rectangle().path(in: rect).stroke(Color.white.opacity(0.6), lineWidth: 1))
            case .spotlight:
                Rectangle().path(in: rect).stroke(Color.white, lineWidth: 1)
            case .draw, .drawHighlight:
                Path { path in
                    let points = object.points.map { $0.scaled(by: fit) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color.opacity(object.kind == .drawHighlight ? 0.4 : 1),
                        style: StrokeStyle(lineWidth: object.style.thickness * fit, lineCap: .round, lineJoin: .round))
            default:
                Rectangle().path(in: rect).stroke(color, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The eight resize handles on a selected object.
private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Returns `rect` resized by moving this handle to `point`.
    func resize(_ rect: CGRect, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch self {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        // Never let a drag invert the rect; a zero-width object cannot be
        // selected again, so a minimum is enforced instead.
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: max(4, abs(maxX - minX)), height: max(4, abs(maxY - minY)))
    }
}

private extension CGRect {
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}

private extension CGPoint {
    func scaled(by factor: CGFloat) -> CGPoint {
        CGPoint(x: x * factor, y: y * factor)
    }
}

private extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}

/// Dedicated pixel-dimension dialog, separate from crop selection. Mirrors the
/// source NIB's *functional* controls with an independently implemented UI.
private struct AnnotationResizeDialog: View {
    @Environment(\.dismiss) private var dismiss
    private let originalWidth: Int
    private let originalHeight: Int
    private let onResize: (Int, Int, Bool) -> Void

    @State private var width: Int
    @State private var height: Int
    @State private var keepAspect = true
    @State private var flattenAnnotations = false
    @State private var usePercent = false

    init(pixelWidth: Int, pixelHeight: Int,
         onResize: @escaping (Int, Int, Bool) -> Void) {
        self.originalWidth = pixelWidth
        self.originalHeight = pixelHeight
        self.onResize = onResize
        _width = State(initialValue: pixelWidth)
        _height = State(initialValue: pixelHeight)
    }

    // TextField accepts arbitrary signed integers. Clamp intermediate Double
    // conversions to avoid traps on excessively large entered percentages.
    private func safePixels(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let maxConvertible = Double(Int.max / 4)
        return Int(min(maxConvertible, max(-maxConvertible, value.rounded())))
    }

    private var widthEntry: Binding<Int> {
        Binding(
            get: {
                usePercent ? safePixels(Double(width) / Double(max(1, originalWidth)) * 100) : width
            },
            set: { entered in
                width = safePixels(usePercent
                    ? Double(entered) * Double(originalWidth) / 100
                    : Double(entered))
                if keepAspect {
                    height = safePixels(Double(width) * Double(originalHeight) /
                                        Double(max(1, originalWidth)))
                }
            }
        )
    }

    private var heightEntry: Binding<Int> {
        Binding(
            get: {
                usePercent ? safePixels(Double(height) / Double(max(1, originalHeight)) * 100) : height
            },
            set: { entered in
                height = safePixels(usePercent
                    ? Double(entered) * Double(originalHeight) / 100
                    : Double(entered))
                if keepAspect {
                    width = safePixels(Double(height) * Double(originalWidth) /
                                       Double(max(1, originalHeight)))
                }
            }
        )
    }

    private var dimensionsValid: Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
            Int64(width) * Int64(height) <= 100_000_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Image").font(.headline)
            Text("Original size: \(originalWidth) × \(originalHeight) pixels")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                TextField("Width", value: widthEntry, format: .number)
                    .accessibilityLabel("Resize width")
                Button { keepAspect.toggle() } label: {
                    Image(systemName: keepAspect ? "link" : "link.slash")
                        .foregroundStyle(keepAspect ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .help(keepAspect ? "Unlock aspect ratio" : "Lock aspect ratio")
                    .accessibilityLabel("Preserve aspect ratio")
                    .accessibilityValue(keepAspect ? "On" : "Off")
                TextField("Height", value: heightEntry, format: .number)
                    .accessibilityLabel("Resize height")
                Picker("Units", selection: $usePercent) {
                    Text("Pixels (px)").tag(false)
                    Text("Percent (%)").tag(true)
                }
                .labelsHidden().frame(width: 100)
            }
            .textFieldStyle(.roundedBorder)

            Toggle("Preserve aspect ratio", isOn: $keepAspect)
                .onChange(of: keepAspect) { _, enabled in
                    if enabled {
                        height = safePixels(Double(width) * Double(originalHeight) /
                                            Double(max(1, originalWidth)))
                    }
                }

            Toggle("Flatten Annotations", isOn: $flattenAnnotations)
            Text("This action will flatten all annotations, making them uneditable.")
                .font(.caption).foregroundStyle(.secondary)

            if !dimensionsValid {
                Text("Dimensions must be 1–16,384 pixels and at most 100 million pixels total.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") { onResize(width, height, flattenAnnotations) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dimensionsValid)
            }
        }
        .padding(22)
        .frame(width: 510)
    }
}

/// Normalized Vision bounding-box conversion, independent from view dimensions.
/// Vision uses bottom-left origin; annotation objects use top-left points.
enum AnnotationSmartTextMatcher {
    static func annotationRect(from box: CGRect, pixelSize: CGSize, scale: CGFloat) -> CGRect {
        guard scale.isFinite, scale > 0 else { return .zero }
        let pointWidth = pixelSize.width / scale
        let pointHeight = pixelSize.height / scale
        return CGRect(x: box.minX * pointWidth,
                      y: (1 - box.maxY) * pointHeight,
                      width: box.width * pointWidth,
                      height: box.height * pointHeight)
    }

    static func matches(in image: CGImage, query: String, scale: CGFloat) throws -> [CGRect] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.count <= 100, scale.isFinite, scale > 0 else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        let pixelSize = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation -> CGRect? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.string.localizedCaseInsensitiveContains(needle) else { return nil }
            let bounds = annotationRect(from: observation.boundingBox, pixelSize: pixelSize, scale: scale)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return bounds
        }.prefix(100).map { $0 }
    }
}

/// Comparable snapshot of everything the user can change in the editor.
private struct AnnotationSavedState: Equatable {
    let objects: [AnnotationObject]
    let cropRect: CGRect?
    let background: AnnotationBackground
    let baseImage: CGImage

    init(_ document: AnnotationDocument) {
        objects = document.objects
        cropRect = document.cropRect
        background = document.background
        baseImage = document.baseImage
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.objects == rhs.objects && lhs.cropRect == rhs.cropRect
            && lhs.background == rhs.background && lhs.baseImage === rhs.baseImage
    }
}
