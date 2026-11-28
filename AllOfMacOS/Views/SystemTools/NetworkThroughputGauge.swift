import SwiftUI

/// 7.22: two large live figures (down, up) over a 60-second sparkline.
struct NetworkThroughputGauge: View {
    @StateObject private var throughput = NetworkThroughput()

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x6) {
                figure("Download", NetworkThroughput.format(throughput.current.received), symbol: "arrow.down", tint: AOMColor.accent)
                figure("Upload", NetworkThroughput.format(throughput.current.sent), symbol: "arrow.up", tint: AOMColor.success)
                Spacer()
                Text("Last 60 s").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
            }
            let samples = throughput.samples
            Canvas { context, size in
                guard samples.count > 1 else { return }
                let peak = max(1, samples.map { max($0.received, $0.sent) }.max() ?? 1)
                func path(_ value: (NetworkThroughput.Sample) -> Double) -> Path {
                    var path = Path()
                    for (index, sample) in samples.enumerated() {
                        let x = size.width * CGFloat(index) / CGFloat(NetworkThroughput.window - 1)
                        let y = size.height * (1 - CGFloat(value(sample) / peak))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    return path
                }
                context.stroke(path { $0.received }, with: .color(AOMColor.accent), lineWidth: 1.5)
                context.stroke(path { $0.sent }, with: .color(AOMColor.success), lineWidth: 1.5)
            }
            .frame(height: 44)
            .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .accessibilityHidden(true)
        }
        .onAppear { throughput.start() }
        .onDisappear { throughput.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network: download \(NetworkThroughput.format(throughput.current.received)), upload \(NetworkThroughput.format(throughput.current.sent))")
    }

    private func figure(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol).font(AOMFont.caption).foregroundStyle(tint)
            Text(value).font(AOMFont.metricLarge)
        }
    }
}

/// 7.23: the busiest apps on the network right now, from nettop.
struct AppTrafficList: View {
    @StateObject private var traffic = AppTraffic()

    var body: some View {
        Group {
            if let problem = traffic.problem {
                AOMSettingRow("Couldn't read traffic by app", detail: problem) { Button("Try Again") { traffic.refresh() } }
            } else if traffic.rows.isEmpty {
                AOMSettingRow("No app is using the network", detail: "Updated every 3 seconds") { EmptyView() }
            } else {
                ForEach(traffic.rows) { row in
                    HStack(spacing: AOMSpace.x3) {
                        Text(row.name).font(AOMFont.body).lineLimit(1)
                        Text("\(row.pid)").font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textTertiary)
                        Spacer()
                        Label(NetworkThroughput.format(row.received), systemImage: "arrow.down")
                            .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.accent)
                            .frame(width: 96, alignment: .trailing)
                        Label(NetworkThroughput.format(row.sent), systemImage: "arrow.up")
                            .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.successText)
                            .frame(width: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, AOMSpace.rowInset)
                    .frame(minHeight: AOMSize.rowStandard)
                    .overlay(alignment: .top) { AOMRowDivider() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .onAppear { traffic.start() }
        .onDisappear { traffic.stop() }
    }
}
