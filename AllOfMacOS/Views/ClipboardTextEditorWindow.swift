import AppKit
import SwiftUI

/// Presents text composition independently of the clipboard shelf. Non-text
/// naming dialogs retain their existing sheet presentation.
@MainActor
struct ClipboardTextEditorPresenter: NSViewRepresentable {
    @Binding var request: ClipboardEditorRequest?
    let store: ClipboardStore

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        let binding = $request
        context.coordinator.update(request: request, store: store) { binding.wrappedValue = nil }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.close() }

    private final class ClipboardTextPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: NSPanel?
        private var requestID: UUID?
        private var editor: ClipboardRichTextModel?
        private var onDismiss: (() -> Void)?

        func update(request: ClipboardEditorRequest?, store: ClipboardStore, dismiss: @escaping () -> Void) {
            guard let request, request.isTextEditor else { close(); return }
            guard requestID != request.id else { return }
            close()
            requestID = request.id
            onDismiss = dismiss
            let model = ClipboardRichTextModel(request: request, store: store)
            editor = model
            let size: NSSize
            if case .newText = request.operation { size = NSSize(width: 500, height: 360) }
            else { size = NSSize(width: 390, height: 316) }
            let window = ClipboardTextPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.sharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 350, height: 240)
            window.delegate = self
            let content = ClipboardRichTextEditor(model: model, request: request, store: store) { [weak self] in
                self?.finish()
            }
            window.contentView = NSHostingView(rootView: content)
            panel = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let editor, editor.hasChanges else { finish(); return false }
            let alert = NSAlert()
            alert.messageText = "Discard changes?"
            alert.informativeText = "Your changes to this clipboard item have not been saved."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard")
            alert.beginSheetModal(for: sender) { [weak self] response in
                if response == .alertSecondButtonReturn { self?.finish() }
            }
            return false
        }

        private func finish() {
            let callback = onDismiss
            close()
            callback?()
        }
        func close() {
            panel?.delegate = nil
            panel?.orderOut(nil)
            panel?.close()
            panel = nil
            requestID = nil
            editor = nil
            onDismiss = nil
        }
    }
}

@MainActor
final class ClipboardRichTextModel: NSObject, ObservableObject, NSTextViewDelegate {
    enum Formatting { case bold, italic, underline, strike }
    @Published private(set) var value: NSAttributedString
    @Published private(set) var bold = false
    @Published private(set) var italic = false
    @Published private(set) var underline = false
    @Published private(set) var strike = false
    let original: NSAttributedString
    weak var textView: NSTextView?

    init(request: ClipboardEditorRequest, store: ClipboardStore) {
        var initial: NSAttributedString?
        if case .editEntry(let id) = request.operation,
           let entry = store.entries.first(where: { $0.id == id }),
           let data = entry.items.compactMap({ $0[NSPasteboard.PasteboardType.rtf.rawValue] }).first {
            initial = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        let attributed = initial ?? NSAttributedString(string: request.text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black
        ])
        original = attributed
        value = attributed
        super.init()
    }

