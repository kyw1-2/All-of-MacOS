import AppKit
import SwiftUI

/// 7.0: AI Chat, Raycast's chat window — the launcher's conversation in a
/// window of its own (⌘J on Ask AI with a native model), with earlier chats
/// in the sidebar, the model menu in the toolbar and a composer that keeps
/// what you typed while the answer streams.
@MainActor
final class AOMAIChatWindowController: NSObject, NSWindowDelegate {
    static let shared = AOMAIChatWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AOMAIChatWindowView(chat: .shared, history: .shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AI Chat"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AOMAIChatWindow")
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct AOMAIChatWindowView: View {
    @ObservedObject var chat: PaletteAIChat
    @ObservedObject var history: AOMAIChatHistory
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<UUID?>(get: { chat.chatID }, set: { id in
                if let id, id != chat.chatID, let record = history.records.first(where: { $0.id == id }) { chat.load(record) }
            })) {
                // 7.3: a chats.json that couldn't be read is kept, never replaced.
                if let problem = history.problem {
                    AOMNotice(problem.blocksSaving ? .error : .warning, problem.title, detail: problem.detail) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([problem.file]) }
                    }
                }
                Section("Chats") {
                    ForEach(history.records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title).lineLimit(1)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        }
                        .tag(record.id)
                        .contextMenu {
                            Button("Delete Chat", role: .destructive) { history.delete(record.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
            .toolbar {
                ToolbarItem {
                    Button { chat.newChat(); composerFocused = true } label: { Image(systemName: "square.and.pencil") }
                        .help("New Chat (⌘N)")
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if chat.messages.isEmpty {
                    VStack(spacing: 10) {
                        AOMAIProviderGlyph(provider: chat.model.provider, size: 44)
                        Text("Ask \(chat.model.title)").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AOMCraftColor.ink)
                        Text("⌘↩ sends · ⌘N new chat · ⌘R asks again")
                            .font(AOMFont.callout).foregroundStyle(AOMCraftColor.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AOMAITranscriptView(chat: chat, fontSize: 14, horizontalPadding: 28)
                }
                composer
            }
            .background(AOMCraftColor.canvas)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { AOMAIModelMenu(chat: chat) }
                ToolbarItem(placement: .primaryAction) {
                    Button { chat.regenerate() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Ask Again (⌘R)")
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(chat.isRunning || chat.messages.isEmpty)
                }
            }
            .navigationTitle(chat.title)
        }
        .onAppear { composerFocused = true }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a follow-up…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
            if chat.isRunning {
                Button { chat.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Stop (⌘.)")
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AOMCraftColor.inkTertiary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (↩, ⌘↩)")
            }
        }
        .padding(12)
        .aomContentCard(radius: 14, padding: 0)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isRunning else { return }
        draft = ""
        chat.ask(text)
    }
}
