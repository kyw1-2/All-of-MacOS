import AppKit
import SwiftUI

// AOM 6.0 buttons. The 5.x pages used the system's bordered push button
// everywhere: a white bezel with a drop shadow, which reads as a dialog from
// an older macOS next to flat cards. 6.0 draws two buttons of its own, the
// way Linear, Raycast and Things do:
//
// - `AOMSoftButtonStyle` — the default for every page button: a quiet fill
//   one step above the surface, no outline, no shadow; it deepens under the
//   pointer and when pressed.
// - `AOMPrimaryButtonStyle` — a page's one main action: the accent fill
//   with white text.
//
// Both read the control size (mini … large), keep the system focus ring for
// keyboard users, dim when disabled and draw a destructive role in red.
// Increase Contrast adds a solid edge.

enum AOMButtonMetrics {
    static func height(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 18
        case .small: return 22
        case .large: return 32
        case .extraLarge: return 38
        default: return 26
        }
    }

    static func font(_ size: ControlSize) -> Font {
        switch size {
        case .mini: return .caption.weight(.medium)
        case .small: return .callout.weight(.medium)
        case .large, .extraLarge: return .body.weight(.semibold)
        default: return .body.weight(.medium)
        }
    }

    static func horizontalPadding(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 6
        case .small: return 8
        case .large, .extraLarge: return 14
        default: return 11
        }
    }

    static func radius(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 4
        case .small: return 6
        case .large, .extraLarge: return 9
        default: return 7
        }
    }
}

/// The default page button.
struct AOMSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMButtonBody(configuration: configuration, prominent: false)
    }
}

/// A page's one main action.
struct AOMPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMButtonBody(configuration: configuration, prominent: true)
    }
}

private struct AOMButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var destructive: Bool { configuration.role == .destructive }

    private var fill: Color {
        if prominent {
            let base = destructive ? AOMColor.danger : AOMColor.accent
            return configuration.isPressed ? base.opacity(0.8) : (hovering ? base.opacity(0.92) : base)
        }
        let dark = scheme == .dark
        let rest = dark ? 0.10 : 0.055
        let hover = dark ? 0.15 : 0.085
        let press = dark ? 0.20 : 0.12
        return Color.primary.opacity(configuration.isPressed ? press : (hovering ? hover : rest))
    }

    private var foreground: Color {
        if prominent { return .white }
        return destructive ? AOMColor.dangerText : AOMColor.text
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMButtonMetrics.radius(controlSize), style: .continuous)
        configuration.label
            .font(AOMButtonMetrics.font(controlSize))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, AOMButtonMetrics.horizontalPadding(controlSize))
            .frame(minHeight: AOMButtonMetrics.height(controlSize))
            .background(fill, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(prominent ? Color.clear : AOMColor.strongLine, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { inside in if isEnabled { hovering = inside } else { hovering = false } }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    /// The page default: buttons without a style of their own become soft.
    func aomButtonDefaults() -> some View { buttonStyle(AOMSoftButtonStyle()) }
}
