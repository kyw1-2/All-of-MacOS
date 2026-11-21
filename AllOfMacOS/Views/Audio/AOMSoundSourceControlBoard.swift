import AppKit
import SwiftUI

struct AOMAudioAppRowState: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    var volume: Double       // 0.0 ... 4.0 (0% ... 400%)
    var isMuted: Bool
    var peakLevel: Double    // 0.0 ... 1.0
    var outputName: String
    var magicBoostOn: Bool
    var eqBands: [Double]    // 10 bands, -12 ... +12 dB
}

// MARK: - 1. SoundSource 고정 컬럼 앱 믹서 행

// MARK: - 2. 12세그먼트 피크 미터

struct AOMPeakMeterView: View {
    let level: Double
    private let segments = 12

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { idx in
                let threshold = Double(idx + 1) / Double(segments)
                let lit = level >= threshold - 0.05
                let color: Color = idx >= 10 ? .red : (idx >= 8 ? AOMCraftColor.overdriveAmber : .green)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(lit ? color : Color.primary.opacity(0.09))
            }
        }
    }
}

// MARK: - 3. 100% Detent 틱 + 101~400% 앰버 오버드라이브 슬라이더

struct AOMOverdriveSlider: View {
    @Binding var value: Double // 0.0 ... 4.0
    let isMuted: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pos = AOMVolumeScale.position(for: value)
            let fillW = w * pos
            let isBoosted = value > 1

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 6)

                // 100% 기준선 Detent 마크
                Rectangle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 1.5, height: 10)
                    .offset(x: w * 0.6)

                Capsule()
                    .fill(
                        isMuted ? AnyShapeStyle(Color.secondary.opacity(0.4)) :
                        (isBoosted
                            ? AnyShapeStyle(LinearGradient(colors: [.accentColor, AOMCraftColor.overdriveAmber, AOMCraftColor.overdriveHot], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.accentColor))
                    )
                    .frame(width: fillW, height: 6)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(w - 14, w * pos - 7)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let next = AOMVolumeScale.volume(for: drag.location.x / max(1, w))
                        if (value <= 1.0 && next > 1.0) || (value > 1.0 && next == 1.0) {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        value = next
                    }
            )
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: value = AOMVolumeScale.clamped(AOMVolumeScale.clamped(value) - 0.01)
            case .right, .up: value = AOMVolumeScale.clamped(AOMVolumeScale.clamped(value) + 0.01)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...4, step: 0.01) { Text("Volume") }
                .accessibilityValue(Text("\(Int((AOMVolumeScale.clamped(value) * 100).rounded()))%"))
        }
    }
}

enum AOMVolumeScale {
    static func clamped(_ value: Double) -> Double {
        value.isFinite ? max(0, min(4, value)) : 0
    }

    /// 0~100%가 트랙의 60%, 100~400% 오버드라이브가 우측 40%를 차지하는 비선형 매핑
    static func position(for vol: Double) -> Double {
        let v = clamped(vol)
        return v <= 1.0 ? v * 0.6 : 0.6 + ((v - 1.0) / 3.0) * 0.4
    }

    static func volume(for pos: Double) -> Double {
        let p = max(0, min(1, pos))
        if abs(p - 0.6) < 0.02 { return 1.0 } // 100% 자석 스냅(Detent)
        return p <= 0.6 ? p / 0.6 : 1.0 + ((p - 0.6) / 0.4) * 3.0
    }
}

// MARK: - 4. 10-Band EQ 스플라인 응답 커브 캔버스

struct AOMEQCurveCanvas: View {
    @Binding var bands: [Double] // 10 bands, -12 ... +12 dB
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 부드러운 베지어 응답 곡선 배경
                Canvas { ctx, size in
                    guard bands.count == 10 else { return }
                    let midY = size.height * 0.5
                    var zeroLine = Path()
                    zeroLine.move(to: CGPoint(x: 0, y: midY))
                    zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
                    ctx.stroke(zeroLine, with: .color(.primary.opacity(0.1)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                    let pts: [CGPoint] = bands.enumerated().map { idx, db in
                        let x = size.width * (CGFloat(idx) + 0.5) / 10.0
                        let norm = CGFloat(max(-12, min(12, db)) / 12.0)
                        let y = midY - norm * (size.height * 0.36)
                        return CGPoint(x: x, y: y)
                    }

                    var curve = Path()
                    curve.move(to: pts[0])
                    for i in 0..<(pts.count - 1) {
                        let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                        curve.addQuadCurve(to: mid, control: pts[i])
                    }
                    curve.addLine(to: pts.last!)
                    ctx.stroke(curve, with: .color(.accentColor.opacity(0.75)), lineWidth: 2)
                }

                // 10개 인터랙티브 밴드 조절 열
                HStack(spacing: 0) {
                    ForEach(0..<min(10, bands.count), id: \.self) { idx in
                        VStack(spacing: 2) {
                            Spacer()
                            Text(labels[idx])
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let norm = (geo.size.height * 0.5 - drag.location.y) / max(1, geo.size.height * 0.36)
                                    bands[idx] = max(-12, min(12, Double(norm * 12.0)))
                                }
                        )
                        .focusable()
                        .onMoveCommand { direction in
                            switch direction {
                            case .up: bands[idx] = min(12, bands[idx] + 1)
                            case .down: bands[idx] = max(-12, bands[idx] - 1)
                            default: break
                            }
                        }
                        .accessibilityRepresentation {
                            Slider(value: $bands[idx], in: -12...12, step: 1) {
                                Text("\(labels[idx]) Hz")
                            }
                            .accessibilityValue(Text("\(bands[idx], specifier: "%.1f") dB"))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
