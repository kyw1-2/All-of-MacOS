import SwiftUI

private struct ThemeColorKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var themeColor: Color {
        get { self[ThemeColorKey.self] }
        set { self[ThemeColorKey.self] = newValue }
    }
}

struct GesturePreviewView: View {
    let gesture: TrackpadGesture
    @EnvironmentObject var appState: AppState
    @State private var animating = false
    @State private var animationID = UUID()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Trackpad body
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(nsColor: .darkGray).opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                    )

                // Gesture animation, drawn at the original trackpad scale and
                // proportionally downscaled with the body
                gestureAnimation
                    .scaleEffect(2.0 / 3.0)
                    .id(animationID)
            }
            .frame(width: 120, height: 92)
            .clipped()
            .onAppear { startAnimation() }
            .onChange(of: gesture) { _ in restartAnimation() }

            Text(gesture.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .environment(\.themeColor, appState.accentColorChoice.color)
    }

    private func startAnimation() {
        animating = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(AOMDesign.animation(.default)) { animating = true }
        }
    }

    private func restartAnimation() {
        animating = false
        animationID = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(AOMDesign.animation(.default)) { animating = true }
        }
    }

    /// Leading digit of the gesture name is its finger count.
    private var pinchFingerCount: Int {
        Int(gesture.rawValue.prefix(1)) ?? 2
    }
    private var rotateFingerCount: Int {
        Int(gesture.rawValue.prefix(1)) ?? 2
    }

    @ViewBuilder
    private var gestureAnimation: some View {
        switch gesture {
        // Swipes
        case .twoFingerSwipeUp:
            SwipeAnimation(fingerCount: 2, direction: .up, animating: animating)
        case .twoFingerSwipeDown:
            SwipeAnimation(fingerCount: 2, direction: .down, animating: animating)
        case .twoFingerSwipeLeft:
            SwipeAnimation(fingerCount: 2, direction: .left, animating: animating)
        case .twoFingerSwipeRight:
            SwipeAnimation(fingerCount: 2, direction: .right, animating: animating)
        case .threeFingerSwipeUp:
            SwipeAnimation(fingerCount: 3, direction: .up, animating: animating)
        case .threeFingerSwipeDown:
            SwipeAnimation(fingerCount: 3, direction: .down, animating: animating)
        case .threeFingerSwipeLeft:
            SwipeAnimation(fingerCount: 3, direction: .left, animating: animating)
        case .threeFingerSwipeRight:
            SwipeAnimation(fingerCount: 3, direction: .right, animating: animating)
        case .fourFingerSwipeUp:
            SwipeAnimation(fingerCount: 4, direction: .up, animating: animating)
        case .fourFingerSwipeDown:
            SwipeAnimation(fingerCount: 4, direction: .down, animating: animating)
        case .fourFingerSwipeLeft:
            SwipeAnimation(fingerCount: 4, direction: .left, animating: animating)
        case .fourFingerSwipeRight:
            SwipeAnimation(fingerCount: 4, direction: .right, animating: animating)
        case .fiveFingerSwipeUp:
            SwipeAnimation(fingerCount: 5, direction: .up, animating: animating)
        case .fiveFingerSwipeDown:
            SwipeAnimation(fingerCount: 5, direction: .down, animating: animating)
        case .fiveFingerSwipeLeft:
            SwipeAnimation(fingerCount: 5, direction: .left, animating: animating)
        case .fiveFingerSwipeRight:
            SwipeAnimation(fingerCount: 5, direction: .right, animating: animating)

        // Positional one-finger taps reuse the click zone artwork.
        case .oneFingerTapTopLeft: PositionClickAnimation(position: .topLeft, animating: animating)
        case .oneFingerTapTopRight: PositionClickAnimation(position: .topRight, animating: animating)
        case .oneFingerTapTopMiddle: PositionClickAnimation(position: .middleTop, animating: animating)
        case .oneFingerTapBottomLeft: PositionClickAnimation(position: .bottomLeft, animating: animating)
        case .oneFingerTapBottomRight: PositionClickAnimation(position: .bottomRight, animating: animating)
        case .oneFingerTapBottomMiddle: PositionClickAnimation(position: .middleBottom, animating: animating)
        case .oneFingerTapLeftSideMiddle: PositionClickAnimation(position: .middleTop, animating: animating)
        case .oneFingerTapRightSideMiddle: PositionClickAnimation(position: .middleTop, animating: animating)
        case .oneFingerSwipeUpOnLeftEdge, .oneFingerSwipeDownOnLeftEdge:
            SwipeAnimation(fingerCount: 1, direction: gesture == .oneFingerSwipeUpOnLeftEdge ? .up : .down, animating: animating)
        case .oneFingerSwipeUpOnRightEdge, .oneFingerSwipeDownOnRightEdge:
            SwipeAnimation(fingerCount: 1, direction: gesture == .oneFingerSwipeUpOnRightEdge ? .up : .down, animating: animating)
        case .oneFingerSwipeLeftOnTopEdge, .oneFingerSwipeRightOnTopEdge:
            SwipeAnimation(fingerCount: 1, direction: gesture == .oneFingerSwipeRightOnTopEdge ? .right : .left, animating: animating)
        case .oneFingerSwipeLeftOnBottomEdge, .oneFingerSwipeRightOnBottomEdge:
            SwipeAnimation(fingerCount: 1, direction: gesture == .oneFingerSwipeRightOnBottomEdge ? .right : .left, animating: animating)

        // Taps
        case .oneFingerTap:
            TapAnimation(fingerCount: 1, animating: animating)
        case .oneFingerDoubleTap:
            DoubleTapAnimation(fingerCount: 1, animating: animating)
        case .twoFingerTap:
            TapAnimation(fingerCount: 2, animating: animating)
        case .twoFingerDoubleTap:
            DoubleTapAnimation(fingerCount: 2, animating: animating)
        case .threeFingerTap:
            TapAnimation(fingerCount: 3, animating: animating)
        case .threeFingerDoubleTap:
            DoubleTapAnimation(fingerCount: 3, animating: animating)
        case .fourFingerTap:
            TapAnimation(fingerCount: 4, animating: animating)
        case .fourFingerDoubleTap:
            DoubleTapAnimation(fingerCount: 4, animating: animating)
        case .fiveFingerTap:
            TapAnimation(fingerCount: 5, animating: animating)

        // Clicks
        case .twoFingerClick:
            TapAnimation(fingerCount: 2, animating: animating, isClick: true)
        case .threeFingerClick:
            TapAnimation(fingerCount: 3, animating: animating, isClick: true)
        case .fourFingerClick:
            TapAnimation(fingerCount: 4, animating: animating, isClick: true)
        case .fiveFingerClick:
            TapAnimation(fingerCount: 5, animating: animating, isClick: true)

        // Pinch
        case .twoFingerPinchIn, .threeFingerPinchIn, .fourFingerPinchIn, .fiveFingerPinchIn:
            PinchAnimation(fingerCount: pinchFingerCount, pinchIn: true, animating: animating)
        case .twoFingerPinchOut, .threeFingerPinchOut, .fourFingerPinchOut, .fiveFingerPinchOut:
            PinchAnimation(fingerCount: pinchFingerCount, pinchIn: false, animating: animating)

        // Rotate
        case .twoFingerRotateLeft, .threeFingerRotateLeft, .fourFingerRotateLeft, .fiveFingerRotateLeft:
            RotateAnimation(fingerCount: rotateFingerCount, clockwise: false, animating: animating)
        case .twoFingerRotateRight, .threeFingerRotateRight, .fourFingerRotateRight, .fiveFingerRotateRight:
            RotateAnimation(fingerCount: rotateFingerCount, clockwise: true, animating: animating)

        // TipTap
        case .tipTapLeft:
            TipTapAnimation(direction: .left, animating: animating)
        case .tipTapRight:
            TipTapAnimation(direction: .right, animating: animating)
        case .tipTapMiddle:
            TipTapAnimation(direction: .middle, animating: animating)

        // Circle
        case .circleClockwise:
            CircleAnimation(clockwise: true, animating: animating)
        case .circleCounterClockwise:
            CircleAnimation(clockwise: false, animating: animating)

        // Drawings
        case .drawTriangle:
            TriangleDrawAnimation(animating: animating)

        // Edge sliders
        case .leftEdgeSlideUp:
            EdgeDragAnimation(edge: .left, direction: .up, animating: animating)
        case .leftEdgeSlideDown:
            EdgeDragAnimation(edge: .left, direction: .down, animating: animating)
        case .rightEdgeSlideUp:
            EdgeDragAnimation(edge: .right, direction: .up, animating: animating)
        case .rightEdgeSlideDown:
            EdgeDragAnimation(edge: .right, direction: .down, animating: animating)

        // Corner/Position clicks
        case .cornerClickTopLeft:
            PositionClickAnimation(position: .topLeft, animating: animating)
        case .cornerClickTopRight:
            PositionClickAnimation(position: .topRight, animating: animating)
        case .cornerClickBottomLeft:
            PositionClickAnimation(position: .bottomLeft, animating: animating)
        case .cornerClickBottomRight:
            PositionClickAnimation(position: .bottomRight, animating: animating)
        case .middleClickTop:
            PositionClickAnimation(position: .middleTop, animating: animating)
        case .middleClickBottom:
            PositionClickAnimation(position: .middleBottom, animating: animating)

        // Force Touch: same positions as the plain clicks, drawn as a press.
        case .forceClick:
            PositionClickAnimation(position: .middleTop, animating: animating)
        case .forceClickTwoFinger:
            PositionClickAnimation(position: .middleBottom, animating: animating)
        case .forceClickThreeFinger:
            PositionClickAnimation(position: .middleBottom, animating: animating)
        case .cornerForceClickTopLeft:
            PositionClickAnimation(position: .topLeft, animating: animating)
        case .cornerForceClickTopRight:
            PositionClickAnimation(position: .topRight, animating: animating)
        case .cornerForceClickBottomLeft:
            PositionClickAnimation(position: .bottomLeft, animating: animating)
        case .cornerForceClickBottomRight:
            PositionClickAnimation(position: .bottomRight, animating: animating)

        // Touch Start / Long Touch / Release: the resting-finger artwork with the right finger count.
        case .oneFingerTouchStart, .twoFingerTouchStart, .threeFingerTouchStart, .fourFingerTouchStart, .fiveFingerTouchStart:
            TapAnimation(fingerCount: gesture.touchHoldFingerCount ?? 1, animating: animating)
        case .oneFingerLongTouch, .twoFingerLongTouch, .threeFingerLongTouch, .fourFingerLongTouch, .fiveFingerLongTouch:
            TapAnimation(fingerCount: gesture.touchHoldFingerCount ?? 1, animating: animating, isClick: true)
        case .releaseLastFingerAfter1: TapAnimation(fingerCount: 1, animating: animating)
        case .releaseLastFingerAfter2: TapAnimation(fingerCount: 2, animating: animating)
        case .releaseLastFingerAfter3: TapAnimation(fingerCount: 3, animating: animating)
        case .releaseLastFingerAfter4: TapAnimation(fingerCount: 4, animating: animating)
        case .releaseLastFingerAfter5: TapAnimation(fingerCount: 5, animating: animating)
        case .releaseLastFingerRegardless: TapAnimation(fingerCount: 1, animating: animating)
        // Two-finger edge swipes move inward from the named side.
        case .twoFingerSwipeFromLeftEdge: SwipeAnimation(fingerCount: 2, direction: .right, animating: animating)
        case .twoFingerSwipeFromRightEdge: SwipeAnimation(fingerCount: 2, direction: .left, animating: animating)
        case .twoFingerSwipeFromTopEdge: SwipeAnimation(fingerCount: 2, direction: .down, animating: animating)
        case .twoFingerSwipeFromBottomEdge: SwipeAnimation(fingerCount: 2, direction: .up, animating: animating)
        case .threeFingerTapTop, .threeFingerTapBottom: TapAnimation(fingerCount: 3, animating: animating)
        case .scrollUp: SwipeAnimation(fingerCount: 2, direction: .up, animating: animating)
        case .scrollDown: SwipeAnimation(fingerCount: 2, direction: .down, animating: animating)

        // Press-drag
        case .twoFingerPressDragLeft:
            SwipeAnimation(fingerCount: 2, direction: .left, animating: animating)
        case .twoFingerPressDragRight:
            SwipeAnimation(fingerCount: 2, direction: .right, animating: animating)
        }
    }
}

