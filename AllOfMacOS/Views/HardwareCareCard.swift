import SwiftUI

struct HardwareCareCard: View {
    @ObservedObject private var model = HardwareCareModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.aomPageActivity) private var pageActivity

    var body: some View {
        AOMSectionCard("Battery & Hardware", symbol: "battery.75percent") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    ForEach(model.sample.sensors) { sensor in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sensor.name).font(.caption).foregroundStyle(.secondary)
                            Text("\(sensor.value, specifier: "%.1f") \(sensor.unit)").monospacedDigit()
                        }.help("SMC channel: \(sensor.id). Availability and meaning vary by model.")
                    }
                }
                if model.sample.sensors.isEmpty {
                    Text("No supported SMC temperature or power channels on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.power?.percent != nil || model.sample.batteryPercent != nil {
                    BatteryCareSection(model: model)
                    Divider()
                }
                HStack {
                    if model.sample.fanCount == 0 {
                        Text("This Mac has no fans.").foregroundStyle(.secondary)
                    } else if model.sample.fans.isEmpty {
                        Text("Fan telemetry unavailable.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sample.fans) { fan in
                            Text("Fan \(fan.id + 1): \(fan.rpm, specifier: "%.0f") RPM").monospacedDigit()
                        }
                        Spacer()
                        Picker("Fans", selection: Binding(get: { model.fan }, set: model.setFan)) {
                            Text("Auto").tag(FanPreset.auto)
                            Text("Quiet").tag(FanPreset.quiet)
                            Text("Max").tag(FanPreset.max)
                        }.frame(maxWidth: 240).disabled(model.busy)
                    }
                }
                Text("Quiet uses the verified minimum RPM and returns to Auto at 75 °C, high thermal pressure, or missing CPU/GPU readings. Max uses each fan’s verified maximum.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(model.helperStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.helperReady {
                        Button("Enable Hardware Helper…") { model.installHelper() }.disabled(model.busy)
                    }
                    Button("Refresh Helper Status") { model.refreshHelper() }
                }
                if !model.message.isEmpty { Text(model.message).font(.caption).textSelection(.enabled) }
                if model.busy { ProgressView().controlSize(.small) }
            }
        }
        // Sampled while System Tools is the selected page and on screen.
        .aomOnPageVisibilityChange { visible in
            if visible { model.appear() } else { model.disappear() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active && pageActivity.isActive { model.refreshHelper() } }
    }
}


/// 6.10: AlDente's controls on what macOS 27 firmware still allows — the
/// native charge limit (80–100 %), Hold Here (the limit at this level: the
/// Mac runs on the adapter), Top Up, and Discharge (the adapter cut through
/// the helper) — with the power flow and the battery's health.
struct BatteryCareSection: View {
    @ObservedObject var model: HardwareCareModel
    static let limits = HardwareCareModel.limits

    private var percent: Int? { model.power?.percent ?? model.sample.batteryPercent }

