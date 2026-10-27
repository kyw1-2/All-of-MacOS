import SwiftUI

/// Reusable samples: one-handed paths are shown as native lightweight thumbnails.
enum DrawingPatternLibrary {
    struct Template: Identifiable {
        let name: String
        let samples: [DrawingPoint]
        var id: String { name }
    }
    private static func line(_ vertices: [(Double,Double)]) -> [DrawingPoint] {
        zip(vertices, vertices.dropFirst()).flatMap { a, b in
            (0..<10).map { index in
                let t = Double(index) / 10
                return DrawingPoint(x: a.0 + (b.0-a.0)*t, y: a.1 + (b.1-a.1)*t)
            }
        } + [DrawingPoint(x: vertices.last?.0 ?? 0, y: vertices.last?.1 ?? 0)]
    }
    static let templates: [Template] = [
        Template(name: "Left", samples: line([(0.88,0.5),(0.12,0.5)])),
        Template(name: "Right", samples: line([(0.12,0.5),(0.88,0.5)])),
        Template(name: "Up", samples: line([(0.5,0.88),(0.5,0.12)])),
        Template(name: "Down", samples: line([(0.5,0.12),(0.5,0.88)])),
        Template(name: "L", samples: line([(0.25,0.15),(0.25,0.82),(0.83,0.82)])),
        Template(name: "Z", samples: line([(0.15,0.2),(0.82,0.2),(0.15,0.8),(0.82,0.8)])),
        Template(name: "M", samples: line([(0.12,0.84),(0.12,0.18),(0.5,0.58),(0.85,0.18),(0.85,0.84)])),
        Template(name: "Check", samples: line([(0.16,0.53),(0.40,0.78),(0.84,0.20)])),
        Template(name: "Circle", samples: (0..<49).map { i in
            let a = -Double.pi/2 + Double(i) * Double.pi * 2 / 48
            return DrawingPoint(x: 0.5+0.38*cos(a), y: 0.5+0.38*sin(a))
        }),
        Template(name: "Rectangle", samples: line([(0.18,0.18),(0.82,0.18),(0.82,0.82),(0.18,0.82),(0.18,0.18)]))
    ]
}

/// Path begins at the first point; direction remains important (Left != Right).
struct DrawingStrokePreview: View {
    let sample: [DrawingPoint]
    var tint: Color = .accentColor
    var body: some View {
        Canvas { context, size in
            guard sample.count >= 2 else { return }
            var path = Path()
            let points = sample.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            let start = CGRect(x: points[0].x-4, y: points[0].y-4, width: 8, height: 8)
            context.fill(Path(ellipseIn: start), with: .color(.green))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.25)))
    }
}

struct DrawingStrokePad: View {
    let onComplete: ([DrawingPoint]) -> Void
    @State private var current: [DrawingPoint] = []
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                }.stroke(.secondary.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                if current.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "pencil.tip.crop.circle").font(.system(size: 28))
                        Text("Draw a single continuous stroke").font(.caption)
                    }.foregroundStyle(.tertiary)
                }
                DrawingStrokePreview(sample: current)
                    .opacity(current.isEmpty ? 0 : 1)
                    .allowsHitTesting(false)
                    .padding(2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    let x = max(0, min(1, Double(event.location.x / max(1, geometry.size.width))))
                    let y = max(0, min(1, Double(event.location.y / max(1, geometry.size.height))))
                    if current.count < 256 { current.append(DrawingPoint(x:x, y:y)) }
                }
                .onEnded { _ in
                    let sample = current
                    current.removeAll()
                    onComplete(sample)
                })
        }
        .accessibilityLabel("Draw a gesture by dragging here")
    }
}