// MARK: - Finger dot

struct FingerDot: View {
    var size: CGFloat = 18
    var opacity: Double = 1.0
    var isClick: Bool = false
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        themeColor.opacity(0.9),
                        themeColor.opacity(0.4)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(themeColor, lineWidth: isClick ? 2 : 0.5)
            )
            .shadow(color: themeColor.opacity(0.5), radius: 4)
            .opacity(opacity)
    }
}

// MARK: - Swipe Animation

struct SwipeAnimation: View {
    let fingerCount: Int
    let direction: SwipeDir
    let animating: Bool
    @Environment(\.themeColor) private var themeColor

    enum SwipeDir { case up, down, left, right }

    var body: some View {
        let spacing: CGFloat = 14
        let totalWidth = CGFloat(fingerCount - 1) * spacing

        ZStack {
            ForEach(0..<fingerCount, id: \.self) { i in
                let baseX = -totalWidth / 2 + CGFloat(i) * spacing
                FingerDot()
                    .offset(
                        x: baseX + (animating ? offsetX : 0),
                        y: animating ? offsetY : 0
                    )
            }

            // Arrow trail
            Image(systemName: arrowName)
                .font(.system(size: 20, weight: .light))
                .foregroundColor(themeColor.opacity(animating ? 0.6 : 0))
                .offset(
                    x: animating ? offsetX * 0.4 : 0,
                    y: animating ? offsetY * 0.4 : 0
                )
        }
        .animation(
            AOMDesign.animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)),
            value: animating
        )
    }

    private var offsetX: CGFloat {
        switch direction {
        case .left: return -30
        case .right: return 30
        default: return 0
        }
    }

    private var offsetY: CGFloat {
        switch direction {
        case .up: return -30
        case .down: return 30
        default: return 0
        }
    }

    private var arrowName: String {
        switch direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}