    var hasChanges: Bool { !value.isEqual(to: original) }
    var canSave: Bool {
        !value.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value.string.utf8.count <= ClipboardStore.maximumEntryBytes
    }
    var summary: String {
        let text = value.string
        let words = text.split(whereSeparator: \.isWhitespace).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return "\(text.count.formatted()) characters · \(words.formatted()) words · \(lines.formatted()) lines"
    }
    func rtfData() throws -> Data {
        try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    func textDidChange(_ notification: Notification) { synchronize() }

    @available(macOS 15.2, *)
    func showWritingTools() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if textView.selectedRange().length == 0 { textView.selectAll(nil) }
        textView.showWritingTools(nil)
    }
    func textViewDidChangeSelection(_ notification: Notification) { synchronizeFormatting() }
    private func synchronize() {
        guard let textView else { return }
        value = NSAttributedString(attributedString: textView.attributedString())
        synchronizeFormatting()
    }
    private func synchronizeFormatting() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if selection.length > 0, selection.location < textView.attributedString().length {
            attrs = textView.attributedString().attributes(at: selection.location, effectiveRange: nil)
        } else { attrs = textView.typingAttributes }
        let traits = NSFontManager.shared.traits(of: attrs[.font] as? NSFont ?? .systemFont(ofSize: 14))
        bold = traits.contains(.boldFontMask)
        italic = traits.contains(.italicFontMask)
        underline = (attrs[.underlineStyle] as? NSNumber)?.intValue != nil && (attrs[.underlineStyle] as? NSNumber)?.intValue != 0
        strike = (attrs[.strikethroughStyle] as? NSNumber)?.intValue != nil && (attrs[.strikethroughStyle] as? NSNumber)?.intValue != 0
    }

    func toggle(_ formatting: Formatting) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let wasEnabled: Bool
        switch formatting {
        case .bold: wasEnabled = bold
        case .italic: wasEnabled = italic
        case .underline: wasEnabled = underline
        case .strike: wasEnabled = strike
        }
        func converted(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attrs
            switch formatting {
            case .bold, .italic:
                let trait: NSFontTraitMask = formatting == .bold ? .boldFontMask : .italicFontMask
                let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
                result[.font] = wasEnabled ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
            case .underline: result[.underlineStyle] = wasEnabled ? 0 : NSUnderlineStyle.single.rawValue
            case .strike: result[.strikethroughStyle] = wasEnabled ? 0 : NSUnderlineStyle.single.rawValue
            }
            return result
        }
        if selection.length == 0 {
            textView.typingAttributes = converted(textView.typingAttributes)
        } else {
            let previous = NSAttributedString(attributedString: textView.attributedString())
            let updated = NSMutableAttributedString(attributedString: previous)
            previous.enumerateAttributes(in: selection) { attrs, range, _ in
                updated.setAttributes(converted(attrs), range: range)
            }
            replace(updated, selection: selection)
            textView.undoManager?.setActionName("Format Text")
        }
        textView.window?.makeFirstResponder(textView)
        synchronizeFormatting()
    }

    private func replace(_ attributed: NSAttributedString, selection: NSRange) {
        guard let textView else { return }
        let before = NSAttributedString(attributedString: textView.attributedString())
        let priorSelection = textView.selectedRange()
        textView.undoManager?.registerUndo(withTarget: self) { model in
            model.replace(before, selection: priorSelection)
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(selection)
        textView.didChangeText()
        synchronize()
    }
}

@MainActor
private struct ClipboardRichTextEditor: View {
    @ObservedObject var model: ClipboardRichTextModel
    let request: ClipboardEditorRequest
    let store: ClipboardStore
    let dismiss: () -> Void
    @State private var discardRequested = false
    @State private var error: String?