struct DrawingPatternComposer: View {
    @Binding var name: String
    @Binding var samples: [[DrawingPoint]]
    @Binding var certainty: Double
    @Binding var ignoreDirection: Bool
    @State private var testing = false
    @State private var testFeedback: String?
    @State private var warning: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a starter shape, or draw your own")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(DrawingPatternLibrary.templates) { template in
                        Button {
                            name = template.name
                            samples = [DrawingRecognizer.normalized(template.samples) ?? template.samples]
                            warning = nil
                        } label: {
                            VStack(spacing: 4) {
                                DrawingStrokePreview(sample: template.samples)
                                    .frame(width: 78, height: 62)
                                Text(template.name).font(.caption.weight(.medium))
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(name == template.name ? Color.accentColor.opacity(0.12) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(name == template.name ? Color.accentColor : Color.clear))
                        }.buttonStyle(.plain)
                    }
                }.padding(2)
            }.frame(height: 106)
            HStack {
                Text(testing ? "Test recognition (does not execute actions)" : "Record gesture variations")
                    .font(.headline)
                Spacer()
                Text("\(samples.count)/3 saved").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Record variations") { testing = false; testFeedback = nil }
                    .buttonStyle(.bordered)
                    .tint(testing ? .secondary : .accentColor)
                Button("Test recognition") { testing = true; testFeedback = nil }
                    .buttonStyle(.bordered)
                    .tint(testing ? .accentColor : .secondary)
                    .disabled(samples.isEmpty)
                Spacer()
            }
            DrawingStrokePad { path in
                if let normalized = DrawingRecognizer.normalized(path) {
                    if testing {
                        let distances = samples.compactMap {
                            DrawingRecognizer.score(normalized, template: $0, directionIndependent: ignoreDirection)
                        }
                        if let best = distances.min() {
                            let match = DrawingRecognizer.certainty(from: best)
                            testFeedback = String(format: "Recognition: %.0f%% · required %.0f%% · %@",
                                 match * 100, certainty * 100,
                                 match >= certainty && best <= 0.21 ? "PASS" : "TRY AGAIN")
                        }
                    } else {
                        if samples.count >= 3 { samples.removeFirst() }
                        samples.append(normalized)
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Custom drawing" }
                        warning = nil
                        testFeedback = "Variation saved. Draw it again for improved reliability."
                    }
                } else { warning = "Draw one continuous, larger stroke (at least 8 points)." }
            }
            .frame(height: 195)
            if let testFeedback { Text(testFeedback).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                ForEach(Array(samples.enumerated()), id: \.offset) { i, sample in
                    DrawingStrokePreview(sample: sample)
                        .frame(width: 80, height: 55)
                        .overlay(alignment: .topTrailing) {
                            Button { samples.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove this sample")
                                .accessibilityLabel("Remove sample \(i + 1)")
                        }
                }
                Spacer()
                Button("Clear") { samples = []; warning = nil }
                    .disabled(samples.isEmpty)
            }
            TextField("Drawing name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Required recognition certainty")
                    .font(.caption)
                Slider(value: $certainty, in: 0.5...0.9, step: 0.05)
                Text("\(Int(certainty * 100))%")
                    .font(.caption.monospacedDigit()).frame(width: 35)
            }
            Toggle("Drawing direction does not matter", isOn: $ignoreDirection)
                .font(.caption)
            Label("Perform on trackpad: hold ⌃ Control + ⌥ Option, drag the pointer with one finger, then release.", systemImage: "hand.draw")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The inspector stays compact; a focused editor sheet has room for 3 samples.
struct DrawingSamplesConfiguration: View {
    let trigger: Trigger
    let save: (String, [[DrawingPoint]], Double, Bool) -> Void
    @State private var showingEditor = false
    var body: some View {
        GroupBox("Drawing Gesture") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if let first = trigger.drawingSamples.first {
                        DrawingStrokePreview(sample: first).frame(width: 94, height: 82)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(trigger.input.displayName).font(.subheadline.weight(.semibold))
                        Text("\(trigger.drawingSamples.count) variations · \(Int(trigger.drawingCertainty*100))% certainty")
                            .font(.caption).foregroundStyle(.secondary)
                        if trigger.drawingIgnoreDirection {
                            Text("Direction ignored").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { showingEditor = true } label: {
                    Label("Configure Drawing…", systemImage: "pencil.and.scribble")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Text("Control + Option + drag to draw. Edit samples, test recognition or adjust certainty.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .sheet(isPresented: $showingEditor) {
            DrawingEditorSheet(trigger: trigger, save: save)
        }
    }
}

private struct DrawingEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String, [[DrawingPoint]], Double, Bool) -> Void
    @State private var name: String
    @State private var samples: [[DrawingPoint]]
    @State private var certainty: Double
    @State private var ignoreDirection: Bool
    init(trigger: Trigger, save: @escaping (String, [[DrawingPoint]], Double, Bool) -> Void) {
        self.save = save
        _name = State(initialValue: trigger.input.displayName)
        _samples = State(initialValue: trigger.drawingSamples)
        _certainty = State(initialValue: trigger.drawingCertainty)
        _ignoreDirection = State(initialValue: trigger.drawingIgnoreDirection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure Drawing Gesture").font(.title2.bold())
            ScrollView(showsIndicators: false) {
                DrawingPatternComposer(name: $name, samples: $samples,
                                       certainty: $certainty, ignoreDirection: $ignoreDirection)
                    .padding(4)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Drawing") {
                    save(name, samples, certainty, ignoreDirection)
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || samples.isEmpty)
            }
        }
        .padding(20).frame(width: 710, height: 680)
    }
}
