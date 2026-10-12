import AppKit
import SwiftUI
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
        let width = min(1440, max(1180, capture.pixelSize.width / 2 + 320))
        let height = min(900, max(640, capture.pixelSize.height / 2 + 140))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Annotate — \(capture.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1120, height: 560)
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

/// An uninterrupted canvas with compact tool capsules and contextual popovers.
private struct AnnotationEditorView: View {
    let capture: CaptureHistoryEntry
    let fileURL: URL?

    @State private var document: AnnotationDocument
    @State private var tool: AnnotationKind = .arrow
    @State private var style = AnnotationStyle()
    @State private var selectedID: UUID?
    @State private var counterValue = 1
    @State private var cropMode = false
    @State private var showingResize = false
    @State private var cropRect: CGRect?
    @State private var status: String?

    @State private var colorPopover = false
    @State private var optionsPopover = false
    @State private var backgroundPopover = false
    @State private var layersPopover = false
    @State private var canvasLocked = false
    @State private var zoom: CGFloat? = nil
    @State private var moveOriginal: AnnotationObject?
    @State private var resizeOriginal: AnnotationObject?
    @State private var cropHandleOriginal: CGRect?
    @State private var cropAspect: CGFloat = 0
    @State private var snapToEdges = true

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
            if cropMode { cropToolbar } else { toolbar }
            Divider()
            canvas
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
    }

    // MARK: - Toolbar

    private let mainTools: [AnnotationKind] = [
        .move, .rectangle, .filledRectangle, .ellipse, .line, .arrow,
        .text, .pixelate, .redact, .highlighter, .counter, .draw, .drawHighlight
    ]

    private var toolbar: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 32)
            capsuleButton("crop", help: "Crop (C)", active: cropMode) { selectTool(.crop) }
                .keyboardShortcut("c", modifiers: [])
            capsuleButton("arrow.up.left.and.arrow.down.right", help: "Resize Image…") {
                showingResize = true
            }
            capsuleButton("photo.badge.plus", help: "Add Screenshot…") { addScreenshot() }
            capsuleButton("photo", help: "Background", active: backgroundPopover) { if !backgroundPopover { document.beginChange() }; backgroundPopover.toggle() }
                .popover(isPresented: $backgroundPopover) { backgroundOptions.padding(18).frame(width: 270) }

            HStack(spacing: 0) {
                ForEach(mainTools) { kind in
                    toolButton(kind)
                    if kind != mainTools.last {
                        Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1, height: 16)
                    }
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.065), in: Capsule())

            Button { colorPopover.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: style.color.nsColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                        .frame(width: 18, height: 18)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            .buttonStyle(.plain).help("Color").accessibilityLabel("Color")
            .popover(isPresented: $colorPopover) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Color").font(.headline)
                    ColorSwatchRow(selection: $style.color).onChange(of: style.color) { _, _ in applyStyleToSelection() }
                    section("Opacity") { slider(value: $style.opacity, range: 0.1...1, label: "\(Int(style.opacity * 100))%") }
                }.padding(18).frame(width: 230)
            }
            Button { optionsPopover.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.diagonal").font(.system(size: 18, weight: .heavy))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 10).frame(height: 32)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            .buttonStyle(.plain).help("Thickness and Tool Options").accessibilityLabel("Tool Options")
            .popover(isPresented: $optionsPopover) { toolOptions.padding(18).frame(width: 270) }
            capsuleButton(canvasLocked ? "lock.fill" : "lock.open.fill", help: "Lock Canvas", active: canvasLocked) { canvasLocked.toggle() }

            Menu {
                Button("Undo") { document.undo() }.disabled(!document.canUndo).keyboardShortcut("z", modifiers: .command)
                Button("Redo") { document.redo() }.disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Layers…") { layersPopover = true }
                Button("Spotlight") { selectTool(.spotlight) }
                Button("Delete Selected") { deleteSelection() }.disabled(selectedID == nil).keyboardShortcut(.delete, modifiers: [])
                Divider()
                Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                Button("Actual Size") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 30) }
            .menuStyle(.borderlessButton).fixedSize().help("More Options")
            .popover(isPresented: $layersPopover) { layers.padding(16).frame(width: 280) }
            Spacer(minLength: 0)
            Button { saveAs() } label: {
                Text("Save as…").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).padding(.horizontal, 15).frame(height: 32)
                    .background(Color.accentColor, in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12).frame(height: 54)
    }

    private func capsuleButton(_ symbol: String, help: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 38, height: 32)
                .background(active ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
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

    private func toolButton(_ kind: AnnotationKind) -> some View {
        Button { selectTool(kind) } label: {
            Image(systemName: toolSymbol(kind))
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 33, height: 29)
                .background(tool == kind ? Color.accentColor : Color.clear, in: Capsule())
                .foregroundStyle(tool == kind ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(kind.displayName).accessibilityLabel(kind.displayName)
    }

    private func toolSymbol(_ kind: AnnotationKind) -> String {
        switch kind {
        case .move: return "cursorarrow"
        case .draw: return "pencil.tip"
        case .drawHighlight: return "highlighter"
        case .highlighter: return "rectangle.inset.filled"
        case .counter: return "1.circle.fill"
        default: return kind.iconName
        }
    }

    private var footer: some View {
        ZStack {
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
                .help("Zoom")
                if cropMode {
                    Toggle("Snap to edges", isOn: $snapToEdges).toggleStyle(.checkbox).font(.system(size: 12))
                    Text("Hold Command ⌘ to disable snapping.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !cropMode {
                AnnotationShareButton(image: renderedImage(), scale: scale).frame(width: 38, height: 32)
                capsuleButton("pin.fill", help: "Pin to Screen") { pin() }
                capsuleButton("doc.on.doc.fill", help: "Copy (⌘C)") { copyToClipboard() }.keyboardShortcut("c", modifiers: .command)
                }
            }
            if !cropMode {
            Text("☰   Drag Me   ☰")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 17).frame(height: 34)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .onDrag { dragProvider() }
                .help("Drag the edited image to another app")
            }
        }
        .padding(.horizontal, 14).frame(height: 54)
    }

    private var cropToolbar: some View {
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
        }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 54)
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

    private var canvas: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: CGFloat(document.croppedImage.width) / scale,
                                   height: CGFloat(document.croppedImage.height) / scale)
            let canvasSize = document.canvasSize(scale: scale)
            let fit = zoom ?? fitScale(for: canvasSize, in: geometry.size)
            let drawn = canvasSize.scaled(by: fit)
            let padding = document.background.isExpanded ? document.background.padding * fit : 0
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let rendered = document.render(scale: scale) {
                        Image(decorative: rendered, scale: scale).resizable()
                            .frame(width: drawn.width, height: drawn.height)
                    }
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(document.objects) { object in
                            if object.id == selectedID, tool == .move {
                                selectionHandles(for: object, fit: fit)
                            }
                        }
                        if let draft { DraftOverlay(object: draft, fit: fit, scale: scale) }
                        if cropMode, let cropRect { cropOverlay(cropRect: cropRect, fit: fit, imageSize: imageSize) }
                    }
                    .frame(width: imageSize.width * fit, height: imageSize.height * fit)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: "annotationCanvas")
                    .gesture(canvasGesture(fit: fit, imageSize: imageSize))
                    .allowsHitTesting(!canvasLocked)
                    .offset(x: padding, y: padding)
                }
                .frame(width: drawn.width, height: drawn.height)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 3)
                .padding(24)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
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
                    // Clicking picks the topmost object under the pointer.
                    if dragStart == nil {
                        dragStart = point
                        moveOriginal = document.objects.last { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }
                        selectedID = moveOriginal?.id
                        if let original = moveOriginal { style = original.style; document.beginChange() }
                    }
                    if let original = moveOriginal {
                        let dx = current.x - point.x, dy = current.y - point.y
                        var updated = original
                        updated.rect = original.rect.offsetBy(dx: dx, dy: dy)
                        updated.points = original.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                        document.update(updated)
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
                defer { dragStart = nil; activeHandle = nil; moveOriginal = nil }
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
            optionsPopover = true
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

    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool Options").font(.headline)
            section("Thickness") {
                slider(value: $style.thickness, range: 1...20, label: "\(Int(style.thickness)) pt")
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

                if tool == .text || tool == .counter || document.objects.first(where: { $0.id == selectedID })?.kind == .text {
                    section("Text") {
                        slider(value: $style.fontSize, range: 10...96, label: "\(Int(style.fontSize)) pt")
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

        }
    }

    private var backgroundOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                            .onTapGesture { tool = .move; selectedID = object.id; style = object.style }
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

    private func addScreenshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add Screenshot"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            if document.appendScreenshot(image, scale: scale) {
                selectedID = nil
                zoom = nil
                status = "Screenshot added below the current image."
            } else { status = "Could not add that image." }
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

    private func deleteSelection() {
        guard let id = selectedID else { return }
        document.remove(id)
        selectedID = nil
    }

    private func saveAs() {
        guard let image = renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [CaptureSettings.format.contentType]
        panel.nameFieldStringValue = CaptureNaming.defaultName(
            for: CaptureResult(image: image, globalRect: .zero, scale: scale, kind: capture.kind,
                               windowTitle: capture.windowTitle, capturedAt: capture.capturedAt))
            + " Edited." + CaptureSettings.format.fileExtension
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
            case .redact:
                // Preview matches the opaque export: no semi-transparent "privacy" mask.
                Rectangle().path(in: rect).fill(Color.black)
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
                Image(systemName: keepAspect ? "link" : "link.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField("Height", value: heightEntry, format: .number)
                    .accessibilityLabel("Resize height")
                Picker("Units", selection: $usePercent) {
                    Text("pixels").tag(false)
                    Text("percent").tag(true)
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
            Text("Flattening merges annotations into the image. Undo restores the original layers.")
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
