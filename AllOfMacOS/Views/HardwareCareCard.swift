import SwiftUI

struct HardwareCareCard: View {
    @ObservedObject private var model = HardwareCareModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AOMSectionCard("Battery & Hardware", symbol: "cpu") {
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
                if let percent = model.sample.batteryPercent {
                    HStack {
                        Label("\(percent)%", systemImage: model.sample.charging ? "battery.100percent.bolt" : "battery.100percent")
                        if let temperature = model.sample.batteryTemperature { Text("\(temperature, specifier: "%.1f") °C") }
                        if let watts = model.sample.batteryWatts { Text("\(watts, specifier: "%+.1f") W battery flow") }
                        Spacer()
                        Picker("Charging", selection: Binding(get: { model.battery }, set: model.setBattery)) {
                            Text("System default").tag(BatteryCareMode.off)
                            Text("80% limit").tag(BatteryCareMode.limit80)
                            Text("Bypass").tag(BatteryCareMode.bypass)
                        }.frame(maxWidth: 280).disabled(model.busy)
                    }
                    Text(model.nativeStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Native limits persist in macOS. Helper mode pauses at 80% and resumes at 75%; bypass pauses charging while AC stays connected. Below 20%, normal charging resumes. Helper policies end on sleep or AOM exit.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshHelper() } }
    }
}