// MARK: - Tap Animation

struct TapAnimation: View {
    let fingerCount: Int
    let animating: Bool
    var isClick: Bool = false
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        let spacing: CGFloat = 14
        let totalWidth = CGFloat(fingerCount - 1) * spacing

        ZStack {
            // Ripple
            ForEach(0..<fingerCount, id: \.self) { i in
                let x = -totalWidth / 2 + CGFloat(i) * spacing
                Circle()
                    .stroke(themeColor.opacity(animating ? 0 : 0.4), lineWidth: 1.5)
                    .frame(width: animating ? 40 : 18, height: animating ? 40 : 18)
                    .offset(x: x)
            }

            ForEach(0..<fingerCount, id: \.self) { i in
                let x = -totalWidth / 2 + CGFloat(i) * spacing
                FingerDot(opacity: animating ? 1.0 : 0.3, isClick: isClick)
                    .scaleEffect(animating ? 1.0 : 0.6)
                    .offset(x: x)
            }
        }
        .animation(
            AOMDesign.animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)),
            value: animating
        )
    }
}

// MARK: - Double Tap Animation

struct DoubleTapAnimation: View {
    let fingerCount: Int
    let animating: Bool
    @Environment(\.themeColor) private var themeColor
    @State private var phase: Int = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spacing: CGFloat = 14
        let totalWidth = CGFloat(fingerCount - 1) * spacing

