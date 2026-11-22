import AppKit
import SwiftUI

// 7.8: the launcher's Theme screen (Raycast's theme picker). ↑↓ tries each
// theme on the panel itself; ↩ keeps it; esc goes back to the one you had.
// Opacity and Material sit under the themes, so the whole look is set
// without leaving the launcher.

extension QuickCommandPalette {
    static let themeRowPrefix = "launcher.theme."

    /// The theme a row stands for (nil: not a theme row).
    static func theme(forRow id: String?) -> AOMLauncherTheme? {
        guard let id, id.hasPrefix(themeRowPrefix) else { return nil }
        let themeID = String(id.dropFirst(themeRowPrefix.count))
        return AOMLauncherTheme.all.first { $0.id == themeID }
    }

    func themeItems() -> [PaletteItem] {
        let look = AOMLauncherAppearance.shared
        var items: [PaletteItem] = []
        for theme in AOMLauncherTheme.all {
            let current = theme == look.theme
            var row = screenRow(Self.themeRowPrefix + theme.id, theme.name,
                                theme.schemeLabel,
                                icon: "paintpalette", group: "Themes",
                                primary: PaletteAction(title: current ? "Current Theme" : "Use Theme", symbol: "checkmark", effect: .stay) {
                                    look.setTheme(theme)
                                    screens.show("Launcher theme: \(theme.name)")
                                    sourcesChanged()
                                },
                                accessory: current ? "Current" : nil,
                                image: AOMLauncherThemeSwatch.image(theme))
            row.aliases = [theme.name.lowercased(), "theme", "테마"]
            items.append(row)
        }
        let levels: [(Double, String)] = [(0.45, "Clear"), (0.58, "Light"), (AOMLauncherAppearance.defaultOpacity, "Balanced"),
                                          (0.82, "Dense"), (0.92, "Nearly solid"), (1, "Solid")]
        let nearest = levels.min { abs($0.0 - look.opacity) < abs($1.0 - look.opacity) }?.0
        for (value, name) in levels {
            let current = nearest == value
            items.append(screenRow("launcher.opacity.\(Int(value * 100))", "\(name) · \(Int((value * 100).rounded())) %",
                                   value >= 1 ? "No desktop behind the launcher" : "How much of the theme colour lies over the blurred desktop",
                                   icon: value >= 1 ? "square.fill" : value < 0.6 ? "square.dashed" : "square.lefthalf.filled",
                                   group: "Opacity",
                                   primary: PaletteAction(title: "Use Opacity", symbol: "checkmark", effect: .stay) {
                                       look.setOpacity(value)
                                       screens.show("Launcher opacity \(Int((value * 100).rounded())) %")
                                       sourcesChanged()
                                   },
                                   accessory: current ? "Current" : nil))
        }
        for material in AOMLauncherMaterial.allCases {
            let current = material == look.material
            let subtitle: String
            if material == .frosted {
                subtitle = "A strong blur: the wallpaper's colour shows, its detail doesn't"
            } else if #available(macOS 26, *) {
                subtitle = "Apple's Liquid Glass: clearer, with a lens at the edges"
            } else {
                subtitle = "Liquid Glass needs macOS 26; the frosted blur is used"
            }
            items.append(screenRow("launcher.material.\(material.rawValue)", material == .frosted ? "Frosted Blur" : "Liquid Glass", subtitle,
                                   icon: material == .frosted ? "drop.halffull" : "drop", group: "Material",
                                   primary: PaletteAction(title: "Use Material", symbol: "checkmark", effect: .stay) {
                                       look.setMaterial(material)
                                       sourcesChanged()
                                   },
                                   accessory: current ? "Current" : nil))
        }
        items.append(screenRow("launcher.theme.settings", "Appearance Settings…", "Theme, opacity and material in Settings › General",
                               icon: "gearshape", group: "More",
                               primary: PaletteAction(title: "Open Settings") { openAOMSettings() }))
        return items
    }

    /// Arrowing onto a theme row shows that theme; leaving the screen goes
    /// back to the saved one.
    func previewTheme(forSelection id: String?) {
        guard navigation.current == .themes else { return }
        AOMLauncherAppearance.shared.preview(Self.theme(forRow: id))
    }
}

/// A theme's swatch for its row: the base colour with the accent inside.
enum AOMLauncherThemeSwatch {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ theme: AOMLauncherTheme) -> NSImage {
        if let cached = cache[theme.id] { return cached }
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            if theme.scheme == .system {
                // Half light, half dark.
                NSGraphicsContext.saveGraphicsState()
                outer.addClip()
                theme.lightBase.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height)).fill()
                theme.darkBase.setFill()
                NSBezierPath(rect: NSRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                (theme.scheme == .light ? theme.lightBase : theme.darkBase).setFill()
                outer.fill()
            }
            NSColor.black.withAlphaComponent(0.18).setStroke()
            outer.lineWidth = 1
            outer.stroke()
            (theme.accent ?? NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 5, y: rect.midY - 5, width: 10, height: 10)).fill()
            return true
        }
        cache[theme.id] = image
        return image
    }
}