    private var saveTitle: String { if case .newText = request.operation { return "Create" }; return "Save" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Cancel") { cancel() }
                    .buttonStyle(ClipboardEditorPillStyle(prominent: false))
                    .keyboardShortcut(.cancelAction).help("Cancel (Esc)")
                Spacer(minLength: 8)
                formatButton("bold", title: "Bold (⌘B)", active: model.bold, formatting: .bold)
                formatButton("italic", title: "Italic (⌘I)", active: model.italic, formatting: .italic)
                formatButton("underline", title: "Underline (⌘U)", active: model.underline, formatting: .underline)
                formatButton("strikethrough", title: "Strikethrough (⇧⌘X)", active: model.strike, formatting: .strike)
                if #available(macOS 15.2, *) {
                    Button { model.showWritingTools() } label: {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 12)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).help("Writing Tools (⇧⌘E)").accessibilityLabel("Writing Tools")
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }
                Spacer(minLength: 8)
                Button(saveTitle) { save() }
                    .buttonStyle(ClipboardEditorPillStyle(prominent: true))
                    .disabled(!model.canSave).keyboardShortcut("s", modifiers: .command)
                    .help("\(saveTitle) (⌘S)")
            }.padding(.horizontal, 10).frame(height: 36)
            ClipboardAttributedTextView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 5).padding(.top, 2)
            HStack {
                Text(error ?? model.summary).font(.system(size: 11))
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 38)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .alert("Discard changes?", isPresented: $discardRequested) {
            Button("Keep Editing", role: .cancel) { model.textView?.window?.makeFirstResponder(model.textView) }
            Button("Discard", role: .destructive) { dismiss() }
        } message: { Text("Your changes to this clipboard item have not been saved.") }
    }
    private func formatButton(_ symbol: String, title: String, active: Bool, formatting: ClipboardRichTextModel.Formatting) -> some View {
        Button { model.toggle(formatting) } label: {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24)
                .background(active ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private func cancel() {
        if model.hasChanges { discardRequested = true } else { dismiss() }
    }
    private func save() {
        do {
            let rtf = try model.rtfData()
            guard rtf.count + model.value.string.utf8.count <= ClipboardStore.maximumEntryBytes else {
                error = "Text exceeds the item size limit"; return
            }
            switch request.operation {
            case .newText:
                guard store.createTextItem(model.value.string, rtfData: rtf) != nil else {
                    error = store.lastError ?? "Could not create this clipboard item."; return
                }
            case .editEntry(let id):
                guard store.entries.contains(where: { $0.id == id }) else {
                    error = "This clipboard item is no longer available."; return
                }
                store.editText(entryID: id, text: model.value.string, rtfData: rtf)
            default: return
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ClipboardEditorPillStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12).frame(height: 24)
            .background(prominent ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

@MainActor
private struct ClipboardAttributedTextView: NSViewRepresentable {
    let model: ClipboardRichTextModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let text = EditorTextView(frame: .zero)
        text.model = model
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        // Apple Intelligence Writing Tools (rewrite, proofread, summarize) work
        // inline in the editor, as in Paste 7's text editor.
        if #available(macOS 15.0, *) { text.writingToolsBehavior = .complete }
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 9, height: 10)
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textColor = .textColor
        text.insertionPointColor = .black
        text.font = .systemFont(ofSize: 14)
        text.textStorage?.setAttributedString(model.value)
        text.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        text.delegate = model
        model.textView = text
        scroll.documentView = text
        DispatchQueue.main.async {
            text.window?.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        }
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class EditorTextView: NSTextView {
        weak var model: ClipboardRichTextModel?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let formatting: ClipboardRichTextModel.Formatting?
            switch (event.keyCode, modifiers) {
            case (11, .command): formatting = .bold
            case (34, .command): formatting = .italic
            case (32, .command): formatting = .underline
            case (7, [.command, .shift]): formatting = .strike
            default: formatting = nil
            }
            if let formatting { model?.toggle(formatting); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor
struct ClipboardReadOnlyTextPreview: NSViewRepresentable {
    let entry: ClipboardEntry
    var prepared: NSAttributedString? = nil
    final class Coordinator {
        var version: UUID?
        var isPrepared = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 9, height: 10)
        text.backgroundColor = .textBackgroundColor
        text.textColor = .textColor
        text.font = .systemFont(ofSize: 14)
        scroll.documentView = text
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.version != entry.contentVersion || context.coordinator.isPrepared != (prepared != nil) else { return }
        context.coordinator.version = entry.contentVersion
        context.coordinator.isPrepared = prepared != nil
        // Full text and RTF are prepared by ClipboardPreviewCache's worker.
        // Until then, display a bounded plain preview without parsing rich data.
        let attributed = prepared ?? NSAttributedString(string: entry.previewText, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black
        ])
        text.textStorage?.setAttributedString(attributed)
    }
}
