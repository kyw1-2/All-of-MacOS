import AppKit
import SwiftUI

/// A page's search field as a toolbar item, in place of
/// `.searchable(placement: .toolbar)`: inside `aomPageToolbar` it exists only
/// while its page is selected, which `.searchable` cannot do without changing
/// the page's identity. Put it last among the page's items so it sits at the
/// trailing end, where the system field sat.
struct AOMToolbarSearchItem: ToolbarContent {
    @Binding var text: String
    let prompt: String
    /// Setting it to true focuses the field, which sets it back to false.
    var focusRequest: Binding<Bool>?

    init(text: Binding<String>, prompt: String, focusRequest: Binding<Bool>? = nil) {
        self._text = text
        self.prompt = prompt
        self.focusRequest = focusRequest
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            AOMToolbarSearchField(text: $text, prompt: prompt, focusRequest: focusRequest)
        }
    }
}

/// `NSSearchField` with the system search field's behaviour: it filters as
/// you type, ⌘F focuses it, and Escape clears it and gives up focus.
struct AOMToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var focusRequest: Binding<Bool>?

    static let widthRange: ClosedRange<CGFloat> = 160...320
    static let idealWidth: CGFloat = 240

    /// Isolated previews (`--aom-preview-search`): the field on screen takes
    /// the posted text as if it had been typed.
    static let previewSearch = Notification.Name("AOMPreviewToolbarSearch")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = text
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.coordinator = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != prompt { field.placeholderString = prompt }
        if field.stringValue != text { field.stringValue = text }
        field.updateFocusRequest(focusRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        let width = proposal.width.map { min(max($0, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
            ?? Self.idealWidth
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.cancelFocusRequest()
        field.coordinator = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AOMToolbarSearchField

        init(_ parent: AOMToolbarSearchField) { self.parent = parent }

        func set(_ value: String) {
            if parent.text != value { parent.text = value }
        }

        @objc func searchChanged(_ sender: NSSearchField) { set(sender.stringValue) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            set(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.stringValue = ""
            set("")
            control.window?.makeFirstResponder(nil)
            return true
        }
    }

    final class Field: NSSearchField {
        weak var coordinator: Coordinator?
        private var keyMonitor: Any?
        private var previewObserver: NSObjectProtocol?
        private let deferredFocus = AOMDeferredWindowFocus()
        private var hadWindow = false

        func focus() {
            guard let window, isEnabled, !isHiddenOrHasHiddenAncestor, currentEditor() == nil else { return }
            window.makeFirstResponder(self)
        }

        func updateFocusRequest(_ request: Binding<Bool>?) {
            guard let request, request.wrappedValue, let window else { deferredFocus.cancel(); return }
            // A detached field must not replay its old request in a new window.
            deferredFocus.schedule(in: window) { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      let liveRequest = self.coordinator?.parent.focusRequest, liveRequest.wrappedValue else { return }
                self.focus()
                liveRequest.wrappedValue = false
            }
        }

        func cancelFocusRequest() { deferredFocus.cancel() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow { cancelFocusRequest() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopListening()
            if window != nil {
                startListening()
                if !hadWindow { updateFocusRequest(coordinator?.parent.focusRequest) }
                hadWindow = true
            }
        }

        /// ⌘F reaches the field only while it is in a window, which for a
        /// page's field means while its page is selected. A text view with
        /// its own find bar keeps ⌘F.
        private func startListening() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
                if let text = window.firstResponder as? NSTextView, !text.isFieldEditor,
                   text.usesFindBar || text.usesFindPanel { return event }
                self.focus()
                return nil
            }
            if PresetManager.isUIPreview {
                previewObserver = NotificationCenter.default.addObserver(
                    forName: AOMToolbarSearchField.previewSearch, object: nil, queue: .main) { [weak self] note in
                    guard let text = note.object as? String else { return }
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.stringValue = text
                        self.coordinator?.set(text)
                    }
                }
            }
        }

        private func stopListening() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
            previewObserver = nil
        }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        }
    }
}
