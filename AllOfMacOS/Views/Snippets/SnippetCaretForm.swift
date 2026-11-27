import AppKit
import ApplicationServices
import SwiftUI

// 7.22 (DeepSeek 7.21 report §4.7, TextExpander's fill-in window): a
// snippet typed by its abbreviation asks its questions in a small panel at
// the text cursor instead of in the launcher. The panel never activates AOM,
// so the document keeps focus and the app stays in front; every question is
// on one form (Tab moves, ↩ inserts, Esc leaves the text as typed).

/// Where the panel goes: the caret's rectangle when the app reports it
/// (AX bounds of the selected range), else near the pointer. Pure helpers
/// for the geometry so tests can check the clamping.
enum SnippetCaretGeometry {
    /// The focused text caret in AppKit global coordinates (origin bottom-
    /// left), or nil when the app doesn't say.
    @MainActor
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.origin != .zero || rect.size != .zero else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return flipped(rect, primaryHeight: primaryHeight)
    }

    /// AX (top-left origin) → AppKit (bottom-left origin).
    nonisolated static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(1, rect.width), height: max(1, rect.height))
    }

    /// The panel's frame: below the caret (above it when there's no room),
    /// kept inside `visible` (TextExpander's fitToWorkArea).
    nonisolated static func frame(size: CGSize, caret: CGRect, visible: CGRect, gap: CGFloat = 6) -> CGRect {
        var origin = CGPoint(x: caret.minX, y: caret.minY - gap - size.height)
        if origin.y < visible.minY { origin.y = caret.maxY + gap }
        origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        origin.y = min(max(origin.y, visible.minY + gap), visible.maxY - size.height - gap)
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
final class SnippetCaretForm: ObservableObject {
    static let shared = SnippetCaretForm()

    /// 7.22: on by default; off asks in the launcher as before.
    nonisolated static let defaultsKey = "AOMSnippetFormAtCaret"
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    struct Request {
        var text: String
        var syntax: Int?
        var abbreviation: String
        var fields: [SnippetField]
        var erase: Int
        var target: NSRunningApplication?
        var typed: String
    }

    @Published var values: [String: String] = [:]
    @Published private(set) var request: Request?
    private var panel: NSPanel?
    private var keyMonitor: Any?

    /// Opens the form for a typed abbreviation. The caret is asked for at
    /// once and again after 200 ms (some apps update it late); the screen
    /// centre is the fallback.
    func present(_ request: Request) {
        close()
        self.request = request
        values = Self.initialValues(request.fields)
        let panel = SnippetCaretPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 120))
        let host = NSHostingView(rootView: SnippetCaretFormView(form: self))
        panel.contentView = host
        self.panel = panel
        let size = host.fittingSize
        place(size: CGSize(width: max(300, size.width), height: size.height), caret: SnippetCaretGeometry.caretRect())
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeys()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.panel === panel, let caret = SnippetCaretGeometry.caretRect() else { return }
            self.place(size: panel.frame.size, caret: caret)
        }
    }

    nonisolated static func initialValues(_ fields: [SnippetField]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            switch field.kind {
            case .text: values[field.name] = ""
            case .choice(let options, let index): values[field.name] = options.indices.contains(index) ? options[index] : (options.first ?? "")
            case .optional(let on): values[field.name] = on ? SnippetField.on : SnippetField.off
            }
        }
        return values
    }

    private func place(size: CGSize, caret: CGRect?) {
        guard let panel else { return }
        let anchor = caret ?? {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            return CGRect(x: visible.midX - size.width / 2, y: visible.midY + size.height / 2, width: 1, height: 1)
        }()
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let frame = SnippetCaretGeometry.frame(size: size, caret: anchor, visible: screen?.visibleFrame ?? anchor)
        panel.setFrame(frame, display: true)
    }

    /// The text the snippet would insert with the answers so far.
    var preview: String {
        guard let request, case .success(let render) = SnippetTemplate.render(
            text: request.text, syntax: request.syntax, context: .init(arguments: values)) else { return "" }
        return render.text
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil                            // Esc
            case 36, 76:                                                  // ↩ / Enter
                if event.modifierFlags.contains(.shift) { return event }  // ⇧↩: a new line in the field
                self.submit(); return nil
            default: return event
            }
        }
    }

    func cancel() {
        close()
    }

    /// Inserts the snippet in the app it was typed in: the abbreviation is
    /// erased first, and put back if the text can't go in.
    func submit() {
        guard let request else { close(); return }
        let values = self.values
        close()
        guard case .success(let render) = SnippetTemplate.render(text: request.text, syntax: request.syntax,
                                                                 context: .init(arguments: values)) else {
            GestureHUD.shared.show(title: "Snippet Not Inserted", detail: "Its text has a mistake — fix it in Automation.")
            return
        }
        if let refusal = SnippetInserter.refusal(for: render) {
            GestureHUD.shared.show(title: "Snippet Not Inserted", detail: refusal)
            return
        }
        let target = request.target
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            GestureHUD.shared.show(title: "Snippet Not Inserted", detail: "The app you typed in isn't in front any more; the text is as you left it.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            TypedStringEngine.shared.erase(request.erase)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SnippetInserter.insert(render, into: target) { inserted, note in
                    if !inserted {
                        if !request.typed.isEmpty { ActionExecutor.typeReplacementText(request.typed) }
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(render.text, forType: .string)
                        GestureHUD.shared.show(title: "Snippet Copied", detail: (note ?? "Couldn't insert it") + " — press ⌘V.")
                    } else if let note {
                        GestureHUD.shared.show(title: "Snippet", detail: note)
                    }
                }
            }
        }
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        request = nil
    }
}

/// Floats over the document, takes keys, and never activates AOM.
final class SnippetCaretPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SnippetCaretFormView: View {
    @ObservedObject var form: SnippetCaretForm
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x1) {
                Image(systemName: "text.badge.plus").foregroundStyle(AOMColor.textSecondary)
                Text(form.request?.abbreviation ?? "Snippet").font(AOMFont.headline)
                Spacer(minLength: AOMSpace.x2)
                Text("↩ Insert · esc").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
            ForEach(Array((form.request?.fields ?? []).enumerated()), id: \.offset) { index, field in
                fieldRow(field, first: index == 0)
            }
            if !form.preview.isEmpty {
                Text(form.preview)
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Preview, \(form.preview)")
            }
        }
        .padding(AOMSpace.x3)
        .frame(width: 340)
        .background(AOMColor.overlaySurface)
    }

    @ViewBuilder
    private func fieldRow(_ field: SnippetField, first: Bool) -> some View {
        switch field.kind {
        case .text:
            TextField(field.name, text: binding(field.name))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: field.name)
                .onAppear { if first { focused = field.name } }
        case .choice(let options, _):
            Picker(field.name, selection: binding(field.name)) {
                ForEach(options, id: \.self) { Text($0.isEmpty ? "(nothing)" : $0).tag($0) }
            }
            .pickerStyle(.menu)
        case .optional:
            Toggle(field.name, isOn: Binding(
                get: { SnippetField.isOn(form.values[field.name], default: false) },
                set: { form.values[field.name] = $0 ? SnippetField.on : SnippetField.off }))
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { form.values[name] ?? "" }, set: { form.values[name] = $0 })
    }
}