        ZStack {
            ForEach(0..<fingerCount, id: \.self) { i in
                let x = -totalWidth / 2 + CGFloat(i) * spacing
                FingerDot(opacity: phase > 0 ? 1.0 : 0.3)
                    .scaleEffect(phase > 0 ? 1.0 : 0.6)
                    .offset(x: x)
            }

            // "x2" badge
            Text("x2")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(themeColor)
                .offset(y: 28)
                .opacity(phase == 2 ? 1 : 0)
        }
        .task(id: "\(animating)-\(scenePhase == .active)-\(reduceMotion)") {
            phase = 0
            guard animating, scenePhase == .active, !reduceMotion else { return }
            do {
                while !Task.isCancelled {
                    for (delay, next) in [(300, 1), (200, 0), (200, 2), (200, 0), (600, 0)] {
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        try Task.checkCancellation()
                        withAnimation(AOMDesign.animation(.easeInOut(duration: 0.15))) { phase = next }
                    }
                }
            } catch { /* View disappeared or preview changed: stop the loop. */ }
        }
    }
}

// MARK: - Pinch Animation

struct PinchAnimation: View {
    var fingerCount: Int = 2
    let pinchIn: Bool
    let animating: Bool

    var body: some View {
        let open: CGFloat = pinchIn ? 30 : 10
        let closed: CGFloat = pinchIn ? 10 : 30
        let radius: CGFloat = animating ? closed : open

        ZStack {
            // Fingers are placed evenly on a circle, so the same animation
            // reads correctly for two through five fingers.
            ForEach(0..<fingerCount, id: \.self) { index in
                let angle = Double(index) / Double(fingerCount) * 2 * .pi - .pi / 2
                FingerDot()
                    .offset(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
            }
        }
        .animation(
            AOMDesign.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)),
            value: animating
        )
    }
}

