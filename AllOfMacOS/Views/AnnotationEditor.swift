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
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 200_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000,
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
    /// F-04C: true while an asynchronous export is in flight, so the window is
    /// never torn down mid-write.
    var isBusy: () -> Bool = { false }
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
        window.applyCaptureVisibilityPreference()
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
        guard !closeConfirmed else { return true }
        // F-04C: never tear the editor down in the middle of an asynchronous
        // export. The export closes the window itself on success when a commit
        // is pending; otherwise the user can close again once it finishes.
        guard !session.isBusy() else { return false }
        guard session.isDirty() else { return true }
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
    /// F-04C: a full-image export is encoding/writing off the main thread; this
    /// blocks re-entry so a double click can never start two writes.
    @State private var exportInFlight = false
    /// F-04C: a Done / close-Save commit is waiting for the in-flight export to
    /// finish; the export closes the window itself once the file is written.
    @State private var closeAfterExport = false

    @State private var colorPopover = false
    @State private var optionsPopover = false
    /// The Text tool's Format popover (weight, emphasis, alignment, effects).
    @State private var textFormatPopover = false
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

    // 3.3.3 eraser: the last pointer position of the drag, whether the drag
    // already took its undo snapshot, and how much it erased.
    @State private var eraserMode = AnnotationSettings.eraserMode()
    @State private var eraserSize = AnnotationSettings.eraserSize()
    @State private var eraserLast: CGPoint?
    @State private var eraserChanged = false
    @State private var eraserCount = 0

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

    /// F-04C: records the exact document state that was written to disk.
    ///
    /// `exportedState` is captured *before* the asynchronous encode/write starts.
    /// If an edit lands while that write is in flight, `savedState` is set to the
    /// exported snapshot and the newer edit stays dirty, instead of the old
    /// `markSaved()` behaviour that stamped the (possibly changed) live document
    /// as saved. Returns `true` when the document has moved past what was written.
    @discardableResult
    private func markExported(_ exportedState: AnnotationSavedState) -> Bool {
        savedState = exportedState
        return AnnotationSavedState(document) != exportedState
    }

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
            AnnotationPlacementChooser(thumbnail: request.image, choose: { placement in
                placementRequest = nil
                if let placement { combine(request.image, imageScale: request.scale, placement: placement) }
            }, chooseLayer: {
                placementRequest = nil
                insertImageLayer(request.image, imageScale: request.scale)
            })
        }
        .background(CaptureKeyEventHandler(handle: handleEditorKey))
        .onAppear {
            session?.isDirty = { isDirty }
            session?.isBusy = { exportInFlight }
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
        HStack(spacing: AOMSpace.x2) {
            Color.clear.frame(width: AOMFeatureSize.trafficLightsInset, height: AOMFeatureSize.barControlHeight)
            capsuleButton(AnnotationToolbarItem.crop.symbol, help: AnnotationToolbarItem.crop.help,
                          active: cropMode) { selectToolbarItem(.crop) }
            capsuleButton(AnnotationToolbarItem.background.symbol, help: AnnotationToolbarItem.background.help,
                          active: backgroundPanelOpen) { selectToolbarItem(.background) }
            capsuleButton("photo.badge.plus", help: "Add Screenshot From File… (⌘I)") { addScreenshot() }
                .keyboardShortcut("i", modifiers: .command)
            capsuleButton(AnnotationToolbarItem.imageLayer.symbol,
                          help: "Insert Image Layer… (⌥⌘I) — move, resize and rotate it freely") {
                selectToolbarItem(.imageLayer)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(AnnotationToolbarItem.segments) { item in
                        if item == .marker {
                            AOMDivider(axis: .vertical).frame(height: AOMIcon.row)
                                .padding(.horizontal, AOMSpace.x1)
                        }
                        toolButton(item)
                    }
                }
                .padding(AOMSpace.x0_5)
                .background(AOMColor.track, in: Capsule())
                .padding(.vertical, AOMSpace.x0_5)
                .background(NativeScrollChrome(.hidden))
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            moreMenu
            outputActions
        }
        .padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowDetail)
        .background(.bar)
    }

    private var outputActions: some View {
        HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Image(systemName: "hand.draw")
                .font(AOMFont.body.weight(.semibold))
                .frame(width: AOMFeatureSize.barButtonWidth, height: AOMFeatureSize.barControlHeight)
                .background(AOMColor.track, in: Capsule())
                .contentShape(Capsule())
                .onDrag { dragProvider() }
                .help("Drag the edited image to another app")
                .accessibilityLabel("Drag image to another app")
            capsuleButton("pin.fill", help: "Pin to the Screen") { pin() }
            capsuleButton("doc.on.doc", help: "Copy to Clipboard (⇧⌘C)") { copyToClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            HStack(spacing: 0) {
                Button { saveToExportLocation() } label: {
                Text("Save").font(AOMFont.body.weight(.medium))
                        .padding(.leading, AOMSpace.x3).padding(.trailing, AOMSpace.x1 + AOMSpace.x0_5)
                        .frame(height: AOMFeatureSize.barControlHeight)
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
                    Image(systemName: "chevron.down").font(AOMFont.badge.weight(.bold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, AOMSpace.x2).frame(height: AOMFeatureSize.barControlHeight)
                .help("Save options")
                .accessibilityLabel("Save options")
            }
            .background(AOMColor.track, in: Capsule())
            if let onApply {
                Button("Apply to Clipboard") {
                    if let image = renderedImage() { onApply(image); markSaved(); status = "Updated clipboard image." }
                }.buttonStyle(.bordered).controlSize(.large).fixedSize()
            }
            Button { done() } label: {
                Text("Done").font(AOMFont.bodyEmphasis)
                    .foregroundStyle(AOMTheme.onAccent(AOMColor.accent))
                    .padding(.horizontal, AOMSpace.x4).frame(height: AOMFeatureSize.barControlHeight)
                    .background(AOMColor.accent, in: Capsule())
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
            Button("Remove Background") { removeBackground() }
                .help("Make everything except the subject transparent (Undo restores it)")
            Button("Smart Highlight Text…") { showingSmartHighlight = true }
            Divider()
            Button("Layers…") { layersPopover = true }
            Button("Insert Image Layer From File…") { insertImageLayerFromFile() }
            Button("Paste Image as Layer") { pasteImageLayer() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Menu("Arrange") {
                Button(AnnotationArrangement.bringToFront.title) { arrangeSelection(.bringToFront) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(AnnotationArrangement.bringForward.title) { arrangeSelection(.bringForward) }
                    .keyboardShortcut("]", modifiers: .command)
                Button(AnnotationArrangement.sendBackward.title) { arrangeSelection(.sendBackward) }
                    .keyboardShortcut("[", modifiers: .command)
                Button(AnnotationArrangement.sendToBack.title) { arrangeSelection(.sendToBack) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            .disabled(selectedID == nil)
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
        } label: { Image(systemName: "ellipsis").frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea).contentShape(Rectangle()) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More Options").accessibilityLabel("More Options")
        .popover(isPresented: $layersPopover) { layers.padding(AOMSpace.x4).frame(width: AOMSize.drawerWidth.lowerBound) }
    }

    // MARK: - Properties bar

    /// Contextual properties for the active tool (or the selected object).
    private var propertiesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AOMSpace.x3) {
                palette
                propertyDivider
                toolProperties
                propertyDivider
                propertySlider("Opacity", value: Binding(get: { CGFloat(style.opacity) }, set: { style.opacity = Double($0) }),
                               range: 0.1...1, width: AOMFeatureSize.sliderShort, label: "\(Int(style.opacity * 100))%")
                Button { optionsPopover.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea - AOMSpace.x1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("More Tool Options").accessibilityLabel("More Tool Options")
                .popover(isPresented: $optionsPopover) {
                    toolOptions.padding(AOMSpace.x4).frame(width: AOMFeatureSize.toolPopoverWidth)
                }
                if inspectedKind == .draw || inspectedKind == .drawHighlight {
                    Toggle(isOn: $canvasLocked) {
                        Image(systemName: canvasLocked ? "lock.fill" : "lock.open")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .toggleStyle(.button).help("Lock Canvas").accessibilityLabel("Lock Canvas")
                }
            }
            .font(AOMFont.body)
            .controlSize(.small)
            .padding(.horizontal, AOMSpace.x4)
            .frame(height: AOMSize.rowStandard)
            .background(NativeScrollChrome(.hidden))
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var propertyDivider: some View {
        AOMDivider(axis: .vertical).frame(height: AOMIcon.row)
    }

    private var palette: some View {
        HStack(spacing: AOMSpace.x1) {
            ForEach(AnnotationColor.palette) { color in
                Button {
                    style.color = color
                    style.customColorHex = nil
                    applyStyleToSelection()
                } label: {
                    Circle().fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                        .frame(width: AOMFeatureSize.swatchSmall, height: AOMFeatureSize.swatchSmall)
                        .padding(AOMSpace.x0_5)
                        .overlay(Circle().strokeBorder(AOMColor.accent,
                                                       lineWidth: style.customColorHex == nil && style.color == color ? AOMFeatureSize.swatchRing : 0))
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(style.customColorHex == nil && style.color == color ? .isSelected : [])
            }
            Button { colorPopover.toggle() } label: {
                ZStack {
                    // The colour wheel names the picker, so it shows the hues themselves.
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center))
                        .frame(width: AOMFeatureSize.swatchSmall + AOMSpace.x0_5, height: AOMFeatureSize.swatchSmall + AOMSpace.x0_5)
                    Circle().fill(Color(nsColor: style.resolvedColor))
                        .frame(width: AOMFeatureSize.swatchSmall / 2 + 1, height: AOMFeatureSize.swatchSmall / 2 + 1)
                        .overlay(Circle().strokeBorder(AOMFeatureColor.onMedia, lineWidth: 1))
                }
                .padding(1)
                .overlay(Circle().strokeBorder(AOMColor.accent, lineWidth: style.customColorHex != nil ? AOMFeatureSize.swatchRing : 0))
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
                propertySlider("Thickness", value: $style.thickness, range: 1...20, width: AOMFeatureSize.sliderStandard,
                               label: "\(Int(style.thickness)) pt")
            }
            if kind == .arrow {
                Picker("Arrow style", selection: $style.arrowStyle) {
                    ForEach(ArrowStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: AOMFeatureSize.barPicker)
                .help("Arrow style")
                .onChange(of: style.arrowStyle) { _, _ in applyStyleToSelection() }
            }
            if kind == .rectangle {
                propertySlider("Corners", value: $style.cornerRadius, range: 0...40, width: AOMFeatureSize.sliderShort,
                               label: "\(Int(style.cornerRadius)) pt")
            }
            if kind == .spotlight {
                Picker("Shape", selection: Binding(
                    get: { style.spotlightShape ?? .rectangle },
                    set: { style.spotlightShape = $0; applyStyleToSelection() }
                )) {
                    Label("Rectangle", systemImage: "rectangle").tag(SpotlightShape.rectangle)
                    Label("Ellipse", systemImage: "circle").tag(SpotlightShape.ellipse)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: AOMFeatureSize.barPickerWide)
                .help("Spotlight shape")

                propertySlider("Dim Opacity", value: Binding(
                    get: { CGFloat(style.spotlightOpacity ?? 0.55) },
                    set: { style.spotlightOpacity = Double($0); applyStyleToSelection() }
                ), range: 0.2...0.95, width: AOMFeatureSize.sliderStandard, label: "\(Int((style.spotlightOpacity ?? 0.55) * 100))%")
            } else if kind == .highlighter {
                Text("Rectangular marker").foregroundStyle(AOMColor.textSecondary)
            }
        case .filledRectangle:
            propertySlider("Corners", value: $style.cornerRadius, range: 0...40, width: AOMFeatureSize.sliderShort,
                           label: "\(Int(style.cornerRadius)) pt")
        case .text:
            // The Text tool keeps its most-used controls in the bar (one-click
            // styles, size, the text itself); weight, emphasis, alignment and
            // effects live in the Format popover, grouped.
            textStylePresetMenu
            propertySlider("Font size", value: $style.fontSize, range: 10...96, width: AOMFeatureSize.sliderStandard,
                           label: "\(Int(style.fontSize)) pt")
            Button { textFormatPopover.toggle() } label: {
                Label("Format", systemImage: "textformat")
            }
            .help("Weight, bold, italic, alignment, background, outline and shadow")
            .accessibilityLabel("Text format")
            .popover(isPresented: $textFormatPopover, arrowEdge: .bottom) { textFormatOptions }
            if let id = selectedID, let object = document.objects.first(where: { $0.id == id }), object.kind == .text {
                // 3.3.3: vertical axis, so ⌥↩ adds a line (the box grows to fit).
                TextField("Text", text: Binding(
                    get: { object.text },
                    set: { newValue in
                        document.beginChange()
                        var updated = object; updated.text = newValue; document.update(fittedText(updated))
                    }), axis: .vertical)
                .lineLimit(1)
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
                .frame(width: 200)
                .help("Text (⌥↩ starts a new line; More Tool Options shows every line)")
                .accessibilityLabel("Text content")
            }
        case .eraser:
            Picker("Eraser mode", selection: Binding(
                get: { eraserMode },
                set: { eraserMode = $0; AnnotationSettings.setEraserMode($0) })) {
                ForEach(AnnotationEraserMode.allCases) { Text($0.title).tag($0).help($0.help) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(eraserMode.help).accessibilityLabel("Eraser mode")
            propertySlider("Size", value: Binding(get: { eraserSize },
                                                  set: { eraserSize = $0; AnnotationSettings.setEraserSize($0) }),
                           range: AnnotationEraser.radiusRange, width: AOMFeatureSize.sliderStandard, label: "\(Int(eraserSize * 2)) pt")
            Text("\(eraserMode.help) · ⌘Z restores").foregroundStyle(AOMColor.textSecondary)
        case .image:
            if let id = selectedID, let object = document.objects.first(where: { $0.id == id }), object.kind == .image {
                propertySlider("Rotation", value: Binding(
                    get: { object.resolvedRotation * 180 / .pi },
                    set: { setRotation(of: id, radians: $0 * .pi / 180) }),
                               range: -180...180, width: AOMFeatureSize.sliderWide, label: "\(Int((object.resolvedRotation * 180 / .pi).rounded()))°")
                Button("Upright") { setRotation(of: id, radians: 0) }
                    .disabled(object.resolvedRotation == 0).help("Reset the rotation")
                Button { arrangeSelection(.bringToFront) } label: {
                    Image(systemName: "square.3.layers.3d.top.filled")
                }
                .buttonStyle(.plain).help("Bring to Front (⇧⌘])").accessibilityLabel("Bring to Front")
                Button { arrangeSelection(.sendToBack) } label: {
                    Image(systemName: "square.3.layers.3d.bottom.filled")
                }
                .buttonStyle(.plain).help("Send to Back (⇧⌘[)").accessibilityLabel("Send to Back")
                Text("Corners resize (⇧ keeps the ratio) · the round handle rotates (⇧ snaps to 15°)")
                    .foregroundStyle(AOMColor.textSecondary)
            }
        case .counter:
            Picker("Counter Style", selection: Binding(
                get: { style.counterStyle ?? .numbers },
                set: { style.counterStyle = $0; applyStyleToSelection() }
            )) {
                ForEach(CounterStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: AOMFeatureSize.barPicker)
            .help("Counter sequence style")

            Text("Next").foregroundStyle(AOMColor.textSecondary)
            Stepper(value: $counterValue, in: 1...9999) {
                Text((style.counterStyle ?? .numbers).format(counterValue)).monospacedDigit().frame(minWidth: AOMIcon.hitArea)
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
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help((AnnotationRedactionStyle(kind: kind) ?? .pixelate).help)
            .accessibilityLabel("Redaction style")
            if kind.isSecureRedaction {
                Image(systemName: "checkmark.shield").foregroundStyle(AOMColor.successText)
                    .help("Exported pixels in this area are fully replaced")
                    .accessibilityLabel("Irreversible redaction")
            }
            if kind == .secureBlur {
                Picker("Block size", selection: $style.pixelBlockSize) {
                    ForEach([16, 24, 32, 48], id: \.self) { Text("\($0) px").tag(CGFloat($0)) }
                }
                .labelsHidden().frame(width: AOMFeatureSize.barPickerNarrow).help("Secure blur block size (larger hides more)")
                .onChange(of: style.pixelBlockSize) { _, _ in applyStyleToSelection() }
            }
            if kind == .pixelate {
                Picker("Pixel size", selection: $style.pixelBlockSize) {
                    ForEach([8, 16, 32], id: \.self) { Text("\($0) px").tag(CGFloat($0)) }
                }
                .labelsHidden().frame(width: AOMFeatureSize.barPickerNarrow).help("Pixel block size")
                .onChange(of: style.pixelBlockSize) { _, _ in applyStyleToSelection() }
            } else if kind == .blur {
                propertySlider("Intensity", value: $style.blurRadius, range: 1...64, width: AOMFeatureSize.barPickerNarrow,
                               label: "\(Int(style.blurRadius)) px")
            }
        case .move:
            Text(selectedID == nil ? "Select an object to edit it · Arrow keys nudge (⇧ 10 px)"
                                   : "Arrow keys nudge (⇧ 10 px) · ⌫ deletes")
                .foregroundStyle(AOMColor.textSecondary)
        default:
            EmptyView()
        }
    }

    /// The Text tool's Format popover, grouped the way a text inspector is:
    /// the font, the paragraph, then what is drawn behind and around the text.
    /// Every control applies at once to the selected text and to new text.
    private var textFormatOptions: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            AOMSection("Font") {
                AOMSettingRow("Weight") {
                    Picker("Weight", selection: Binding(
                        get: { style.resolvedFontWeight },
                        set: { style.fontWeight = $0; style.bold = $0.isBold; applyStyleToSelection() })) {
                        ForEach(AnnotationFontWeight.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Font weight")
                }
                AOMSettingRow("Bold") {
                    Toggle("Bold", isOn: Binding(get: { style.resolvedFontWeight.isBold },
                                                 set: { style.fontWeight = nil; style.bold = $0; applyStyleToSelection() }))
                        .help("Bold")
                }
                AOMSettingRow("Italic") {
                    Toggle("Italic", isOn: Binding(get: { style.italic ?? false }, set: { style.italic = $0; applyStyleToSelection() }))
                        .help("Italic")
                }
            }
            AOMSection("Paragraph") {
                AOMSettingRow("Alignment") {
                    Picker("Alignment", selection: Binding(
                        get: { style.resolvedTextAlignment },
                        set: { style.textAlignment = $0 == .left ? nil : $0; applyStyleToSelection() })) {
                        ForEach(AnnotationTextAlignment.allCases) { alignment in
                            Image(systemName: alignment.symbol).tag(alignment).help("Align \(alignment.displayName)")
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Text alignment").accessibilityLabel("Text alignment")
                }
            }
            AOMSection("Background & effects", footer: "More Tool Options sets the text, box and outline colours and the outline width.") {
                AOMSettingRow("Background") {
                    Picker("Background", selection: Binding(
                        get: { style.resolvedTextBackground },
                        set: { style.textBackground = $0 == .none ? nil : $0; applyStyleToSelection() })) {
                        ForEach(AnnotationTextBackground.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Text background: a box or speech bubble in the main colour (More Tool Options sets its own colour)")
                    .accessibilityLabel("Text background")
                }
                AOMSettingRow("Outline") {
                    Toggle("Outline", isOn: Binding(get: { style.textOutline ?? true }, set: { style.textOutline = $0; applyStyleToSelection() }))
                        .help("Outlined text style")
                }
                AOMSettingRow("Shadow") {
                    Toggle("Text shadow", isOn: Binding(get: { style.textShadow ?? false },
                                                        set: { style.textShadow = $0 ? true : nil; applyStyleToSelection() }))
                        .help("Drop shadow")
                }
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: AOMFeatureSize.toolPopoverWidth)
    }

    private func propertySlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                                width: CGFloat, label: String) -> some View {
        HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Text(title).foregroundStyle(AOMColor.textSecondary)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = CGFloat($0); applyStyleToSelection() }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: width)
                .accessibilityLabel(title)
                .accessibilityValue(label)
            Text(label).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                .frame(minWidth: AOMFeatureSize.sliderValue, alignment: .leading)
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
            withAnimation(AOMMotion.quick) { backgroundPanelOpen.toggle() }
        case .crop:
            selectTool(cropMode ? .move : .crop)
        case .redact:
            selectTool(redactKind)
        case .imageLayer:
            insertImageLayerFromFile()
        default:
            if let kind = item.kinds.first { selectTool(kind) }
        }
    }

    private func capsuleButton(_ symbol: String, help: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(AOMFont.section)
                .foregroundStyle(active ? AOMTheme.onAccent(AOMColor.accent) : AOMColor.text)
                .frame(width: AOMFeatureSize.barButtonWidth, height: AOMFeatureSize.barControlHeight)
                // The same quiet track as the tool group, so every bar button reads as one.
                .background(active ? AOMColor.accent : AOMColor.track, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
            .accessibilityAddTraits(active ? .isSelected : [])
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

    private func removeBackground() {
        let source = document.baseImage
        status = "Removing background…"
        Task { @MainActor in
            do {
                let output = try await BackgroundRemoval.removingBackground(source)
                guard document.replaceBaseImage(output) else {
                    status = "Could not remove the background."
                    return
                }
                status = "Background removed. Undo restores the original."
            } catch {
                status = error.localizedDescription
            }
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
                .font(AOMFont.section)
                .frame(width: AOMIcon.headerBadge + 1, height: AOMIcon.hitArea + 1)
                .background(active ? AOMColor.accent : Color.clear, in: Capsule())
                .foregroundStyle(active ? AOMTheme.onAccent(AOMColor.accent) : AOMColor.text)
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
                    .font(AOMFont.callout.weight(.medium)).monospacedDigit()
                    .frame(width: AOMFeatureSize.barPickerNarrow - AOMSpace.x5, height: AOMSize.rowSingle)
            }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, AOMSpace.x2)
            .background(AOMColor.track, in: Capsule())
            .help("Zoom").accessibilityLabel("Zoom")
            if cropMode {
                Toggle("Snap to edges", isOn: $snapToEdges).toggleStyle(.checkbox).font(AOMFont.callout)
                Text("Hold Command ⌘ to disable snapping.").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
            Spacer()
            Text("\(document.croppedImage.width) × \(document.croppedImage.height) px")
                .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
            if !cropMode {
                AnnotationShareButton(image: renderedImage(), scale: scale)
                    .frame(width: AOMFeatureSize.barButtonWidth, height: AOMFeatureSize.barControlHeight)
            }
        }
        // macOS 26 rounds windows more: keep the end controls clear of the
        // bottom corners.
        .padding(.horizontal, AOMSpace.x5).frame(height: AOMSize.rowDouble)
        .background(.bar)
    }

    private var cropToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: AOMSpace.x3) {
            Color.clear.frame(width: AOMFeatureSize.trafficLightsInset, height: AOMFeatureSize.barControlHeight)
            capsuleButton("crop", help: "Exit Crop", active: true) { cropMode = false }
            Picker("Aspect Ratio", selection: Binding<AnnotationCropPreset>(
                get: {
                    // A fixed ratio wins over "Original" when both match.
                    let size = CGSize(width: document.croppedImage.width, height: document.croppedImage.height)
                    let fixed = AnnotationCropPreset.allCases.filter { $0 != .original }
                    return fixed.first { abs($0.ratio(imageSize: size) - cropAspect) < 0.0001 }
                        ?? (abs(AnnotationCropPreset.original.ratio(imageSize: size) - cropAspect) < 0.0001 ? .original : .freeform)
                },
                set: { preset in
                    let bounds = CGRect(x: 0, y: 0, width: CGFloat(document.croppedImage.width) / scale,
                                        height: CGFloat(document.croppedImage.height) / scale)
                    cropAspect = preset.ratio(imageSize: bounds.size)
                    // The largest selection of that ratio, centred (3.3.3).
                    guard cropAspect > 0 else { return }
                    cropRect = boundedCrop(AnnotationCropPreset.centredRect(ratio: cropAspect, in: bounds))
                })) {
                ForEach(AnnotationCropPreset.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: AOMFeatureSize.barPicker + AOMSpace.x6)
                .help("Aspect ratio of the crop")
            cropDimension("Width", width: true)
            Image(systemName: "arrow.left.and.right").foregroundStyle(AOMColor.textSecondary)
            cropDimension("Height", width: false)
            Divider().frame(height: AOMSpace.x6)
            Text("Image size:").foregroundStyle(AOMColor.textSecondary)
            Text("\(document.croppedImage.width) × \(document.croppedImage.height) px")
                .monospacedDigit()
                .padding(.horizontal, AOMSpace.x3).frame(height: AOMFeatureSize.barControlHeight)
                .background(AOMColor.track, in: Capsule())
            Spacer()
            Button("Cancel") { selectTool(.move) }.buttonStyle(.plain)
                .padding(.horizontal, AOMSpace.x4).frame(height: AOMFeatureSize.barControlHeight)
                .background(AOMColor.track, in: Capsule())
                .keyboardShortcut(.escape, modifiers: [])
            Button { if let cropRect { applyCrop(cropRect) } } label: {
                Text("Crop").foregroundStyle(AOMTheme.onAccent(AOMColor.accent)).fontWeight(.semibold)
                    .padding(.horizontal, AOMSpace.x4).frame(height: AOMFeatureSize.barControlHeight)
                    .background(AOMColor.accent, in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: [])
                .disabled(cropRect == nil || (cropRect?.width ?? 0) < 1 || (cropRect?.height ?? 0) < 1)
        }.font(AOMFont.body).padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowDetail)
            .background(NativeScrollChrome(.hidden))
        }
        .scrollIndicators(.hidden)
        .background(.bar)
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
            .textFieldStyle(.roundedBorder).frame(width: AOMFeatureSize.barPickerNarrow - AOMSpace.x5).accessibilityLabel(label)
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
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    if let rendered = document.render(scale: scale, draft: privacyDraft) {
                        Image(decorative: rendered, scale: scale).resizable()
                            .frame(width: drawn.width, height: drawn.height)
                    }
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(document.objects) { object in
                            if object.id == selectedID, tool == .move {
                                if object.kind == .image {
                                    imageLayerHandles(for: object, fit: fit)
                                } else {
                                    selectionHandles(for: object, fit: fit)
                                }
                            } else if extraSelection.contains(object.id), tool == .move {
                                Rectangle().path(in: object.rect.scaled(by: fit))
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .allowsHitTesting(false)
                            }
                        }
                        if let draft, draft.kind != .blur && draft.kind != .pixelate { DraftOverlay(object: draft, fit: fit, scale: scale) }
                        if cropMode, let cropRect { cropOverlay(cropRect: cropRect, fit: fit, imageSize: imageSize) }
                        if tool == .eraser, let eraserLast {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1))
                                .frame(width: eraserSize * 2 * fit, height: eraserSize * 2 * fit)
                                .position(eraserLast.scaled(by: fit))
                                .allowsHitTesting(false)
                        }
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
                                                               },
                                                               onDropLayer: { image, imageScale, location in
                                                                   // ⌥-drop: a free layer under the pointer.
                                                                   let point = CGPoint(x: (location.x - origin.x) / fit,
                                                                                       y: (location.y - origin.y) / fit)
                                                                   insertImageLayer(image, imageScale: imageScale ?? scale,
                                                                                    center: point)
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
                        let hit = document.objects.last { object in
                            // Image layers hit-test their rotated outline (3.3.3).
                            object.kind == .image
                                ? AnnotationTransformGeometry.contains(point, rect: object.rect,
                                                                       rotation: object.resolvedRotation, tolerance: 4)
                                : object.rect.insetBy(dx: -4, dy: -4).contains(point)
                        }
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

                if tool == .eraser {
                    eraseStep(to: current)
                    return
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
                                         style: style,
                                         // 3.3.3: lines and arrows keep the drag direction.
                                         points: tool == .line || tool == .arrow ? [point, current] : [])
            }
            .onEnded { value in
                defer { dragStart = nil; activeHandle = nil; moveOriginals = []; moveHasChanged = false }
                if cropMode {
                    return
                }
                if tool == .move { return }
                if tool == .eraser {
                    if eraserLast == nil { eraseStep(to: value.location.scaled(by: 1 / fit)) }
                    finishEraserStroke()
                    return
                }
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
                // Freehand strokes and (3.3.3) line/arrow ends follow the rect.
                if original.kind.isFreehand || ((original.kind == .line || original.kind == .arrow) && original.points.count == 2) {
                    updated.points = original.points.map { point in
                        CGPoint(x: updated.rect.minX + (point.x - original.rect.minX) * updated.rect.width / max(1, original.rect.width),
                                y: updated.rect.minY + (point.y - original.rect.minY) * updated.rect.height / max(1, original.rect.height))
                    }
                }
                // 3.3.3: a text box's height follows its wrapped lines.
                document.update(fittedText(updated))
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
            object = fittedText(object)
            document.add(object)
            selectedID = object.id
            // Type straight into the properties bar's text field.
            DispatchQueue.main.async { textFieldFocused = true }
        } else {
            var object = AnnotationObject(kind: .counter,
                                          rect: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28),
                                          style: style, text: (style.counterStyle ?? .numbers).format(counterValue))
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
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            Text("Tool Options").font(AOMFont.headline).foregroundStyle(AOMColor.text)
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
                        Toggle("Bold", isOn: Binding(get: { style.resolvedFontWeight.isBold },
                                                     set: { style.fontWeight = nil; style.bold = $0; applyStyleToSelection() }))
                        Toggle("Italic", isOn: Binding(get: { style.italic ?? false }, set: { style.italic = $0; applyStyleToSelection() }))
                        Toggle("Outline", isOn: Binding(get: { style.textOutline ?? true }, set: { style.textOutline = $0; applyStyleToSelection() }))
                        if inspectedKind == .text {
                            Toggle("Shadow", isOn: Binding(get: { style.textShadow ?? false },
                                                           set: { style.textShadow = $0 ? true : nil; applyStyleToSelection() }))
                            textColorPicker("Text Color", keyPath: \.textColorHex, automatic: "Automatic")
                            textColorPicker("Background Color", keyPath: \.textBackgroundHex, automatic: "Main Color")
                                .disabled(style.resolvedTextBackground == .none)
                            textColorPicker("Outline Color", keyPath: \.textOutlineHex, automatic: "Dark (55 %)")
                                .disabled(!(style.textOutline ?? true))
                            Text("Outline Width").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            slider(value: Binding(get: { style.textOutlineWidth ?? 6 }, set: { style.textOutlineWidth = $0 }),
                                   range: 2...40, label: "\(Int(style.textOutlineWidth ?? 6)) %")
                                .disabled(!(style.textOutline ?? true))
                        }
                        if let id = selectedID, let object = document.objects.first(where: { $0.id == id }) {
                            TextField("Text", text: Binding(
                                get: { object.text },
                                set: { newValue in
                                    document.beginChange()
                                    var updated = object; updated.text = newValue; document.update(fittedText(updated))
                                }), axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                            .help("⌥↩ starts a new line")
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
        ScrollView(showsIndicators: false) {
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
        if object.kind == .counter, let val = Int(object.text) {
            object.text = (style.counterStyle ?? .numbers).format(val)
        }
        document.update(fittedText(object))
    }

    // MARK: - 3.3.3 text styles, eraser, image layers

    /// A text object grown (or shrunk) to show every line, its box padding and
    /// a bubble tail at its current width. Other kinds pass through.
    private func fittedText(_ object: AnnotationObject) -> AnnotationObject {
        guard object.kind == .text else { return object }
        var fitted = object
        fitted.rect.size.height = AnnotationTextRenderer.fittedHeight(text: object.text, style: object.style,
                                                                      width: object.rect.width)
        return fitted
    }

    /// The CleanShot-like text presets, with the current one checked.
    private var textStylePresetMenu: some View {
        let current = AnnotationTextStylePreset.matching(style)
        return Menu {
            ForEach(AnnotationTextStylePreset.allCases) { preset in
                Button {
                    style = preset.applied(to: style)
                    applyStyleToSelection()
                } label: {
                    if preset == current {
                        Label(preset.displayName, systemImage: "checkmark")
                    } else {
                        Text(preset.displayName)
                    }
                }
                .help(preset.help)
            }
        } label: {
            Text(current?.displayName ?? "Custom Style").frame(minWidth: 70)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Text style presets (Classic, Plain, Outline, Shadow, Label, Light Label, Pill, Speech Bubble)")
        .accessibilityLabel("Text style")
    }

    /// A palette colour (or the automatic choice) for one of the text-style colours.
    private func textColorPicker(_ title: String, keyPath: WritableKeyPath<AnnotationStyle, String?>,
                                 automatic: String) -> some View {
        let current = style[keyPath: keyPath] ?? ""
        let palette = AnnotationColor.palette.map { ($0.displayName, AnnotationColorLibrary.hex(of: $0.nsColor)) }
        return Picker(title, selection: Binding(
            get: { current },
            set: { style[keyPath: keyPath] = $0.isEmpty ? nil : $0; applyStyleToSelection() })) {
            Text(automatic).tag("")
            ForEach(palette, id: \.1) { name, hex in Text(name).tag(hex) }
            if !current.isEmpty, !palette.contains(where: { $0.1 == current }) {
                Text("Custom #\(String(current.prefix(6)))").tag(current)
            }
        }
    }

    /// One eraser step from the last pointer position to `point` (canvas
    /// points). The first change of a drag takes the undo snapshot.
    private func eraseStep(to point: CGPoint) {
        let from = eraserLast ?? point
        eraserLast = point
        let erased: Int
        switch eraserMode {
        case .object:
            erased = document.eraseObjects(from: from, to: point, radius: eraserSize, registersUndo: !eraserChanged)
        case .stroke:
            erased = document.eraseStrokes(from: from, to: point, radius: eraserSize, registersUndo: !eraserChanged)
        }
        if erased > 0 {
            eraserChanged = true
            eraserCount += erased
            if let id = selectedID, !document.objects.contains(where: { $0.id == id }) { selectedID = nil }
        }
    }

    private func finishEraserStroke() {
        if eraserCount > 0 {
            let noun = eraserMode == .object ? (eraserCount == 1 ? "object" : "objects")
                                             : (eraserCount == 1 ? "stroke" : "strokes")
            status = "Erased \(eraserCount) \(noun). ⌘Z restores."
        }
        eraserLast = nil
        eraserChanged = false
        eraserCount = 0
    }

    /// Sets an image layer's rotation (one undo step per change).
    private func setRotation(of id: UUID, radians: CGFloat) {
        guard var object = document.objects.first(where: { $0.id == id }) else { return }
        let value = AnnotationTransformGeometry.normalized(radians)
        guard value != object.resolvedRotation else { return }
        document.beginChange()
        object.rotation = value == 0 ? nil : value
        document.update(object)
    }

    private func arrangeSelection(_ arrangement: AnnotationArrangement) {
        guard selectedID != nil else { return }
        if document.arrange(selectedIDs, arrangement) {
            status = "\(arrangement.title)."
        }
    }

    /// Adds `image` as a free layer (centred, or at `center` in canvas points)
    /// and selects it with the Move tool.
    private func insertImageLayer(_ image: CGImage, imageScale: CGFloat, center: CGPoint? = nil) {
        guard let id = document.insertImageLayer(image, imageScale: imageScale, scale: scale, center: center,
                                                 style: style) else {
            status = "Could not add that image (too large?)."
            return
        }
        select([id])
        status = "Image layer added. Drag to move, corners resize (⇧ keeps the ratio), the round handle rotates."
    }

    private func insertImageLayerFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Insert"
        panel.message = "Choose an image to add as a layer you can move, resize and rotate."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let entry = AnnotationEditorController.entry(fromImageAt: url) else {
                status = "Could not add that image."
                return
            }
            insertImageLayer(entry.image, imageScale: entry.scale)
        }
    }

    /// The clipboard's image (or image file) as a layer.
    @discardableResult
    private func pasteImageLayer() -> Bool {
        guard let entry = AnnotationEditorController.entryFromPasteboard(.general) else {
            status = "No image on the clipboard."
            return false
        }
        insertImageLayer(entry.image, imageScale: entry.scale)
        return true
    }

    /// Selection outline, resize handles and a rotation handle that follow an
    /// image layer's rotation.
    private func imageLayerHandles(for object: AnnotationObject, fit: CGFloat) -> some View {
        let rect = object.rect.scaled(by: fit)
        let rotation = object.resolvedRotation
        let corners = AnnotationTransformGeometry.corners(of: rect, rotation: rotation)
        let anchors: [CGPoint] = [CGPoint(x: -1, y: -1), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 0),
                                  CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 1), CGPoint(x: -1, y: 0)]
        let top = AnnotationTransformGeometry.point(at: CGPoint(x: 0, y: -1), of: rect, rotation: rotation)
        let knob = CGPoint(x: top.x + sin(rotation) * 24, y: top.y - cos(rotation) * 24)
        return ZStack {
            Path { path in
                path.addLines(corners)
                path.closeSubpath()
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
            Path { path in
                path.move(to: top)
                path.addLine(to: knob)
            }
            .stroke(Color.accentColor, lineWidth: 1)
            .allowsHitTesting(false)
            ForEach(anchors.indices, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(AnnotationTransformGeometry.point(at: anchors[index], of: rect, rotation: rotation))
                    .highPriorityGesture(imageResizeGesture(anchor: anchors[index], object: object, fit: fit))
                    .help("Resize (⇧ keeps the aspect ratio)")
            }
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .position(knob)
                .highPriorityGesture(imageRotateGesture(object: object, fit: fit))
                .help("Rotate (⇧ snaps to 15°)")
                .accessibilityLabel("Rotate image layer")
        }
    }

    private func imageResizeGesture(anchor: CGPoint, object: AnnotationObject, fit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("annotationCanvas"))
            .onChanged { value in
                if resizeOriginal == nil { resizeOriginal = object; document.beginChange() }
                guard let original = resizeOriginal else { return }
                var updated = original
                updated.rect = AnnotationTransformGeometry.resize(
                    original.rect, rotation: original.resolvedRotation, anchor: anchor,
                    to: value.location.scaled(by: 1 / fit), keepAspect: NSEvent.modifierFlags.contains(.shift))
                document.update(updated)
            }
            .onEnded { _ in resizeOriginal = nil }
    }

    private func imageRotateGesture(object: AnnotationObject, fit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("annotationCanvas"))
            .onChanged { value in
                if resizeOriginal == nil { resizeOriginal = object; document.beginChange() }
                guard let original = resizeOriginal else { return }
                var updated = original
                let angle = AnnotationTransformGeometry.rotation(
                    center: CGPoint(x: original.rect.midX, y: original.rect.midY),
                    pointer: value.location.scaled(by: 1 / fit), snap: NSEvent.modifierFlags.contains(.shift))
                updated.rotation = angle == 0 ? nil : angle
                document.update(updated)
            }
            .onEnded { _ in resizeOriginal = nil }
    }

    // MARK: - Output

    private func renderedImage() -> CGImage? {
        document.render(scale: scale)
    }

    /// F-04C: the editor's own encode/write queue. `ScreenCaptureService.writeToDiskAsync`
    /// always derives the file name with `CaptureNaming.defaultName(for:)`, which
    /// would drop the editor's "… Edited" suffix. The service's synchronous
    /// `writeToDisk(_:fileName:)` keeps that name, and `ScreenCaptureService` is
    /// not main-actor isolated, so it is run here off the main thread. This is the
    /// same encode/write work `writeToDiskAsync` performs on its private queue.
    private static let exportQueue = DispatchQueue(label: "com.kyw.allofmacos.annotation-export",
                                                   qos: .userInitiated)

    /// Encodes and writes a named export on `exportQueue`, never on the main actor.
    private func writeEditedToDisk(_ result: CaptureResult, fileName: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Self.exportQueue.async {
                continuation.resume(with: Result<URL, Error> {
                    try ScreenCaptureService.shared.writeToDisk(result, fileName: fileName)
                })
            }
        }
    }

    /// Encodes to `format` and atomically writes to a user-chosen Save As path,
    /// off the main actor.
    private func encodeAndWrite(_ result: CaptureResult, format: CaptureFormat, to url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.exportQueue.async {
                continuation.resume(with: Result<Void, Error> {
                    let data = try ScreenCaptureService.shared.encode(result, format: format)
                    try data.write(to: url, options: .atomic)
                })
            }
        }
    }

    private func copyToClipboard(completionStatus: String? = nil) {
        guard let image = renderedImage() else { return }
        let result = CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                                   windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
        // F-04C: encode the full-resolution image off the main thread and only
        // report success once the pasteboard actually holds the pixels.
        Task { @MainActor in
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(result)
                status = completionStatus ?? "Copied to clipboard."
            } catch {
                status = "Copy failed: \(error.localizedDescription)"
            }
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
            // F-04C: the copy is asynchronous, so hand it the final status text
            // instead of overwriting it right after the call returns.
            copyToClipboard(completionStatus: "No object selected — copied the whole image (⇧⌘C).")
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
            // 3.3.3: an image (or image file) on the clipboard pastes as a free layer.
            if let entry = AnnotationEditorController.entryFromPasteboard(.general) {
                insertImageLayer(entry.image, imageScale: entry.scale)
                return true
            }
            status = "Nothing to paste. Copy an annotation object (⌘C) or an image first."
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
        // F-04C: remember the exact document state this `image` was rendered from.
        // The write below is asynchronous, so a later edit must not be stamped as
        // saved just because the old snapshot finished encoding.
        let exportedState = AnnotationSavedState(document)
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
                    // F-04C: the full-resolution encode and the atomic write run
                    // on the export queue, never on the main actor.
                    try await encodeAndWrite(result, format: format, to: url)
                    if markExported(exportedState) {
                        status = "Saved \(url.lastPathComponent). Newer changes are not saved yet."
                    } else {
                        status = "Saved \(url.lastPathComponent)."
                    }
                } catch {
                    status = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// ⌘S: a new "… Edited" file in the export location. Source files are
    /// never overwritten.
    ///
    /// F-04C: the encode/write runs off the main thread. The Bool says whether a
    /// save was started, not whether it finished; the status (and, for a commit,
    /// the window close) is applied from the completion.
    @discardableResult
    private func saveToExportLocation() -> Bool {
        guard !exportInFlight else { return false }
        guard let image = renderedImage() else { status = "Nothing to save."; return false }
        // F-04C: snapshot the document state this export actually writes. The
        // encode/write below is asynchronous; edits made while it runs must stay
        // dirty instead of being marked saved by a completion-time `markSaved()`.
        let exportedState = AnnotationSavedState(document)
        let result = CaptureResult(image: image,
                                   globalRect: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
                                                      height: CGFloat(image.height) / scale),
                                   scale: scale, kind: capture.kind,
                                   windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
        // Keep the editor's own " Edited" suffix; `writeToDiskAsync` cannot take
        // a file name, so `writeEditedToDisk` preserves the exact result name.
        let name = CaptureNaming.defaultName(for: result) + " Edited"
        exportInFlight = true
        Task { @MainActor in
            defer { exportInFlight = false }
            do {
                let url = try await writeEditedToDisk(result, fileName: name)
                if markExported(exportedState) {
                    // The file holds the pre-await snapshot; the user kept editing.
                    // Keep the newer edits dirty and leave the window open so they
                    // are not silently dropped by a `closeAfterExport` close.
                    closeAfterExport = false
                    status = "Saved \(url.lastPathComponent). Newer changes are not saved yet."
                } else {
                    status = "Saved \(url.lastPathComponent)."
                    if closeAfterExport {
                        closeAfterExport = false
                        session?.close()
                    }
                }
            } catch {
                closeAfterExport = false
                status = "Save failed: \(error.localizedDescription)"
            }
        }
        return true
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
        // F-04C: the export is asynchronous, so return false to keep the
        // synchronous Done / close-Save path from closing the window before the
        // file is written. `saveToExportLocation` closes it from its completion
        // on success, and on failure the editor stays open with the error.
        closeAfterExport = true
        if exportInFlight { return false }
        if !saveToExportLocation() {
            closeAfterExport = false
            return false
        }
        return false
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
                    let (start, end) = object.lineEndpoints
                    path.move(to: start.scaled(by: fit))
                    path.addLine(to: end.scaled(by: fit))
                }.stroke(color, lineWidth: object.style.thickness * fit)
            case .arrow:
                // 3.3.3: from where the drag started to where it is, like the export.
                Path { path in
                    let (start, end) = object.lineEndpoints
                    path.move(to: start.scaled(by: fit))
                    path.addLine(to: end.scaled(by: fit))
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
                if object.style.spotlightShape == .ellipse {
                    Ellipse().path(in: rect).stroke(Color.white, lineWidth: 1)
                } else {
                    Rectangle().path(in: rect).stroke(Color.white, lineWidth: 1)
                }
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
        // CleanShot highlights the matched words, not the whole recognized line.
        return (request.results ?? []).flatMap { observation -> [CGRect] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return wordBoxes(of: needle, in: candidate.string) { range in
                (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
            }.map { annotationRect(from: $0, pixelSize: pixelSize, scale: scale) }
             .filter { $0.width > 0 && $0.height > 0 }
        }.prefix(100).map { $0 }
    }

    /// Every case- and accent-insensitive occurrence of `needle`, boxed by
    /// `box(range)` (Vision's per-range box, or the whole line as a fallback).
    static func wordBoxes(of needle: String, in text: String, box: (Range<String.Index>) -> CGRect) -> [CGRect] {
        var boxes: [CGRect] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            boxes.append(box(range))
            start = range.upperBound
        }
        return boxes
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
