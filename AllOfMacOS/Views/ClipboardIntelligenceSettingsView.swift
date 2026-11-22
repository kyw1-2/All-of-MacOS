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

    /// Destination context uses APIs supported by each macOS version.
    private var destinationModelCopy: String {
        guard ClipboardIntelligence.destinationModelAvailable else {
            return "Requires macOS 26 or later with Apple Intelligence. Suggestions still work from the focused field and your paste history."
        }
        return "Only when the focused field is unclear, AOM reads the destination window on this Mac. macOS 26 uses local Vision text recognition and the text model; macOS 27 can analyze the image directly. Needs Screen Recording access."
    }

    var body: some View {
        AOMSection("Intelligence",
                   help: "Never in password fields or while secure keyboard entry is on: nothing is suggested, read or learned there. Apps on the excluded list are not read for suggestions either, and items that look like passwords, tokens or keys are never suggested.") {
            AOMToggleRow("Intelligent Clipboard",
                         help: "Suggests what you are about to paste, based on the field you are typing into and what you pasted there before. Suggested items appear first with ✦. Everything stays on your Mac.",
                         isOn: $intelligent)
                .onChange(of: intelligent) { _, value in ClipboardIntelligence.shared.isEnabled = value }
            AOMToggleRow("Look at the destination window with the on-device model",
                         help: destinationModelCopy, indent: true,
                         isOn: Binding(get: { readsScreen && ClipboardIntelligence.destinationModelAvailable },
                                       set: { readsScreen = $0 }))
                .disabled(!ClipboardIntelligence.destinationModelAvailable)
                .onChange(of: readsScreen) { _, value in
                    ClipboardIntelligence.shared.readsDestinationScreen = value
                    if value && !ScreenCaptureService.hasPermission { _ = ScreenCaptureService.requestPermission() }
                }
                .aomDependentRows(enabled: intelligent)
            AOMSettingRow("Suggestion history", help: "Which items you pasted into which apps. Erasing it keeps your clipboard items.") {
                Button("Erase Suggestion History…") { eraseConfirmation = true }
                    .disabled(ClipboardIntelligence.shared.log(for: store).events.isEmpty)
            }
        }
        .confirmationDialog("Erase suggestion history?", isPresented: $eraseConfirmation) {
            Button("Erase", role: .destructive) { ClipboardIntelligence.shared.log(for: store).erase() }
        } message: { Text("AOM forgets which items you pasted into which apps. Clipboard items are not deleted.") }

        AOMSection("MCP & AI tools",
                   help: "Allow AI apps such as Claude Code, Codex and Cursor to search and manage your clipboard items and pinboards. Only tools you connect here can access it, through a private local socket — nothing listens on the network. Items that look like passwords, tokens or keys are never shared.") {
            // What MCP allows is the section's ⓘ; the switch needs no second line.
            AOMToggleRow("Enable MCP", isOn: $mcp.enabled)
            AOMSettingRow("Connected AI tools", detail: mcp.tools.isEmpty ? "Nothing connected yet" : nil) {
                Menu("Connect AI Tool…") {
                    ForEach(ClipboardMCPSettings.Client.allCases) { client in
                        Button(client.rawValue) { connecting = .init(client: client, name: client.rawValue) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
            ForEach(mcp.tools) { tool in
                AOMSettingRow(tool.name,
                              detail: tool.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used",
                              indent: true) {
                    HStack(spacing: AOMSpace.x3) {
                        HStack(spacing: AOMSpace.x2) {
                            Text("Automation").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                                .accessibilityHidden(true)
                            Toggle("Automation", isOn: Binding(get: { tool.automationAccess == true },
                                set: { mcp.setAutomationAccess($0, for: tool.id) }))
                        }
                        .help("Allow this client to configure named triggers, run their actions and manage floating menus. This can run scripts and control other apps.")
                        Button("Disconnect…") { pendingDisconnect = tool }
                    }
                }
            }
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
    @State private var connectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            Text("Connect \(request.client.rawValue)").font(AOMFont.pageStatus).foregroundStyle(AOMColor.text)
            if let token = request.token {
                let instructions = ClipboardMCPSettings.instructions(for: request.client, token: token)
                // 7.6 (Codex SEC01): the token isn't on screen as selectable text; Copy carries it.
                let shown = ClipboardMCPSettings.instructions(for: request.client, token: ClipboardMCPSettings.hiddenToken)
                Text(instructions.summary).font(AOMFont.callout).foregroundStyle(AOMColor.text)
                ScrollView(showsIndicators: false) {
                    Text(shown.snippet).font(AOMFont.mono).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(AOMSpace.x3)
                }
                .frame(height: request.client == .claudeCode || request.client == .codex
                       ? AOMFeatureSize.snippetShort : AOMFeatureSize.snippetTall)
                .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                Text("Copy puts the setup with its token on the clipboard once: marked private, so clipboard history (AOM's too) leaves it out, and cleared after 90 seconds unless you copy something else. The token is stored only as a hash.")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied ? "Copied" : "Copy with Token") {
                        ClipboardMCPSettings.copyPrivately(instructions.snippet)
                        copied = true
                    }
                    Spacer()
                    Button("Done") { done() }.keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle())
                }
            } else {
                TextField("Name (e.g. My AI Tool)", text: $request.name).textFieldStyle(.roundedBorder)
                if let connectError {
                    Text(connectError).font(AOMFont.caption).foregroundStyle(AOMColor.dangerText)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        do {
                            request.token = try ClipboardMCPSettings.shared.connect(name: request.name, client: request.client.rawValue)
                            connectError = nil
                        } catch {
                            connectError = error.localizedDescription
                        }
                    }.keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle())
                }
            }
        }
        .padding(AOMSpace.x6).frame(width: AOMFeatureSize.sheetWide)
    }
}