// MARK: - Rotate Animation

struct RotateAnimation: View {
    var fingerCount: Int = 2
    let clockwise: Bool
    let animating: Bool

    var body: some View {
        ZStack {
            ForEach(0..<fingerCount, id: \.self) { index in
                let angle = Double(index) / Double(fingerCount) * 2 * .pi - .pi / 2
                FingerDot()
                    .offset(x: 18 * CGFloat(cos(angle)), y: 18 * CGFloat(sin(angle)))
            }
        }
        .rotationEffect(.degrees(animating ? (clockwise ? 45 : -45) : 0))
        .animation(
            AOMDesign.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)),
            value: animating
        )
    }
}

// MARK: - TipTap Animation

struct TipTapAnimation: View {
    enum TipTapDir { case left, right, middle }
    let direction: TipTapDir
    let animating: Bool
    @State private var tapping = false

    var body: some View {
        ZStack {
            switch direction {
            case .left:
                // Right finger rests, left taps
                FingerDot(size: 16, opacity: 0.5)
                    .offset(x: 16)
                FingerDot(opacity: tapping ? 1.0 : 0.2)
                    .scaleEffect(tapping ? 1.0 : 0.5)
                    .offset(x: -16, y: tapping ? 0 : -12)
            case .right:
                // Left finger rests, right taps
                FingerDot(size: 16, opacity: 0.5)
                    .offset(x: -16)
                FingerDot(opacity: tapping ? 1.0 : 0.2)
                    .scaleEffect(tapping ? 1.0 : 0.5)
                    .offset(x: 16, y: tapping ? 0 : -12)
            case .middle:
                // Two fingers rest, one taps between
                FingerDot(size: 16, opacity: 0.5)
                    .offset(x: -22)
                FingerDot(size: 16, opacity: 0.5)
                    .offset(x: 22)
                FingerDot(opacity: tapping ? 1.0 : 0.2)
                    .scaleEffect(tapping ? 1.0 : 0.5)
                    .offset(y: tapping ? 0 : -12)
            }
        }
        .onAppear { runTipTap() }
    }

