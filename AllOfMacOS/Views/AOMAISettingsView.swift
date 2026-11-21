import AppKit
import SwiftUI

/// Settings › AI (7.0): which model the launcher asks, how hard it thinks,
/// and each provider's key, address and models. Keys go to the Keychain
/// and are shown masked; nothing here is sent anywhere until a question is.
struct AOMAISettingsView: View {
    @ObservedObject private var chat = PaletteAIChat.shared
    @State private var effort = AOMAIConfig.effort
    @State private var instructions = AOMAIConfig.customInstructions
    @State private var recordsMode = AOMAIRecordsMode.current
    @State private var onDeviceReadsMac = AOMAIRecordsMode.onDeviceReadsMac
    @State private var importing = false
    @State private var importResult: String?
    @State private var refresh = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                defaults
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    HStack {
                        AOMSectionTitle("Providers", detail: "Ready providers appear in the launcher's model menu (⌘P).")
                        Spacer()
                        Button {
                            importing = true
                            Task {
                                let found = await AOMAIConfig.importFromShell()
                                importing = false
                                importResult = found.isEmpty ? "No AI keys found in your shell environment."
                                    : "Imported: " + found.joined(separator: ", ")
                                refresh &+= 1
                            }
                        } label: {
                            if importing { ProgressView().controlSize(.small) } else { Text("Import from Shell…") }
                        }
                        .help("Reads ANTHROPIC_API_KEY, OPENAI_API_KEY, DEEPSEEK_API_KEY (and OpenAI's base URL and model) from your login shell into the Keychain")
                        .disabled(importing)
                    }
                    if let importResult {
                        Text(importResult).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(AOMAIProvider.allCases) { provider in
                            AOMAIProviderSettingsRow(provider: provider, refresh: refresh)
                            if provider != AOMAIProvider.allCases.last { Divider().padding(.leading, 52) }
                        }
                    }
                    .aomContentCard(radius: AOMCraftRadius.card, padding: 0)
                }
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("Your instructions", detail: "Added to every question (tone, language, what you do).")
                    TextEditor(text: $instructions)
                        .font(AOMFont.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .aomContentCard(radius: AOMCraftRadius.card, padding: 0)
                        .onChange(of: instructions) { _, value in AOMAIConfig.customInstructions = value }
                }
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("Your Mac's records", detail: "What a question may read — only what it names.")
                    VStack(alignment: .leading, spacing: AOMSpace.x2) {
                        Picker("Records", selection: $recordsMode) {
                            Text("Only what a question mentions").tag(AOMAIRecordsMode.mentions)
                            Text("Never").tag(AOMAIRecordsMode.never)
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: recordsMode) { _, value in AOMAIRecordsMode.current = value }
                        Text("Write @wiki, @memories, @docs (@mac is all three), @claude, @codex, @chats, @shell, @ssh, @files (a folder you choose, or @~/path) or @clip in a question, or press ⌘⇧M in Ask AI to choose them on the Records screen (there ⌘⇧M adds the last question's records again). A question without one reads nothing. What it reads goes to the model you chose; the line under each answer says where it went and what was read. Private keys, keychains and credential files are never opened, and tokens and passwords in results are hidden.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(isOn: $onDeviceReadsMac) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("On-device models may read @mac without a mention")
                                Text("Only a local Ollama model on 127.0.0.1. The Local Proxy forwards to other services (its Haiku route goes to DeepSeek), so it always counts as outside this Mac.")
                                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(recordsMode == .never)
                        .onChange(of: onDeviceReadsMac) { _, value in AOMAIRecordsMode.onDeviceReadsMac = value }
                    }
                    .padding(AOMSpace.x3)
                    .aomContentCard(radius: AOMCraftRadius.card, padding: 0)
                }
                Text("Agents (Claude Code, Codex) use your own subscription through their CLI and stay read-only in the launcher; ⌘J continues the conversation in Terminal, where they can edit and run with your permission. AOM never reads their sign-in.")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AOMSpace.x4)
            .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
        }
        .task { await AOMAIConfig.probeLocalProxy(); refresh &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: AOMAIConfig.didChange)) { _ in refresh &+= 1 }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Ask AI", detail: "⇥ in the launcher asks the model below; ⌘P switches it there too.")
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                HStack {
                    Text("Model")
                    Spacer()
                    AOMAIModelMenu(chat: chat)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Effort")
                        Text("Claude 5 models: how long they think before answering.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    }
                    Spacer()
                    Picker("Effort", selection: $effort) {
                        ForEach(AOMAIConfig.Effort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: effort) { _, value in AOMAIConfig.effort = value }
                }
            }
            .aomContentCard(radius: AOMCraftRadius.card, padding: 14)
        }
        .id(refresh)
    }
}

