import AppKit
import SwiftUI

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

    func open(capture: CaptureHistoryEntry, url: URL?) {
        let id = UUID()
        let window = AnnotationEditorWindow(capture: capture, url: url)
        window.onClose = { [weak self] in self?.editors.removeValue(forKey: id) }
        editors[id] = window
        window.present()
    }

    /// Opens the most recent capture, for "Annotate Last Screenshot".
    func openMostRecent() {
        guard let entry = CaptureHistory.shared.mostRecent else {
            GestureHUD.shared.show(title: "Nothing to Annotate", detail: "Take a capture first.")
            return
        }
        open(capture: entry, url: entry.fileURL)
    }
}

private final class AnnotationEditorWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let capture: CaptureHistoryEntry

    init(capture: CaptureHistoryEntry, url: URL?) {
        self.capture = capture
        let width = min(1360, max(920, capture.pixelSize.width / 2 + 320))
        let height = min(900, max(640, capture.pixelSize.height / 2 + 140))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Annotate — \(capture.displayName)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AnnotationEditorView(capture: capture, fileURL: url))
        window.delegate = self
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

/// The editor: a toolbar on top, the canvas in the middle, and a contextual
/// inspector on the right that changes with the selected tool.
private struct AnnotationEditorView: View {
    let capture: CaptureHistoryEntry
    let fileURL: URL?

    @State private var document: AnnotationDocument
    @State private var tool: AnnotationKind = .arrow
    @State private var style = AnnotationStyle()
    @State private var selectedID: UUID?
    @State private var counterValue = 1
    @State private var cropMode = false
    @State private var cropRect: CGRect?
    @State private var status: String?

    /// The draft object currently being dragged out.
    @State private var draft: AnnotationObject?
    @State private var dragStart: CGPoint?
    /// Which handle of a selected object is being dragged, if any.
    @State private var activeHandle: ResizeHandle?