    private func runTipTap() {
        // Reduce Motion: show the finger resting on the pad instead of a loop.
        guard !AOMDesign.reduceMotion else { tapping = true; return }
        withAnimation(AOMDesign.animation(.easeOut(duration: 0.2))) { tapping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(AOMDesign.animation(.easeIn(duration: 0.2))) { tapping = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { runTipTap() }
    }
}

// MARK: - Circle Animation

struct CircleAnimation: View {
    let clockwise: Bool
    let animating: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            CircleAnimationContent(
                clockwise: clockwise,
                date: timeline.date
            )
        }
    }
}

private struct CircleAnimationContent: View {
    let clockwise: Bool
    let date: Date
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 2.0
        let progress = t.truncatingRemainder(dividingBy: period) / period
        let p = CGFloat(progress)
        let radius: CGFloat = 30

        ZStack {
            circlePath(radius: radius)
            circleTrail(p: p, radius: radius)
            directionArrow
            fingerDot(p: p, radius: radius)
        }
    }

    private func circlePath(radius: CGFloat) -> some View {
        Circle()
            .stroke(themeColor.opacity(0.15), lineWidth: 2)
            .frame(width: radius * 2, height: radius * 2)
    }

    private func circleTrail(p: CGFloat, radius: CGFloat) -> some View {
        let trimFrom = max(0, p - 0.25)
        let scaleX: CGFloat = clockwise ? 1 : -1
        return Circle()
            .trim(from: trimFrom, to: p)
            .stroke(
                themeColor.opacity(0.4),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(-90))
            .scaleEffect(x: scaleX, y: 1)
    }

    private var directionArrow: some View {
        let name = clockwise ? "arrow.clockwise" : "arrow.counterclockwise"
        return Image(systemName: name)
            .font(.system(size: 14, weight: .light))
            .foregroundColor(themeColor.opacity(0.3))
    }

    private func fingerDot(p: CGFloat, radius: CGFloat) -> some View {
        let dir: CGFloat = clockwise ? 1 : -1
        let angle = .pi * 2 * p * dir - .pi / 2
        let x = radius * cos(angle)
        let y = radius * sin(angle)
        return FingerDot(size: 16)
            .offset(x: x, y: y)
    }
}

// MARK: - Triangle Draw Animation

struct TriangleDrawAnimation: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            TriangleDrawContent(date: timeline.date)
        }
    }
}

private struct TriangleDrawContent: View {
    let date: Date
    @Environment(\.themeColor) private var themeColor

    // Triangle vertices (centered, fits inside trackpad preview)
    private let vertices: [CGPoint] = [
        CGPoint(x: 0, y: -22),   // top
        CGPoint(x: 25, y: 18),   // bottom-right
        CGPoint(x: -25, y: 18),  // bottom-left
    ]

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 2.5
        let progress = CGFloat(t.truncatingRemainder(dividingBy: period) / period)

        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let pts = vertices.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }

            // Triangle outline (faint)
            var outline = Path()
            outline.move(to: pts[0])
            outline.addLine(to: pts[1])
            outline.addLine(to: pts[2])
            outline.closeSubpath()
            context.stroke(outline, with: .color(themeColor.opacity(0.15)), lineWidth: 2)

            // Animated trail
            let trailLen: CGFloat = 0.2
            let start = max(0, progress - trailLen)
            var trail = Path()
            let steps = 20
            for i in 0...steps {
                let t = start + (progress - start) * CGFloat(i) / CGFloat(steps)
                let pt = pointOnTriangle(min(t, 1.0), center: center)
                if i == 0 { trail.move(to: pt) }
                else { trail.addLine(to: pt) }
            }
            context.stroke(trail, with: .color(themeColor.opacity(0.5)),
                          style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            // Finger dot
            let fp = pointOnTriangle(min(progress, 1.0), center: center)
            let dotRect = CGRect(x: fp.x - 8, y: fp.y - 8, width: 16, height: 16)
            context.fill(Circle().path(in: dotRect), with: .color(themeColor))
            let glowRect = CGRect(x: fp.x - 11, y: fp.y - 11, width: 22, height: 22)
            context.fill(Circle().path(in: glowRect), with: .color(themeColor.opacity(0.3)))
        }
    }

    private func pointOnTriangle(_ t: CGFloat, center: CGPoint) -> CGPoint {
        let segment = t * 3
        let idx = min(Int(segment), 2)
        let frac = segment - CGFloat(idx)
        let a = vertices[idx]
        let b = vertices[(idx + 1) % 3]
        return CGPoint(
            x: center.x + a.x + (b.x - a.x) * frac,
            y: center.y + a.y + (b.y - a.y) * frac
        )
    }
}