private struct AOMAIProviderSettingsRow: View {
    let provider: AOMAIProvider
    let refresh: Int
    @State private var key = ""
    @State private var baseURL = ""
    @State private var editingKey = false
    @State private var fetching = false
    @State private var message: String?
    @State private var expanded = false

    var body: some View {
        let ready = AOMAIConfig.isReady(provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AOMAIProviderGlyph(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.title).font(AOMFont.body.weight(.medium))
                        if provider.isAgent {
                            Text("Agent").font(AOMFont.badge.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(AOMCraftColor.well, in: Capsule())
                        }
                    }
                    Text(status(ready: ready)).font(AOMFont.caption)
                        .foregroundStyle(ready ? AOMColor.successText : AOMColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if hasDetails {
                    Button(expanded ? "Done" : (ready ? "Edit" : "Set Up")) { expanded.toggle() }
                        .controlSize(.small)
                }
            }
            if expanded { details }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { baseURL = AOMAIConfig.baseURL(for: provider) }
        .id(refresh)
    }

    private var hasDetails: Bool { !provider.isAgent && provider != .apple }

    private func status(ready: Bool) -> String {
        switch provider {
        case .apple: return AOMAppleIntelligence.status
        case .anthropic, .openAI, .deepSeek:
            return AOMAIKeychain.key(for: provider).map { "Key saved (\(AOMAIKeychain.masked($0))) · \(modelCount) models" } ?? "No API key"
        case .localProxy: return ready ? "Answering at \(AOMAIConfig.baseURL(for: provider))" : "Nothing at \(AOMAIConfig.baseURL(for: provider))"
        case .ollama: return ready ? "\(modelCount) local models" : "Not running, or no models fetched"
        case .claudeCode: return PaletteAIProvider.claude.executable.map { "Installed — \($0)" } ?? "Not installed"
        case .codex: return PaletteAIProvider.codex.executable.map { "Installed — \($0)" } ?? "Not installed"
        case .deepSeekHarness: return AOMDeepSeekHarness.appURL.map { "Installed — \($0.path) · \(AOMDeepSeekHarness.version)" } ?? "Not installed"
        }
    }

    private var modelCount: Int { AOMAIConfig.models(for: provider).count }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider.needsKey || provider == .localProxy {
                HStack {
                    SecureField(provider.needsKey ? "API key" : "API key (optional)", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if AOMAIKeychain.hasKey(for: provider) {
                        Button("Remove") { AOMAIKeychain.setKey(nil, for: provider); message = "Key removed" }
                    }
                }
                if let url = provider.keyHelpURL {
                    Link("Get a key…", destination: url).font(AOMFont.caption)
                }
            }
            HStack {
                TextField("Address", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(AOMFont.callout.monospaced())
                    .onSubmit { AOMAIConfig.setBaseURL(baseURL, for: provider) }
                Button("Use") { AOMAIConfig.setBaseURL(baseURL, for: provider); message = "Address saved" }
                    .disabled(baseURL == AOMAIConfig.baseURL(for: provider))
                Button("Fetch Models") { fetchModels() }.disabled(fetching)
                if fetching { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary) }
            let models = AOMAIConfig.models(for: provider)
            if !models.isEmpty {
                Text(models.prefix(8).map(\.title).joined(separator: " · ") + (models.count > 8 ? " …" : ""))
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(2)
            }
        }
        .padding(.leading, 40)
    }

    private func saveKey() {
        let saved = AOMAIKeychain.setKey(key, for: provider)
        message = saved ? "Saved to the Keychain" : "The Keychain refused the key"
        key = ""
    }

    private func fetchModels() {
        AOMAIConfig.setBaseURL(baseURL, for: provider)
        fetching = true
        Task {
            do {
                let models = try await AOMAIClient.fetchModels(provider)
                if !models.isEmpty { AOMAIConfig.setFetchedModels(models, for: provider) }
                message = models.isEmpty ? "No chat models listed" : "\(models.count) models"
                if provider == .localProxy { await AOMAIConfig.probeLocalProxy() }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            fetching = false
        }
    }
}
