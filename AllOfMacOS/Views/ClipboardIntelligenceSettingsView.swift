import AppKit
import SwiftUI

/// Settings ▸ Clipboard ▸ Intelligence: Intelligent Clipboard and MCP & AI tools
/// (Paste 7 "Intelligence" pane equivalents, all local).
@MainActor
struct ClipboardIntelligenceSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var mcp = ClipboardMCPSettings.shared
    @State private var intelligent = ClipboardIntelligence.shared.isEnabled
    @State private var readsScreen = ClipboardIntelligence.shared.readsDestinationScreen
    @State private var connecting: ConnectRequest?
    @State private var pendingDisconnect: ClipboardMCPTool?
    @State private var eraseConfirmation = false

    struct ConnectRequest: Identifiable {
        let id = UUID()
        let client: ClipboardMCPSettings.Client
        var name: String
        var token: String?
    }

    var body: some View {
        GroupBox("Intelligence") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Intelligent Clipboard", isOn: $intelligent)
                    .onChange(of: intelligent) { _, value in ClipboardIntelligence.shared.isEnabled = value }
                Text("Suggests what you are about to paste, based on the field you are typing into and what you pasted there before. Suggested items appear first with ✦. Everything stays on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Look at the destination window with the on-device model", isOn: $readsScreen)
                    .disabled(!intelligent || !ClipboardIntelligence.modelAvailable)
                    .onChange(of: readsScreen) { _, value in
                        ClipboardIntelligence.shared.readsDestinationScreen = value
                        if value && !ScreenCaptureService.hasPermission { _ = ScreenCaptureService.requestPermission() }
                    }
                Text(ClipboardIntelligence.modelAvailable
                     ? "Only when you open the clipboard and the field type is unclear, a small screenshot of that window is read by Apple Intelligence on this Mac. Needs Screen Recording access."
                     : "Requires Apple Intelligence. Suggestions still work from the focused field and your paste history.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Erase Suggestion History…") { eraseConfirmation = true }
                    .disabled(ClipboardIntelligence.shared.log(for: store).events.isEmpty)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Erase suggestion history?", isPresented: $eraseConfirmation) {
            Button("Erase", role: .destructive) { ClipboardIntelligence.shared.log(for: store).erase() }
        } message: { Text("AOM forgets which items you pasted into which apps. Clipboard items are not deleted.") }

        GroupBox("MCP & AI Tools") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable MCP", isOn: $mcp.enabled)
                Text("Allow AI apps such as Claude Code, Codex and Cursor to search and manage your clipboard items and pinboards. Only tools you connect here can access it, through a private local socket — nothing listens on the network. Items that look like passwords, tokens or keys are never shared.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Connected AI Tools").font(.headline)
                    Spacer()
                    Menu("Connect AI Tool…") {
                        ForEach(ClipboardMCPSettings.Client.allCases) { client in
                            Button(client.rawValue) { connecting = .init(client: client, name: client.rawValue) }
                        }
                    }.fixedSize()
                }
                if mcp.tools.isEmpty {
                    Text("Nothing connected yet").foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(mcp.tools) { tool in
                        HStack {
                            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                Text(tool.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect…") { pendingDisconnect = tool }
                        }
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $connecting) { request in
            ClipboardMCPConnectSheet(request: request) { connecting = nil }
        }
        .confirmationDialog("Disconnect “\(pendingDisconnect?.name ?? "")”?", isPresented: Binding(
            get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } })) {
            Button("Disconnect", role: .destructive) {
                if let tool = pendingDisconnect { mcp.disconnect(tool.id) }
                pendingDisconnect = nil
            }
        } message: { Text("\(pendingDisconnect?.name ?? "This tool") will no longer be able to access your clipboard.") }
    }
}

@MainActor
private struct ClipboardMCPConnectSheet: View {
    @State var request: ClipboardIntelligenceSettingsView.ConnectRequest
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(request.client.rawValue)").font(.title2.weight(.semibold))
            if let token = request.token {
                let instructions = ClipboardMCPSettings.instructions(for: request.client, token: token)
                Text(instructions.summary).font(.callout)
                ScrollView {
                    Text(instructions.snippet).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: request.client == .claudeCode || request.client == .codex ? 70 : 170)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                Text("The token is shown only now and is stored only as a hash. Treat it like a password.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instructions.snippet, forType: .string)
                        copied = true
                    }
                    Spacer()
                    Button("Done") { done() }.keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("Name (e.g. My AI Tool)", text: $request.name).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        request.token = ClipboardMCPSettings.shared.connect(name: request.name, client: request.client.rawValue)
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 520)
    }
}
