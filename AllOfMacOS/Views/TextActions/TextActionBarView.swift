import AppKit
import SwiftUI

/// The bar: a capsule of actions over the selection, like the iOS edit menu.
/// It takes no keyboard focus; every control is a click target with a
/// tooltip and a VoiceOver label. `inWindow` draws it inside AOM's own window
/// (the page's live preview), where the material samples the window.
struct TextActionBarView: View {
    @ObservedObject var model: TextActionBarModel
    var inWindow = false

    var body: some View {
        HStack(spacing: 0) {
            if let confirmation = model.confirmation {
                Label(confirmation, systemImage: "checkmark")
                    .font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .padding(.horizontal, AOMSpace.x3)
                    .frame(height: TextActionBarMetrics.height)
                    .accessibilityLabel(confirmation)
            } else if let submenu = model.submenu, case .menu(let variants) = submenu.kind {
                chevron("chevron.left", label: "Back to all actions") { model.closeSubmenu() }
                ForEach(variants) { variant in
                    TextActionBarSeparator()
                    TextActionBarButton(title: variant.title, symbol: nil, showsTitle: true, help: variant.help,
                                        accessibilityLabel: variant.help) { alternate in
                        model.perform(submenu, variant, alternate)
                    }
                }
            } else {
                if model.hasPreviousPage {
                    chevron("chevron.left", label: "Previous actions") { model.previousPage() }
                    TextActionBarSeparator()
                }
                ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { TextActionBarSeparator() }
                    itemView(item)
                }
                if model.hasNextPage {
                    TextActionBarSeparator()
                    chevron("chevron.right", label: "More actions") { model.nextPage() }
                }
            }
        }
        .padding(.horizontal, AOMSpace.x1)
        .frame(height: TextActionBarMetrics.height)
        .fixedSize()
        .aomFloatingSurface(.bar, radius: TextActionBarMetrics.height / 2, inWindow: inWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text Actions")
    }

    @ViewBuilder
    private func itemView(_ item: TextActionBarItem) -> some View {
        switch item.kind {
        case .chip:
            Text(item.title)
                .font(AOMFont.callout)
                .monospacedDigit()
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, TextActionBarMetrics.itemPadding)
                .frame(height: TextActionBarMetrics.height)
                .help(item.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityLabel)
        case .result:
            TextActionBarButton(title: item.title, symbol: nil, showsTitle: true, help: item.help,
                                accessibilityLabel: item.accessibilityLabel, monospaced: true) { alternate in
                model.perform(item, nil, alternate)
            }
        case .menu:
            TextActionBarButton(title: item.title, symbol: item.symbol, showsTitle: model.showsNames, help: item.help,
                                accessibilityLabel: item.accessibilityLabel) { _ in
                model.open(item)
            }
        case .transform(let variant):
            TextActionBarButton(title: item.title, symbol: item.symbol, showsTitle: model.showsNames, help: item.help,
                                accessibilityLabel: item.accessibilityLabel) { alternate in
                model.perform(item, variant, alternate)
            }
        case .action:
            TextActionBarButton(title: item.title, symbol: item.symbol, showsTitle: model.showsNames, help: item.help,
                                accessibilityLabel: item.accessibilityLabel) { alternate in
                model.perform(item, nil, alternate)
            }
        }
    }

    private func chevron(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        TextActionBarButton(title: label, symbol: symbol, showsTitle: false, help: label, accessibilityLabel: label,
                            width: TextActionBarMetrics.chevronWidth) { _ in action() }
    }
}

/// A hairline between items, as in the iOS edit menu.
struct TextActionBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(AOMColor.hairline)
            .frame(width: 1, height: TextActionBarMetrics.height * 0.5)
            .accessibilityHidden(true)
    }
}

/// One clickable item. The action receives whether ⌥ was held.
struct TextActionBarButton: View {
    let title: String
    let symbol: String?
    let showsTitle: Bool
    let help: String
    let accessibilityLabel: String
    var monospaced = false
    var width: CGFloat?
    let action: (Bool) -> Void

    init(title: String, symbol: String?, showsTitle: Bool, help: String, accessibilityLabel: String,
         monospaced: Bool = false, width: CGFloat? = nil, action: @escaping (Bool) -> Void) {
        self.title = title
        self.symbol = symbol
        self.showsTitle = showsTitle
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.monospaced = monospaced
        self.width = width
        self.action = action
    }

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: AOMSpace.x1) {
                if let symbol {
                    Image(systemName: symbol)
                        .imageScale(.medium)
                        .frame(minWidth: AOMIcon.row)
                }
                if showsTitle || symbol == nil {
                    Text(title)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(monospaced ? AOMFont.callout.weight(.medium).monospacedDigit() : AOMFont.callout)
            .padding(.horizontal, symbol != nil && !showsTitle ? AOMSpace.x0_5 : TextActionBarMetrics.itemPadding)
            .frame(minWidth: width ?? (symbol != nil && !showsTitle ? TextActionBarMetrics.iconButton : nil))
            .frame(height: TextActionBarMetrics.height - AOMSpace.x1)
            .contentShape(Rectangle())
        }
        .buttonStyle(TextActionBarButtonStyle())
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Plain items with a soft fill under the pointer and when pressed.
struct TextActionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextActionBarButtonBody(configuration: configuration)
    }
}

private struct TextActionBarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .foregroundStyle(AOMColor.text)
            .background {
                RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? AOMColor.track : (hovering ? AOMColor.sunken : Color.clear))
            }
            .overlay {
                if hovering && contrast == .increased {
                    RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                        .strokeBorder(AOMColor.strongLine, lineWidth: 1)
                }
            }
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
    }
}
