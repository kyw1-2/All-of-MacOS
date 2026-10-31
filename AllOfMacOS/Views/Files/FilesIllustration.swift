import SwiftUI

/// A drawing of an Open dialog with the Files panel beside it. The page shows
/// this instead of driving a real app's dialog to demonstrate the helper.
struct FilesDialogIllustration: View {
    var active: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x2) {
            dialog
            panel
        }
        .padding(AOMSpace.x4)
        .frame(maxWidth: .infinity)
        .frame(height: 196)
        .background(AOMColor.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration: a panel beside an Open dialog lists Finder windows, favorites and recent folders. Clicking one opens it in the dialog.")
    }

    private var line: Color { contrast == .increased ? AOMColor.strongLine : AOMColor.hairline }

    private var dialog: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x1) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(AOMColor.track).frame(width: 7, height: 7) }
                Spacer()
                Capsule().fill(AOMColor.track).frame(width: 90, height: 12)
                Spacer()
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 24)
            AOMDivider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: AOMSpace.x1 + 2) {
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: AOMSpace.x1) {
                            Image(systemName: "folder.fill").imageScale(.small).foregroundStyle(AOMColor.accent.opacity(0.55))
                            Capsule().fill(AOMColor.track).frame(width: CGFloat([46, 38, 52, 30, 42][index]), height: 6)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(AOMSpace.x2)
                .frame(width: 92, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(AOMColor.sunken.opacity(0.6))
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: AOMSpace.x2) {
                            Image(systemName: index == 1 ? "doc.richtext" : "doc")
                                .imageScale(.small)
                                .foregroundStyle(AOMColor.textTertiary)
                            Capsule().fill(AOMColor.track).frame(width: CGFloat([110, 86, 128, 72][index]), height: 6)
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: AOMSpace.x2) {
                        Spacer()
                        Capsule().fill(AOMColor.track).frame(width: 46, height: 16)
                        Capsule().fill(AOMColor.accent.opacity(0.7)).frame(width: 46, height: 16)
                    }
                }
                .padding(AOMSpace.x3)
            }
        }
        .frame(maxWidth: 360)
        .background(AOMColor.raised, in: shape)
        .overlay { shape.strokeBorder(line, lineWidth: contrast == .increased ? 1 : 0.5) }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
        let rows: [(String, String, Bool)] = [("macwindow", "Project", false), ("star.fill", "Downloads", true),
                                             ("star.fill", "Documents", false), ("clock", "Lecture Notes", false),
                                             ("doc.on.clipboard", "Clipboard path", false)]
        return VStack(alignment: .leading, spacing: AOMSpace.x1) {
            HStack(spacing: AOMSpace.x1) {
                AOMModuleBadge(.files, size: 16, active: active)
                Capsule().fill(AOMColor.track).frame(width: 54, height: 7)
            }
            .padding(.bottom, AOMSpace.x1)
            ForEach(rows, id: \.1) { symbol, title, highlighted in
                HStack(spacing: AOMSpace.x1 + 2) {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(highlighted ? Color.white : AOMColor.accent)
                        .frame(width: 14)
                    Text(title)
                        .font(AOMFont.caption)
                        .foregroundStyle(highlighted ? Color.white : AOMColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AOMSpace.x1 + 2)
                .frame(height: 22)
                .background(highlighted ? AOMColor.accent : .clear,
                            in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            }
            Spacer(minLength: 0)
        }
        .padding(AOMSpace.x2)
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(AOMColor.raised, in: shape)
        .overlay { shape.strokeBorder(active ? AOMColor.accent.opacity(0.6) : line, lineWidth: 1) }
        .opacity(active ? 1 : 0.6)
    }
}
