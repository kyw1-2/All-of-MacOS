import AppKit
import SwiftUI

/// 7.23 (DeepSeek design reference 2026-11-25 §2.1, Things Quick Entry): a
/// small field over any app for what just came to mind. ⌃⌥N (Settings ›
/// Shortcuts) opens it without activating AOM; ⌘↩ saves and keeps the panel
/// open with an empty field for the next one; esc closes it and the app
/// underneath keeps its focus. A sentence with a time ("내일 3시 회의")
/// previews as an event or a reminder.
@MainActor
final class QuickEntryController: ObservableObject {
    static let shared = QuickEntryController()

    @Published var text = ""
    @Published var destination: QuickEntryStore.Destination = QuickEntryStore.shared.lastDestination {
        didSet { QuickEntryStore.shared.lastDestination = destination }
    }
    @Published var outcome: QuickEntryStore.Outcome?
    @Published var saving = false
    private var panel: SnippetCaretPanel?
    private var keyMonitor: Any?

    static let size = CGSize(width: 520, height: 132)

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        if let panel { panel.orderFrontRegardless(); panel.makeKey(); return }
        let panel = SnippetCaretPanel.make(contentRect: CGRect(origin: .zero, size: Self.size))
        panel.contentView = NSHostingView(rootView: QuickEntryView(controller: self))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        // Upper third, centred (Things and Spotlight sit there).
        panel.setFrameOrigin(CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + visible.height * 0.66))
        self.panel = panel
        outcome = nil
        panel.orderFrontRegardless()
        panel.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.close(); return nil }
            if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
                self.save(); return nil
            }
            return event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        outcome = nil
    }

    /// What the field would become, for the preview line.
    var sentence: QuickEntrySentence? { QuickEntryParser.parse(text) }

    func save() {
        guard !saving else { return }
        let entry = text
        saving = true
        Task {
            let result = await QuickEntryStore.shared.save(entry, to: destination)
            saving = false
            outcome = result
            if case .saved = result { text = "" }
        }
    }
}

struct QuickEntryView: View {
    @ObservedObject var controller: QuickEntryController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Picker("Save to", selection: $controller.destination) {
                    ForEach(QuickEntryStore.Destination.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .aomSegmented()
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 0)
                Text("⌘↩ Save · esc Close")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textTertiary)
            }
            TextField(placeholder, text: $controller.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AOMFont.entry)
                .lineLimit(1...3)
                .focused($focused)
                .accessibilityLabel("Quick Entry")
            statusLine
        }
        .padding(AOMSpace.x4)
        .frame(width: QuickEntryController.size.width, alignment: .topLeading)
        .frame(minHeight: QuickEntryController.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AOMRadius.panel, style: .continuous))
        .onAppear { focused = true }
    }

    private var placeholder: String {
        switch controller.destination {
        case .note: "Write it down…"
        case .reminder: "Remind me to… (내일 9시 약 먹기)"
        case .event: "Event and when (금요일 3시 회의, lunch tomorrow 12pm)"
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let outcome = controller.outcome {
            switch outcome {
            case .saved(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(AOMFont.callout).foregroundStyle(AOMColor.successText)
            case .failed(let title, let why, let fix):
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: "exclamationmark.triangle.fill")
                        .font(AOMFont.callout.weight(.semibold)).foregroundStyle(AOMColor.warningText)
                    Text(why).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    if let fix {
                        Button(fix) {
                            if fix.hasPrefix("Allow") { QuickEntryStore.openPrivacy(for: controller.destination) }
                        }
                        .buttonStyle(.link).font(AOMFont.caption)
                    }
                }
            }
        } else if controller.destination != .note, let sentence = controller.sentence {
            Label("\(sentence.title) · \(QuickEntryParser.describe(sentence))", systemImage: controller.destination.symbol)
                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
        } else if controller.destination == .event, !controller.text.isEmpty {
            Text("Add a day or a time to make it an event")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
        }
    }
}
