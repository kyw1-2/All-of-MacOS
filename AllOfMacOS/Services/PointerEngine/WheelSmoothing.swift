import Foundation

/// A bounded 120 ms ease-out that preserves the total wheel displacement.
struct WheelSmoothing {
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    private var lastTime = 0.0
    private var endTime = 0.0

    mutating func add(x: Double, y: Double, at time: Double) {
        if x * remainingX < 0 { remainingX = 0 }
        if y * remainingY < 0 { remainingY = 0 }
        remainingX = min(1200, max(-1200, remainingX + x))
        remainingY = min(1200, max(-1200, remainingY + y))
        lastTime = time
        endTime = time + 0.12
    }

    var active: Bool { remainingX != 0 || remainingY != 0 }

    mutating func step(at time: Double) -> (x: Double, y: Double) {
        guard active else { return (0, 0) }
        let elapsed = max(0, time - lastTime)
        let left = max(0, endTime - lastTime)
        let fraction = left <= elapsed ? 1 : 1 - pow(1 - elapsed / left, 3)
        let result = (x: remainingX * fraction, y: remainingY * fraction)
        remainingX -= result.x
        remainingY -= result.y
        lastTime = time
        return result
    }
}
