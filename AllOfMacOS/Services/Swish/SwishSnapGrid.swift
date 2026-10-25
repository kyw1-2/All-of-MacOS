import Foundation
import CoreGraphics

/// Pure mathematical grid engine replicating Swish 1.13.2 snapping geometry.
/// All output rectangles are in Accessibility (AX) coordinate space:
/// - Origin is top-left of the display
/// - Positive X moves rightward
/// - Positive Y moves downward
enum SwishSnapGrid {
    
    enum Direction: Equatable {
        case left, right, top, bottom
    }
    
    enum Corner: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    enum ColumnThird: Equatable {
        case left, center, right, leftTwoThirds, rightTwoThirds
    }

    // MARK: - Standard Halves

    static func half(in visible: CGRect, direction: Direction) -> CGRect {
        switch direction {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .right:
            return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .top:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height / 2)
        case .bottom:
            return CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: visible.height / 2)
        }
    }

    // MARK: - Quarters (4 Corners)

    static func quarter(in visible: CGRect, corner: Corner) -> CGRect {
        let w = visible.width / 2
        let h = visible.height / 2
        switch corner {
        case .topLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: h)
        case .topRight:
            return CGRect(x: visible.midX, y: visible.minY, width: w, height: h)
        case .bottomLeft:
            return CGRect(x: visible.minX, y: visible.midY, width: w, height: h)
        case .bottomRight:
            return CGRect(x: visible.midX, y: visible.midY, width: w, height: h)
        }
    }

    // MARK: - Thirds & Two-Thirds (Horizontal Columns)

    static func third(in visible: CGRect, column: ColumnThird) -> CGRect {
        let oneThird = visible.width / 3
        let twoThirds = oneThird * 2
        switch column {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: oneThird, height: visible.height)
        case .center:
            return CGRect(x: visible.minX + oneThird, y: visible.minY, width: oneThird, height: visible.height)
        case .right:
            return CGRect(x: visible.minX + twoThirds, y: visible.minY, width: oneThird, height: visible.height)
        case .leftTwoThirds:
            return CGRect(x: visible.minX, y: visible.minY, width: twoThirds, height: visible.height)
        case .rightTwoThirds:
            return CGRect(x: visible.minX + oneThird, y: visible.minY, width: twoThirds, height: visible.height)
        }
    }

    // MARK: - Sixths (2 rows x 3 columns)

    static func sixth(in visible: CGRect, col: Int, row: Int) -> CGRect {
        let c = max(0, min(2, col))
        let r = max(0, min(1, row))
        let w = visible.width / 3
        let h = visible.height / 2
        return CGRect(x: visible.minX + CGFloat(c) * w, y: visible.minY + CGFloat(r) * h, width: w, height: h)
    }

    // MARK: - Ninths (3 rows x 3 columns)

    static func ninth(in visible: CGRect, col: Int, row: Int) -> CGRect {
        let c = max(0, min(2, col))
        let r = max(0, min(2, row))
        let w = visible.width / 3
        let h = visible.height / 3
        return CGRect(x: visible.minX + CGFloat(c) * w, y: visible.minY + CGFloat(r) * h, width: w, height: h)
    }

    // MARK: - Almost Max & Center

    static func almostMax(in visible: CGRect, inset: CGFloat = 32.0) -> CGRect {
        visible.insetBy(dx: inset, dy: inset)
    }

    static func center(in visible: CGRect, targetSize: CGSize) -> CGRect {
        let w = min(visible.width, max(120, targetSize.width))
        let h = min(visible.height, max(80, targetSize.height))
        let x = visible.midX - (w / 2)
        let y = visible.midY - (h / 2)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Dynamic Cursor-to-Snap Target Resolver (Swish Grammar)

    /// Given the cursor position in AX space, resolves the appropriate Swish snap target frame.
    /// - Parameters:
    ///   - cursor: Cursor point in AX space (origin top-left)
    ///   - screen: The screen's total frame and menu/dock-adjusted visible frame (both AX space)
    ///   - edgeBand: Margin in points to trigger an edge snap (Swish default: 24–32pt)
    ///   - useThirdsModifier: True if option/modifier is pressed to trigger 1/3 splits instead of halves
    static func resolveTarget(
        cursor: CGPoint,
        screen: (frame: CGRect, visible: CGRect),
        edgeBand: CGFloat = 28.0,
        useThirdsModifier: Bool = false
    ) -> CGRect? {
        let frame = screen.frame
        let visible = screen.visible

        let nearLeft = cursor.x <= frame.minX + edgeBand
        let nearRight = cursor.x >= frame.maxX - edgeBand
        let nearTop = cursor.y <= frame.minY + edgeBand
        let nearBottom = cursor.y >= frame.maxY - edgeBand

        // 1. Corners -> Quarters
        if nearTop && nearLeft { return quarter(in: visible, corner: .topLeft) }
        if nearTop && nearRight { return quarter(in: visible, corner: .topRight) }
        if nearBottom && nearLeft { return quarter(in: visible, corner: .bottomLeft) }
        if nearBottom && nearRight { return quarter(in: visible, corner: .bottomRight) }

        // 2. Edges -> Halves or Thirds
        if nearLeft {
            return useThirdsModifier ? third(in: visible, column: .left) : half(in: visible, direction: .left)
        }
        if nearRight {
            return useThirdsModifier ? third(in: visible, column: .right) : half(in: visible, direction: .right)
        }
        if nearTop {
            // Top center maximizes in Swish
            return visible
        }
        if nearBottom {
            return half(in: visible, direction: .bottom)
        }

        return nil
    }

    // MARK: - Trackpad Gesture Vector Resolver (Swish Directional Engine)

    enum Action: Equatable {
        case snapLeftHalf
        case snapRightHalf
        case snapTopHalf
        case snapBottomHalf
        case snapLeftThird
        case snapRightThird
        case snapTopLeftQuarter
        case snapTopRightQuarter
        case snapBottomLeftQuarter
        case snapBottomRightQuarter
        case maximize
        case minimize
        case close
        case fullscreen
    }

    struct GestureResult: Equatable {
        let action: Action
        let frame: CGRect
        let title: String
        let symbol: String
    }

    /// Resolves snap target frame and action from gesture vector and modifier state.
    static func resolveGesture(
        deltaX: CGFloat,
        deltaY: CGFloat,
        spreadRatio: CGFloat,
        targetFrame: CGRect,
        screenVisible: CGRect,
        useThirds: Bool = false
    ) -> GestureResult? {
        // 1. Pinch In -> Close Window
        if spreadRatio < 0.78 {
            let insetFrame = targetFrame.insetBy(dx: targetFrame.width * 0.12, dy: targetFrame.height * 0.12)
            return GestureResult(action: .close, frame: insetFrame, title: "Close Window", symbol: "xmark.circle.fill")
        }

        // 2. Pinch Out -> Fullscreen
        if spreadRatio > 1.25 {
            return GestureResult(action: .fullscreen, frame: screenVisible, title: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right")
        }

        // 3. Directional Swipes on Trackpad
        let dist = hypot(deltaX, deltaY)
        guard dist >= 0.08 else { return nil }

        // Primary axes vs Diagonal
        if abs(deltaX) > abs(deltaY) * 1.3 {
            // Horizontal swipe
            if deltaX < 0 {
                let f = useThirds ? third(in: screenVisible, column: .left) : half(in: screenVisible, direction: .left)
                return GestureResult(action: useThirds ? .snapLeftThird : .snapLeftHalf, frame: f,
                                     title: useThirds ? "Left 1/3" : "Left Half",
                                     symbol: useThirds ? "rectangle.split.3x1" : "rectangle.lefthalf.filled")
            } else {
                let f = useThirds ? third(in: screenVisible, column: .right) : half(in: screenVisible, direction: .right)
                return GestureResult(action: useThirds ? .snapRightThird : .snapRightHalf, frame: f,
                                     title: useThirds ? "Right 1/3" : "Right Half",
                                     symbol: useThirds ? "rectangle.split.3x1" : "rectangle.righthalf.filled")
            }
        } else if abs(deltaY) > abs(deltaX) * 1.3 {
            // Vertical swipe (deltaY > 0 is up towards display, deltaY < 0 is down towards user)
            if deltaY > 0 {
                if useThirds {
                    let f = half(in: screenVisible, direction: .top)
                    return GestureResult(action: .snapTopHalf, frame: f, title: "Top Half", symbol: "rectangle.tophalf.filled")
                } else {
                    return GestureResult(action: .maximize, frame: screenVisible, title: "Maximize", symbol: "arrow.up.left.and.arrow.down.right")
                }
            } else {
                let minFrame = CGRect(x: targetFrame.midX - 120, y: screenVisible.maxY - 50, width: 240, height: 44)
                return GestureResult(action: .minimize, frame: minFrame, title: "Minimize", symbol: "arrow.down.to.line")
            }
        } else {
            // Diagonal swipe: 4 quarters
            if deltaX < 0 && deltaY > 0 {
                let f = quarter(in: screenVisible, corner: .topLeft)
                return GestureResult(action: .snapTopLeftQuarter, frame: f, title: "Top-Left", symbol: "square.grid.2x2")
            } else if deltaX > 0 && deltaY > 0 {
                let f = quarter(in: screenVisible, corner: .topRight)
                return GestureResult(action: .snapTopRightQuarter, frame: f, title: "Top-Right", symbol: "square.grid.2x2")
            } else if deltaX < 0 && deltaY < 0 {
                let f = quarter(in: screenVisible, corner: .bottomLeft)
                return GestureResult(action: .snapBottomLeftQuarter, frame: f, title: "Bottom-Left", symbol: "square.grid.2x2")
            } else if deltaX > 0 && deltaY < 0 {
                let f = quarter(in: screenVisible, corner: .bottomRight)
                return GestureResult(action: .snapBottomRightQuarter, frame: f, title: "Bottom-Right", symbol: "square.grid.2x2")
            }
        }

        return nil
    }
}
