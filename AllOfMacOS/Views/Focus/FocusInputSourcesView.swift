import SwiftUI

/// Per-app input sources (Input Source Pro): Terminal always in ABC,
/// KakaoTalk always in 2-Set Korean, and optionally the last source used in
/// every other app.
struct FocusInputSourcesSection: View {
    @ObservedObject var controller: FocusInputSourceController
    @ObservedObject var lists: FocusListsStore
    @ObservedObject var settings: FocusSettingsStore
    let remove: (FocusInputSourceRule) -> Void
    let added: (Int) -> Void

    static let help = "When an app comes to the front, Focus selects its input source. It never switches while a password field has the keyboard (secure input), while AOM is paused, or for an app AOM is paused for. With Korean, Chinese, Japanese or Vietnamese sources, macOS sometimes shows the new source in the menu bar while the first keys still type in the old one; clicking in the window fixes it."

    var body: some View {
        let options = settings.settings
        let rules = lists.lists.inputSourceRules
        AOMSection("Input sources", detail: rules.isEmpty ? nil : "\(rules.count)", help: Self.help) {
            AOMToggleRow("Switch input sources by app", detail: "Each app gets its keyboard language when it comes to the front",
                         symbol: "keyboard", isOn: $settings.settings.inputSourcesEnabled)
            if rules.isEmpty {
                AOMInlineEmpty(symbol: "character.bubble", message: "No apps yet. For example, Terminal in ABC and KakaoTalk in Korean.",
                               actionTitle: "Add Suggestions") {
                    added(controller.addSuggestedRules())
                }
                .overlay(alignment: .top) { AOMRowDivider() }
            } else {
                ForEach(rules) { rule in
                    FocusInputSourceRuleRow(rule: rule, sources: controller.sources,
                                            sourceName: controller.name(for: rule.sourceID),
                                            select: { lists.setInputSourceRule(bundleID: rule.bundleID, appName: rule.appName, sourceID: $0) },
                                            remove: { remove(rule) })
                }
            }
            HStack(spacing: AOMSpace.x2) {
                FocusAddAppMenu(excluded: Set(rules.map(\.bundleID))) { app in
                    let source = controller.sources.first(where: \.isLatinLayout)?.id ?? controller.sources.first?.id
                    guard let source else { return }
                    lists.setInputSourceRule(bundleID: app.bundleID, appName: app.name, sourceID: source)
                }
                .disabled(controller.sources.isEmpty)
                if !rules.isEmpty {
                    Button("Add Suggestions") { added(controller.addSuggestedRules()) }
                        .help("Adds Terminal, code editors and KakaoTalk if they're installed")
                }
                Spacer(minLength: AOMSpace.x2)
                if let last = controller.lastSwitch {
                    Text("\(last.app) → \(last.source)")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .help("The last switch, at \(last.date.formatted(date: .omitted, time: .shortened))")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .overlay(alignment: .top) { AOMRowDivider() }
            AOMToggleRow("Remember the source in other apps", detail: "Apps without a rule get back the one used there last",
                         symbol: "clock.arrow.circlepath", isOn: $settings.settings.remembersInputSources)
                .disabled(!options.inputSourcesEnabled)
        }
        .onAppear { controller.reloadSources() }
    }
}

struct FocusInputSourceRuleRow: View {
    let rule: FocusInputSourceRule
    let sources: [FocusInputSource]
    let sourceName: String
    let select: (String) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            FocusAppIconView(bundleID: rule.bundleID)
            Text(rule.appName)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
            Spacer(minLength: AOMSpace.x2)
            Picker("Input source for \(rule.appName)", selection: Binding(get: { rule.sourceID }, set: select)) {
                if !sources.contains(where: { $0.id == rule.sourceID }) {
                    Text("\(sourceName) (not enabled)").tag(rule.sourceID)
                }
                ForEach(sources) { source in Text(source.name).tag(source.id) }
            }
            .labelsHidden()
            .fixedSize()
            AOMIconButton("minus.circle", label: "Remove \(rule.appName)", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .frame(minHeight: AOMSize.rowStandard)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .contextMenu { Button("Remove \(rule.appName)", action: remove) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.appName), \(sourceName)")
    }
}
