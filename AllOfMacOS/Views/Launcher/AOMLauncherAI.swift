import AppKit
import SwiftUI

// AOM 7.0: Ask AI's pieces, shared by the launcher and the AI Chat window —
// a Markdown renderer that streams (headings, lists, quotes, tables and
// code blocks with a Copy button), the transcript, the model picker and
// each provider's mark.

// MARK: - Markdown

enum AOMMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [String])
        case quote(String)
        case code(language: String, text: String)
        case table(rows: [[String]])
        case rule
    }

    /// Pure: Markdown split into blocks. An unclosed code fence (the answer
    /// is still streaming) runs to the end.
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var quote: [String] = []
        var table: [[String]] = []
        var code: (language: String, lines: [String])?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(ordered: listOrdered, items: listItems)); listItems = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(rows: table)); table = [] }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote(); flushTable() }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(raw)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                code = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if line.isEmpty { flushAll(); continue }
            if line.hasPrefix("|"), line.hasSuffix("|"), line.count > 1 {
                flushParagraph(); flushList(); flushQuote()
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:--:| line under the header.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            }
            flushTable()
            if let level = headingLevel(line) {
                flushAll()
                blocks.append(.heading(level: level, text: String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == "---" || line == "***" || line == "___" { flushAll(); blocks.append(.rule); continue }
            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = bullet(line) {
                flushParagraph(); flushQuote()
                if !listItems.isEmpty, listOrdered { flushList() }
                listOrdered = false
                listItems.append(item)
                continue
            }
            if let item = numbered(line) {
                flushParagraph(); flushQuote()
                if !listItems.isEmpty, !listOrdered { flushList() }
                listOrdered = true
                listItems.append(item)
                continue
            }
            // An indented line continues the list item above it.
            if !listItems.isEmpty, raw.hasPrefix("  ") {
                listItems[listItems.count - 1] += " " + line
                continue
            }
            flushList(); flushQuote()
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// Inline Markdown (bold, italics, `code`, links), whitespace kept.
    static func inline(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = .system(size: 12.5, design: .monospaced)
            string[run.range].backgroundColor = AOMCraftColor.well
        }
        return string
    }
}

struct AOMMarkdownView: View {
    let text: String
    var fontSize: CGFloat = 13.5
    var streaming = false

    var body: some View {
        let blocks = AOMMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, isLast: index == blocks.count - 1)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: AOMMarkdown.Block, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let title):
            Text(AOMMarkdown.inline(title))
                .font(.system(size: level == 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 0.5, weight: .semibold))
                .foregroundStyle(AOMCraftColor.ink)
                .padding(.top, 2)
        case .paragraph(let body):
            paragraph(body, caret: streaming && isLast)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: fontSize, weight: ordered ? .medium : .bold).monospacedDigit())
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        Text(AOMMarkdown.inline(item))
                            .font(.system(size: fontSize))
                            .foregroundStyle(AOMCraftColor.ink)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let body):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(AOMCraftColor.inkTertiary).frame(width: 3)
                Text(AOMMarkdown.inline(body))
                    .font(.system(size: fontSize))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let body):
            AOMCodeBlock(language: language, code: body)
        case .table(let rows):
            AOMMarkdownTable(rows: rows, fontSize: fontSize)
        case .rule:
            Rectangle().fill(AOMCraftColor.hairline).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func paragraph(_ body: String, caret: Bool) -> some View {
        var string = AOMMarkdown.inline(body)
        if caret {
            var mark = AttributedString(" ▍")
            mark.foregroundColor = Color.accentColor
            string += mark
        }
        return Text(string)
            .font(.system(size: fontSize))
            .foregroundStyle(AOMCraftColor.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AOMCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AOMCraftColor.inkTertiary)
                Spacer()
                Button {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Color.green : AOMCraftColor.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy the code")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            Rectangle().fill(AOMCraftColor.hairline).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AOMCraftColor.ink)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(AOMCraftColor.codeWell, in: RoundedRectangle(cornerRadius: AOMCraftRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMCraftRadius.control, style: .continuous)
            .strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5))
    }
}

private struct AOMMarkdownTable: View {
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(AOMMarkdown.inline(column < row.count ? row[column] : ""))
                                .font(.system(size: fontSize - 1, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? AOMCraftColor.ink : AOMCraftColor.ink.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
        }
        .background(AOMCraftColor.well, in: RoundedRectangle(cornerRadius: AOMCraftRadius.control, style: .continuous))
    }
}

// MARK: - Provider marks

