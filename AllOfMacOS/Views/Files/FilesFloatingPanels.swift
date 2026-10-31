import AppKit
import SwiftUI

/// A borderless, non-activating panel for Files' floating chrome (the panel
/// beside a dialog, the Drop Shelf). It never activates AOM; it becomes key
/// only when `allowsKey` is set and someone works in it.
class FilesFloatingPanel: NSPanel {
    var allowsKey = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(size: CGSize, label: String) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        setAccessibilityLabel(label)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// A hosting view that takes the first click, so a row in a panel that isn't
/// key acts on one click.
final class FilesHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Screen geometry for panels placed next to other apps' windows.
enum FilesScreenGeometry {
    /// Accessibility rectangles are global with a top-left origin; AppKit's
    /// have a bottom-left origin on the primary display.
    static func cocoaRect(fromAX rect: CGRect, primaryHeight: CGFloat? = nil) -> CGRect {
        let height = primaryHeight ?? (NSScreen.screens.first?.frame.maxY ?? 0)
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The panel's frame beside `dialog`: to its right, else to its left,
    /// else just inside its right edge; top-aligned and kept on the screen
    /// that holds most of the dialog.
    static func frame(beside dialog: CGRect, size: CGSize, visibleFrames: [CGRect], gap: CGFloat = 8) -> CGRect {
        let screen = visibleFrames.max { overlap($0, dialog) < overlap($1, dialog) } ?? dialog.insetBy(dx: -size.width * 2, dy: -size.height)
        let height = min(size.height, screen.height - gap * 2)
        var x = dialog.maxX + gap
        if x + size.width > screen.maxX {
            let left = dialog.minX - gap - size.width
            x = left >= screen.minX ? left : max(screen.minX, min(dialog.maxX - size.width - gap, screen.maxX - size.width))
        }
        var y = dialog.maxY - height
        y = min(max(y, screen.minY + gap), screen.maxY - height - gap)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: height.rounded())
    }

    /// A panel at the pointer, `offset` to the lower right, kept on screen.
    static func frame(at point: CGPoint, size: CGSize, visibleFrames: [CGRect], offset: CGFloat = 12) -> CGRect {
        let screen = visibleFrames.first { $0.insetBy(dx: -1, dy: -1).contains(point) } ?? visibleFrames.first
            ?? CGRect(x: point.x - size.width, y: point.y - size.height, width: size.width * 2, height: size.height * 2)
        var x = point.x + offset
        var y = point.y - offset - size.height
        if x + size.width > screen.maxX { x = point.x - offset - size.width }
        if y < screen.minY { y = point.y + offset }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

/// A row button for floating lists: the hover fill and the pressed fill of
/// the 3.4 interaction layer, nothing that moves.
struct FilesRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FilesRowButtonBody(configuration: configuration)
    }
}

private struct FilesRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? AOMColor.rowPressed : (hovering && isEnabled ? AOMColor.rowHover : .clear))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
    }
}

/// Two or more sections side by side when each gets at least
/// `minimumColumnWidth`, stacked otherwise (design-3.4.0 b.2: related sections
/// side by side on wide windows). Unlike ViewThatFits it decides by the width
/// it is offered, so long paths in rows never force the stacked layout.
struct FilesAdaptiveColumns: Layout {
    var minimumColumnWidth: CGFloat = 420
    var spacing: CGFloat = AOMSpace.sectionGap

    private func sideBySide(_ width: CGFloat, count: Int) -> Bool {
        count > 1 && width >= minimumColumnWidth * CGFloat(count) + spacing * CGFloat(count - 1)
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth * 2 + spacing
        guard !subviews.isEmpty else { return CGSize(width: width, height: 0) }
        if sideBySide(width, count: subviews.count) {
            let column = columnWidth(width, count: subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if sideBySide(bounds.width, count: subviews.count) {
            let column = columnWidth(bounds.width, count: subviews.count)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + spacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: column, height: nil))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}

/// A file or folder icon from the Finder, cached by path.
@MainActor
enum FilesIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = image
        return image
    }
}