    /// Pure enough to read: what the battery is doing and why.
    static func stateLine(power: BatteryTelemetry?, limit: Int?, discharging: Int?, topUp: Bool) -> String {
        guard let power else { return "Reading the battery…" }
        if let target = discharging { return "Discharging to \(target)% — the adapter is cut" }
        if !power.externalConnected { return "On battery" }
        if power.isCharging { return topUp ? "Charging to 100% (top up)" : "Charging" + (limit.map { " to \($0)%" } ?? "") }
        if let limit, let percent = power.percent, percent >= limit - 1 { return "Not charging — held at \(limit)%, running on the adapter" }
        if power.fullyCharged || power.percent == 100 { return "Fully charged" }
        return "Not charging" + (power.notChargingReason != nil ? " (macOS is managing the charge)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(alignment: .center, spacing: AOMSpace.x3) {
                Image(systemName: model.power?.isCharging == true ? "battery.100percent.bolt"
                      : model.dischargeTarget != nil ? "battery.50percent" : "battery.75percent")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(model.dischargeTarget != nil ? AOMColor.warning : AOMColor.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(percent.map { "\($0)%" } ?? "—").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(Self.stateLine(power: model.power, limit: model.nativeLimit, discharging: model.dischargeTarget,
                                        topUp: model.topUpRestore != nil))
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer()
                if let power = model.power {
                    powerFlow(power)
                }
            }
            HStack(spacing: AOMSpace.x2) {
                Text("Charge limit").font(AOMFont.callout.weight(.medium))
                Picker("Charge limit", selection: Binding(get: { model.nativeLimit ?? 0 },
                                                          set: { model.setLimit($0 == 0 ? nil : $0) })) {
                    Text("Off").tag(0)
                    ForEach(Self.limits, id: \.self) { Text("\($0)%").tag($0) }
                }
                .aomSegmented().labelsHidden().frame(maxWidth: 360)
                .disabled(model.busy || !model.nativeAvailable)
                Spacer()
            }
            HStack(spacing: AOMSpace.x2) {
                Button { model.holdHere() } label: { Label("Hold Here", systemImage: "pause.circle") }
                    .help("Stop charging at this level (5% steps, 80% at least) and run on the adapter")
                    .disabled(model.busy || !model.nativeAvailable)
                if model.topUpRestore != nil {
                    Button { model.setLimit(model.topUpRestore) } label: { Label("End Top Up", systemImage: "xmark.circle") }
                } else {
                    Button { model.topUp() } label: { Label("Top Up to 100%", systemImage: "arrow.up.circle") }
                        .help("Charge to 100% once; your limit comes back when full or unplugged")
                        .disabled(model.busy || !model.canTopUp)
                }
                if let target = model.dischargeTarget {
                    Button { model.stopDischarge() } label: { Label("Stop Discharge (\(target)%)", systemImage: "stop.circle") }
                } else {
                    Menu {
                        ForEach([80, 70, 60, 50, 40], id: \.self) { target in
                            Button("Discharge to \(target)%") { model.discharge(to: target) }
                                .disabled((percent ?? 0) <= target)
                        }
                    } label: { Label("Discharge…", systemImage: "arrow.down.circle") }
                    .fixedSize()
                    .help("Cut the adapter so the Mac runs on its battery down to a level (needs the hardware helper)")
                    .disabled(model.busy || !model.helperReady)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let power = model.power {
                HStack(spacing: AOMSpace.x3) {
                    if let health = power.health { Label("Health \(health)%", systemImage: "heart") }
                    if let cycles = power.cycleCount { Label("\(cycles) cycles", systemImage: "arrow.triangle.2.circlepath") }
                    if let temperature = model.sample.batteryTemperature { Label("\(temperature, specifier: "%.1f") °C", systemImage: "thermometer.medium") }
                    if let rating = power.adapterRating, power.externalConnected { Label("\(rating) W adapter", systemImage: "powerplug") }
                }
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
            if model.helperOutdated {
                HStack {
                    Label("The battery helper running now is from an older AOM; restart it once to use Discharge.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AOMColor.warningText)
                    Button("Restart Helper") { model.restartHelper() }.controlSize(.small)
                }.font(AOMFont.caption)
            }
            Text("macOS 27 firmware no longer lets apps pause charging below 80% (Apple locked those controls), so limits and Hold use macOS's own charge limit, which stays after AOM quits. Discharge cuts the adapter through the helper; it ends at the target, on sleep or if AOM quits.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func powerFlow(_ power: BatteryTelemetry) -> some View {
        HStack(spacing: AOMSpace.x2) {
            flowItem("powerplug", power.externalConnected ? power.adapterWatts : nil, "Adapter")
            Image(systemName: "arrow.right").foregroundStyle(AOMColor.textTertiary)
            flowItem("laptopcomputer", power.systemWatts, "Mac")
            flowItem(power.batteryWatts ?? 0 >= 0 ? "battery.100percent.bolt" : "battery.25percent", power.batteryWatts, "Battery", signed: true)
        }
        .font(AOMFont.caption)
        .accessibilityElement(children: .combine)
    }

    private func flowItem(_ symbol: String, _ watts: Double?, _ name: String, signed: Bool = false) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol).foregroundStyle(AOMColor.textSecondary)
            Text(watts.map { String(format: signed ? "%+.1f W" : "%.1f W", $0) } ?? "—").monospacedDigit()
            Text(name).foregroundStyle(AOMColor.textTertiary)
        }
        .frame(minWidth: 54)
    }
}
