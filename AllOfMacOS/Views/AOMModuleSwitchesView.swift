import SwiftUI

/// 7.3: Settings › General › Modules — each module's switch, what it does,
/// and the launcher shown as always on (DeepSeek v2 §5.2: no switch to
/// turn off the launcher, Ask AI, snippets and Kill Apps by mistake).
struct AOMModuleSwitchesRows: View {
    @ObservedObject private var switches = AOMModuleSwitches.shared
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "command.square")
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launcher").font(AOMFont.body)
                    Text("⌥Space, Ask AI, snippets, Kill Apps — the rest of AOM is reached through it")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x3)
                Text("Always on").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(AOMColor.textSecondary.opacity(0.12)))
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .accessibilityElement(children: .combine)
            ForEach(AOMModuleSwitch.allCases) { module in
                row(module)
                    .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
            }
            if let refusal {
                Text(refusal).font(AOMFont.caption).foregroundStyle(AOMColor.warningText)
                    .padding(.horizontal, AOMSpace.rowInset).padding(.bottom, AOMSpace.x2)
            }
            Text("Off stops what the module watches and runs in the background, at once and without a restart; its settings are kept for when you turn it back on.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AOMSpace.rowInset).padding(.vertical, AOMSpace.x2)
        }
    }

    private func row(_ module: AOMModuleSwitch) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: module.symbol)
                .foregroundStyle(switches.isOn(module) ? AOMColor.text : AOMColor.textTertiary)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(AOMFont.body)
                Text(module.detail + (module.runsInBackground ? "" : " · nothing runs until you use it"))
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                #if DEBUG
                if let counter = switches.counters[module] {
                    Text("started \(counter.starts) · stopped \(counter.stops)").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                }
                #endif
            }
            Spacer(minLength: AOMSpace.x3)
            Toggle(module.title, isOn: Binding(get: { switches.isOn(module) }, set: { on in
                refusal = switches.set(module, on: on)
            }))
            .labelsHidden()
            .toggleStyle(AOMRowSwitchStyle())
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
    }
}