// MARK: - Edge Drag Animation

struct EdgeDragAnimation: View {
    enum Edge { case left, right }
    enum Direction { case up, down }
    let edge: Edge
    let direction: Direction
    let animating: Bool
    @Environment(\.themeColor) private var themeColor
    @State private var progress: CGFloat = 0

    var body: some View {
        let edgeX: CGFloat = edge == .left ? -65 : 65
        let startY: CGFloat = direction == .up ? 30 : -30
        let endY: CGFloat = direction == .up ? -30 : 30

        ZStack {
            // Edge zone highlight
            RoundedRectangle(cornerRadius: 4)
                .fill(themeColor.opacity(0.08))
                .frame(width: 24, height: 110)
                .offset(x: edgeX)

            // Arrow indicator
            Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
                .font(.system(size: 12, weight: .light))
                .foregroundColor(themeColor.opacity(0.3))
                .offset(x: edgeX, y: 0)

            // Finger dot
            FingerDot(size: 16)
                .offset(x: edgeX, y: startY + (endY - startY) * progress)
        }
        .onAppear { startLoop() }
    }

    private func startLoop() {
        // Reduce Motion: show the finished stroke instead of looping it.
        progress = AOMDesign.reduceMotion ? 1 : 0
        guard let loop = AOMDesign.animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) else { return }
        withAnimation(loop) {
            progress = 1
        }
    }
}

// MARK: - Position Click Animation

struct PositionClickAnimation: View {
    enum Position {
        case topLeft, topRight, bottomLeft, bottomRight, middleTop, middleBottom
    }
    let position: Position
    let animating: Bool
    @Environment(\.themeColor) private var themeColor
    @State private var pressing = false

    var body: some View {
        ZStack {
            // Zone highlight
            RoundedRectangle(cornerRadius: 4)
                .fill(themeColor.opacity(pressing ? 0.25 : 0.08))
                .frame(width: zoneW, height: zoneH)
                .offset(x: zoneX, y: zoneY)

            // Finger
            FingerDot(opacity: pressing ? 1.0 : 0.4)
                .scaleEffect(pressing ? 1.0 : 0.7)
                .offset(x: dotX, y: dotY)

            // Press ripple
            Circle()
                .stroke(themeColor.opacity(pressing ? 0 : 0.3), lineWidth: 1.5)
                .frame(width: pressing ? 36 : 16, height: pressing ? 36 : 16)
                .offset(x: dotX, y: dotY)
        }
        .onAppear { runPress() }
    }

    private func runPress() {
        // Reduce Motion: a single static press instead of a repeating ripple.
        guard !AOMDesign.reduceMotion else { pressing = true; return }
        withAnimation(AOMDesign.animation(.easeOut(duration: 0.25))) { pressing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(AOMDesign.animation(.easeIn(duration: 0.25))) { pressing = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { runPress() }
    }

    private var dotX: CGFloat {
        switch position {
        case .topLeft, .bottomLeft: return -55
        case .topRight, .bottomRight: return 55
        case .middleTop, .middleBottom: return 0
        }
    }

    private var dotY: CGFloat {
        switch position {
        case .topLeft, .topRight, .middleTop: return -40
        case .bottomLeft, .bottomRight, .middleBottom: return 40
        }
    }

    private var zoneX: CGFloat { dotX }
    private var zoneY: CGFloat { dotY }

    private var zoneW: CGFloat {
        switch position {
        case .middleTop, .middleBottom: return 80
        default: return 40
        }
    }

    private var zoneH: CGFloat { 30 }
}