extension AOMAIProvider {
    /// Each provider's tint (not a logo).
    var tint: Color {
        switch self {
        case .apple: return Color(nsColor: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.95, alpha: 1))
        case .anthropic, .claudeCode: return Color(nsColor: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        case .localProxy: return Color(nsColor: NSColor(srgbRed: 0.10, green: 0.62, blue: 0.62, alpha: 1))
        case .openAI, .codex: return Color(nsColor: NSColor(srgbRed: 0.30, green: 0.32, blue: 0.36, alpha: 1))
        case .deepSeek: return Color(nsColor: NSColor(srgbRed: 0.30, green: 0.42, blue: 1.0, alpha: 1))
        case .ollama: return Color(nsColor: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.48, alpha: 1))
        case .deepSeekHarness: return Color(nsColor: NSColor(srgbRed: 0.18, green: 0.36, blue: 0.92, alpha: 1))
        }
    }

    /// The symbol, falling back when this macOS lacks it.
    var resolvedSymbol: String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : fallbackSymbol
    }
}

struct AOMAIProviderGlyph: View {
    let provider: AOMAIProvider
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: provider.resolvedSymbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if provider == .apple {
                    shape.fill(LinearGradient(colors: [Color(nsColor: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.55, alpha: 1)),
                                                       provider.tint,
                                                       Color(nsColor: NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 1))],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(provider.tint)
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// MARK: - Model picker

/// The accessory at the right of the search field on Ask AI (Raycast's
/// model dropdown): ready models first, the rest say what they need.
struct AOMAIModelMenu: View {
    @ObservedObject var chat: PaletteAIChat
    @State private var refresh = 0

    var body: some View {
        Menu {
            ForEach(AOMAIConfig.pickerModels(), id: \.provider) { group in
                Section(group.ready ? group.provider.title : "\(group.provider.title) — \(setupHint(group.provider))") {
                    ForEach(group.models) { option in
                        let ref = AOMAIModelRef(provider: group.provider, model: option.id)
                        Button {
                            chat.model = ref
                        } label: {
                            if ref == chat.model {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                        .disabled(!group.ready)
                    }
                }
            }
            Divider()
            Button("AI Settings…") { AOMAISettingsLink.open() }
        } label: {
            HStack(spacing: 6) {
                AOMAIProviderGlyph(provider: chat.model.provider, size: 16)
                Text(chat.model.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AOMCraftColor.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(AOMCraftColor.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model (⌘P lists them all, ⇥ goes to the next)")
        .accessibilityLabel("Model: \(chat.model.title)")
        .id(refresh)
        .onReceive(NotificationCenter.default.publisher(for: AOMAIConfig.didChange)) { _ in refresh &+= 1 }
    }

    private func setupHint(_ provider: AOMAIProvider) -> String {
        switch provider {
        case .apple: return "unavailable"
        case .anthropic, .openAI, .deepSeek: return "add a key in Settings"
        case .localProxy: return "not running"
        case .ollama: return "not running"
        case .claudeCode, .codex, .deepSeekHarness: return "not installed"
        }
    }
}

enum AOMAISettingsLink {
    @MainActor static func open() {
        let show = {
            AppDelegate.current?.openSettingsWindow()
            // Again once the window's view is up to hear it.
            for delay in [0.05, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.ai.rawValue)
                }
            }
        }
        if AOMLauncherController.shared.isVisible {
            AOMLauncherController.shared.dismiss(restoringFocus: false, then: show)
        } else {
            show()
        }
    }
}

// MARK: - Transcript

/// The conversation: each question in a quiet chip, its answer rendered as
/// Markdown under the model that wrote it, errors in a red card; follows
/// the newest line while it streams.
struct AOMAITranscriptView: View {
    @ObservedObject var chat: PaletteAIChat
    var fontSize: CGFloat = 13.5
    var horizontalPadding: CGFloat = 18
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        messageView(message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("ai.bottom")
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.last?.text.count) { _, _ in proxy.scrollTo("ai.bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("ai.bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("ai.bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func messageView(_ message: PaletteAIChat.Message) -> some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(AOMCraftColor.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(AOMCraftColor.ink)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    // 7.3: what this question was allowed to read.
                    if let scope = message.scopeSummary {
                        Label(scope, systemImage: "tray.full")
                            .font(.system(size: 11))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AOMCraftColor.well, in: RoundedRectangle(cornerRadius: AOMCraftRadius.row, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)" + (message.scopeSummary.map { ". Records: \($0)" } ?? ""))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AOMAIProviderGlyph(provider: chat.model.provider, size: 16)
                    Text(message.model ?? chat.model.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                    if isStreaming(message) {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    if !message.text.isEmpty, !isStreaming(message) {
                        Button {
                            if let onCopy { onCopy(message.text) } else {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AOMCraftColor.inkTertiary)
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .aomCalmHover(radius: 5)
                        .help("Copy this answer")
                    }
                }
                if message.text.isEmpty {
                    AOMThinkingDots(label: message.thinking ? "Thinking…" : "Writing…")
                } else {
                    AOMMarkdownView(text: message.text, fontSize: fontSize, streaming: isStreaming(message))
                }
                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                }
                if let receipt = message.receipt, !isStreaming(message) || !receipt.used.isEmpty {
                    AOMAIReceiptLine(receipt: receipt)
                }
            }
            .padding(.leading, 2)
        case .error:
            Label {
                Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(AOMColor.dangerText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AOMColor.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: AOMCraftRadius.row, style: .continuous))
        }
    }

    private func isStreaming(_ message: PaletteAIChat.Message) -> Bool {
        chat.isRunning && message.id == chat.messages.last?.id
    }
}

/// Three dots that pulse while the first word is on its way (still with
/// Reduce Motion).
struct AOMThinkingDots: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.32) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(AOMCraftColor.inkSecondary)
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : (index == phase ? 1 : 0.3))
                    }
                }
            }
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(AOMCraftColor.inkTertiary)
        }
        .accessibilityLabel(label)
    }
}

