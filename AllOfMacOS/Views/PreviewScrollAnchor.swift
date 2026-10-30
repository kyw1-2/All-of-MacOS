import SwiftUI

/// Isolated UI previews (3.3.3 integration): `--aom-preview-scroll-fraction
/// 0.4` opens a long page part-way down, so the sections between its top and
/// `--aom-preview-scroll-bottom` (`AOMPreviewHooks.scrollAnchor`) are
/// reviewed in screenshots too. Nil outside isolated previews, so pages keep
/// their normal scroll position.
enum PreviewScrollAnchor {
    static var current: UnitPoint? {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-scroll-fraction"),
              args.indices.contains(index + 1), let fraction = Double(args[index + 1]),
              (0...1).contains(fraction) else { return AOMPreviewHooks.scrollAnchor }
        return UnitPoint(x: 0, y: fraction)
    }
}