    init(capture: CaptureHistoryEntry, fileURL: URL?) {
        self.capture = capture
        self.fileURL = fileURL
        _document = State(initialValue: AnnotationDocument(baseImage: capture.image))
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
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector
                    .frame(width: 260)
            }
        }
        .background(.background)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Group 1: Select & Crop
            HStack(spacing: 2) {
                toolButton(.move)
                toolButton(.crop)
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            // Group 2: Shapes & Lines
            HStack(spacing: 2) {
                toolButton(.arrow)
                toolButton(.line)
                toolButton(.rectangle)
                toolButton(.filledRectangle)
                toolButton(.ellipse)
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            // Group 3: Text & Markings
            HStack(spacing: 2) {
                toolButton(.text)
                toolButton(.highlighter)
                toolButton(.counter)
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            // Group 4: Drawing
            HStack(spacing: 2) {
                toolButton(.draw)
                toolButton(.drawHighlight)
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            // Group 5: Privacy
            HStack(spacing: 2) {
                toolButton(.pixelate)
                toolButton(.spotlight)
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            Spacer()

            // Undo / Redo
            HStack(spacing: 2) {
                Button { document.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain).disabled(!document.canUndo).help("Undo (⌘Z)").keyboardShortcut("z", modifiers: .command)

                Button { document.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain).disabled(!document.canRedo).help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding(2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            Divider().frame(height: 18)

            // Actions: Save, Copy, Pin
            HStack(spacing: 4) {
                Button { saveTo(fileURL) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help("Save to Disk (⌘S)").keyboardShortcut("s", modifiers: .command)

                Button { copyToClipboard() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help("Copy to Clipboard (⌘C)").keyboardShortcut("c", modifiers: .command)

                Button { pin() } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help("Pin to Screen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func toolButton(_ kind: AnnotationKind) -> some View {
        Button {
            tool = kind
            cropMode = (kind == .crop)
            if kind != .crop { cropRect = nil }
            if kind == .move { selectedID = document.objects.last?.id }
            else { selectedID = nil }
        } label: {
            Image(systemName: kind.iconName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .background(tool == kind ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(tool == kind ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.displayName)
        .accessibilityLabel(kind.displayName)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: CGFloat(document.croppedImage.width) / scale,
                                   height: CGFloat(document.croppedImage.height) / scale)
            let fit = fitScale(for: imageSize, in: geometry.size)
            let drawn = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                ZStack {
                    // The rendered document is what the user sees, so what they
                    // export is exactly what they previewed.
                    if let rendered = document.render(scale: scale) {
                        Image(decorative: rendered, scale: scale)
                            .resizable()
                            .frame(width: drawn.width, height: drawn.height)
                    }

                    // Selection handles and the in-progress draft sit on top as
                    // vector overlays rather than being baked into the render.
                    ForEach(document.objects) { object in
                        if object.id == selectedID, tool == .move {
                            selectionHandles(for: object, fit: fit)
                        }
                    }
                    if let draft {
                        DraftOverlay(object: draft, fit: fit, scale: scale)
                    }
                    if cropMode, let cropRect {
                        cropOverlay(cropRect: cropRect, fit: fit, imageSize: imageSize)
                    }
                }
                .frame(width: drawn.width, height: drawn.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .gesture(canvasGesture(fit: fit, imageSize: imageSize))
                .onContinuousHover { phase in
                    if case .active = phase {} else { dragStart = nil }
                }
            }
            .overlay(alignment: .bottom) {
                if let status {
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The scale that fits the image inside the available space.
    private func fitScale(for imageSize: CGSize, in available: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(1, min(available.width / imageSize.width, available.height / imageSize.height))
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
                    .gesture(handleGesture(handle, object: object, fit: fit))
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
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle().path(in: rect).stroke(Color.white, lineWidth: 1)
            Rectangle().path(in: rect.insetBy(dx: -1, dy: -1))
                .stroke(Color.black.opacity(0.4), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func canvasGesture(fit: CGFloat, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.startLocation.scaled(by: 1 / fit)
                let current = value.location.scaled(by: 1 / fit)

                if cropMode {
                    cropRect = CGRect(x: min(point.x, current.x), y: min(point.y, current.y),
                                      width: abs(current.x - point.x), height: abs(current.y - point.y))
                    return
                }

                if tool == .move {
                    // Clicking picks the topmost object under the pointer.
                    if dragStart == nil {
                        dragStart = point
                        selectedID = document.objects.last { $0.rect.contains(point) }?.id
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
                defer { dragStart = nil; activeHandle = nil }
                if cropMode {
                    if let cropRect, cropRect.width >= 8, cropRect.height >= 8 {
                        applyCrop(cropRect)
                    } else { self.cropRect = nil }
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
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location.scaled(by: 1 / fit)
                var updated = object
                updated.rect = handle.resize(object.rect, to: point)
                document.update(updated)
            }
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
        } else {
            var object = AnnotationObject(kind: .counter,
                                          rect: CGRect(x: point.x, y: point.y, width: 30, height: 30),
                                          style: style, text: "\(counterValue)")
            object.style.color = style.color
            document.add(object)
            counterValue += 1
            selectedID = object.id
        }
    }

    private func applyCrop(_ rect: CGRect) {
        // Convert the canvas-space crop into image pixels for the document.
        let base = document.croppedImage
        let existing = document.cropRect ?? CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height))
        let factor = CGFloat(capture.image.width) / capture.pointSize.width
        let scaled = CGRect(x: existing.minX + rect.minX * factor,
                            y: existing.minY + rect.minY * factor,
                            width: rect.width * factor,
                            height: rect.height * factor)
        document.setCrop(scaled.integral)
        cropRect = nil
        cropMode = false
        tool = .move
        // Object coordinates are relative to the cropped canvas, so a crop would
        // otherwise leave every existing annotation pointing at the wrong place.
        status = "Cropped. Existing annotations were kept in image coordinates."
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(AnnotationColor.allCases) { choice in
                            Button {
                                style.color = choice
                                applyStyleToSelection()
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: choice.nsColor))
                                    .frame(height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .stroke(style.color == choice ? Color.accentColor : Color.primary.opacity(0.15),
                                                lineWidth: style.color == choice ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(choice.displayName)
                            .accessibilityLabel(choice.displayName)
                        }
                    }
                }

                if tool.isShape && !tool.isFreehand || tool == .draw || tool == .drawHighlight {
                    section("Thickness") {
                        slider(value: $style.thickness, range: 1...20, label: "\(Int(style.thickness)) pt")
                    }
                }

                if tool == .arrow {
                    section("Arrow Style") {
                        Picker("", selection: $style.arrowStyle) {
                            ForEach(ArrowStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: style.arrowStyle) { _, _ in applyStyleToSelection() }
                    }
                }

                if tool == .text || tool == .counter {
                    section("Text") {
                        slider(value: $style.fontSize, range: 10...96, label: "\(Int(style.fontSize)) pt")
                        if let id = selectedID, let object = document.objects.first(where: { $0.id == id }) {
                            TextField("Text", text: Binding(
                                get: { object.text },
                                set: { newValue in
                                    var updated = object; updated.text = newValue; document.update(updated)
                                }))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if tool == .pixelate {
                    section("Pixel Size") {
                        slider(value: $style.pixelBlockSize, range: 4...48, label: "\(Int(style.pixelBlockSize)) px")
                    }
                }

                if tool == .rectangle || tool == .filledRectangle {
                    section("Corner Radius") {
                        slider(value: $style.cornerRadius, range: 0...40, label: "\(Int(style.cornerRadius)) pt")
                    }
                }

                section("Opacity") {
                    slider(value: $style.opacity, range: 0.1...1, label: "\(Int(style.opacity * 100))%")
                }

                section("Background") {
                    Picker("", selection: $document.background.kind) {
                        ForEach(AnnotationBackground.Kind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    slider(value: Binding(get: { document.background.padding },
                                          set: { document.background.padding = $0 }),
                           range: 0...160, label: "Padding \(Int(document.background.padding)) pt")
                    if document.background.kind == .gradient {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From").font(.caption).foregroundStyle(.secondary)
                            ColorSwatchRow(selection: $document.background.gradientStart)
                            Text("To").font(.caption).foregroundStyle(.secondary)
                            ColorSwatchRow(selection: $document.background.gradientEnd)
                        }
                    } else if document.background.kind == .solid {
                        ColorSwatchRow(selection: $document.background.color)
                    }
                }

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
                            .onTapGesture { selectedID = object.id }
                            .background(selectedID == object.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                }
            }
            .padding(14)
        }
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

    private func saveTo(_ url: URL?) {
        guard let image = renderedImage() else { return }
        let result = CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                                   windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
        if let url {
            do {
                let data = try ScreenCaptureService.shared.encode(result)
                try data.write(to: url, options: .atomic)
                status = "Saved \(url.lastPathComponent)."
                return
            } catch {
                status = "Save failed: \(error.localizedDescription)"
                return
            }
        }
        saveAs()
    }

    private func saveAs() {
        guard let image = renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [CaptureSettings.format.contentType]
        panel.nameFieldStringValue = CaptureNaming.defaultName(
            for: CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                               windowTitle: capture.windowTitle, capturedAt: capture.capturedAt))
            + "." + CaptureSettings.format.fileExtension
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let result = CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                                           windowTitle: capture.windowTitle, capturedAt: capture.capturedAt)
                do {
                    let data = try ScreenCaptureService.shared.encode(result)
                    try data.write(to: url, options: .atomic)
                    status = "Saved \(url.lastPathComponent)."
                } catch {
                    status = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pin() {
        guard let image = renderedImage() else { return }
        let entry = CaptureHistoryEntry(image: image, kind: capture.kind, capturedAt: capture.capturedAt,
                                        windowTitle: capture.windowTitle, fileURL: fileURL)
        PinnedScreenshotController.shared.pin(entry: entry, url: fileURL)
        status = "Pinned to screen."
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
        let color = Color(nsColor: object.style.color.nsColor)
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