/// Ask AI before the first question: the model in use, what it is, and
/// what it needs if it can't answer yet.
struct AOMAIHomeHeader: View {
    @ObservedObject var chat: PaletteAIChat
    let frontApp: String?

    var body: some View {
        let provider = chat.model.provider
        let ready = AOMAIConfig.isReady(provider)
        HStack(alignment: .center, spacing: 12) {
            AOMAIProviderGlyph(provider: provider, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask \(chat.model.title)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AOMCraftColor.ink)
                Text(ready ? detail(provider) : needs(provider))
                    .font(.system(size: 12))
                    .foregroundStyle(ready ? AOMCraftColor.inkSecondary : AOMColor.warningText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !ready {
                Button("Set Up…") { AOMAISettingsLink.open() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(provider.tint.opacity(0.06))
    }

    private func detail(_ provider: AOMAIProvider) -> String {
        let paste = "↩ pastes into \(frontApp ?? "the app you were in")"
        switch provider {
        case .apple: return "On this Mac — private, no key. \(paste) · ⌘P models"
        case .anthropic: return "Streams from Anthropic with your API key. \(paste) · ⌘P models"
        case .localProxy: return "Through your local router (\(AOMAIConfig.baseURL(for: .localProxy))). \(paste)"
        case .openAI, .deepSeek: return "Streams from \(provider.title) with your API key. \(paste) · ⌘P models"
        case .ollama: return "A local model through Ollama. \(paste)"
        case .claudeCode: return "Your Claude subscription through Claude Code, read-only and kept warm. ⌘J continues in Terminal."
        case .codex: return "Your ChatGPT plan through Codex, read-only. ⌘J continues in Terminal."
        case .deepSeekHarness: return "Your DeepSeek Harness, read-only: it reads files and runs read-only commands to answer. ⌘J opens the app."
        }
    }

    private func needs(_ provider: AOMAIProvider) -> String {
        switch provider {
        case .apple: return AOMAppleIntelligence.status + ". ⌘P picks another model."
        case .anthropic, .openAI, .deepSeek: return "Add your \(provider.title) API key in Settings › AI, or ⌘P for another model."
        case .localProxy: return "Nothing answers at \(AOMAIConfig.baseURL(for: .localProxy)). ⌘P picks another model."
        case .ollama: return "Start Ollama, then fetch its models in Settings › AI."
        case .claudeCode, .codex, .deepSeekHarness: return "\(provider.title) isn't installed on this Mac. ⌘P picks another model."
        }
    }
}

/// 7.3 (Codex 7.2.3 report, "AI 자료 영수증"): under an answer, where the
/// question went, what it was allowed to read and what was read. A
/// symbol and words, never colour alone, say that it left this Mac.
struct AOMAIReceiptLine: View {
    let receipt: AOMAIReceipt
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: receipt.leavesMac ? "arrow.up.forward.circle" : "lock.circle")
                    .accessibilityHidden(true)
                Text(expanded ? receipt.line : short)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .multilineTextAlignment(.leading)
            }
            .font(.system(size: 11))
            .foregroundStyle(AOMCraftColor.inkTertiary)
        }
        .buttonStyle(.plain)
        .help(receipt.line)
        .accessibilityLabel(receipt.line)
        .accessibilityHint(expanded ? "Shows less" : "Shows what was shared")
    }

    private var short: String {
        var parts = [receipt.destination]
        if receipt.allowed == "Nothing" { parts.append("No records") }
        else { parts.append(receipt.used.isEmpty ? "Nothing read" : "Read \(receipt.used.count) source\(receipt.used.count == 1 ? "" : "s")") }
        if receipt.clipboardAttached { parts.append("Clipboard") }
        if receipt.earlierTurns > 0 { parts.append("+\(receipt.earlierTurns) earlier") }
        return parts.joined(separator: " · ")
    }
}
