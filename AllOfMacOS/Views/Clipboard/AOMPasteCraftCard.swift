import AppKit
import SwiftUI

struct AOMPasteCardModel: Identifiable, Equatable {
    enum ContentKind: Equatable {
        case text(body: String, charCount: Int)
        case link(title: String, host: String, urlString: String)
        case image(nsImage: NSImage, width: Int, height: Int, format: String, ocrSnippet: String?)
        case color(hex: String, nsColor: NSColor)
        case code(snippet: String, language: String)
        case files(names: [String], folderPath: String, icon: NSImage?)
    }

    let id: UUID
    let headerTitle: String
    let relativeTime: String
    let sourceColor: Color
    let sourceAppIcon: NSImage?
    let content: ContentKind
    let quickIndex: Int? // 1...9 when ⌘ is held
}

// MARK: - 1. Paste 7 시그니처 하단 셸프 카드 (236×236)

struct AOMPasteCraftCard: View {
    let model: AOMPasteCardModel
    let isSelected: Bool
    let showsQuickBadge: Bool
    @Environment(\.self) private var environment

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let source = model.sourceColor.resolve(in: environment)
        let header = NSColor(srgbRed: CGFloat(source.red), green: CGFloat(source.green),
                             blue: CGFloat(source.blue), alpha: 1)
        let ink: Color = AOMSwatchContrast.prefersBlack(header) ? .black : .white

        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // 상단 54pt 소스 컬러 헤더와 명도 대비에 따른 글자색
                ZStack(alignment: .leading) {
                    Color(nsColor: header)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.headerTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Text(model.relativeTime)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ink)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 62)
                }
                .frame(height: 54)

                // 하단 불투명 콘텐츠 본문 (타입별 전용 렌더러)
                cardBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AOMCraftColor.surface)
            }
            .clipShape(shape)

            // 시그니처: 헤더와 본문 경계선에 반쯤 걸친 40×40 Overlapping App Icon
            if let icon = model.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
                    .padding(.top, 30)
                    .padding(.trailing, 12)
            }

            // ⌘ 키 홀드 시 우상단 ⌘1~⌘9 키캡
            if showsQuickBadge, let idx = model.quickIndex, (1...9).contains(idx) {
                Text("⌘\(idx)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .frame(width: 236, height: 236)
        .overlay(
            shape.strokeBorder(
                isSelected ? Color.accentColor : AOMCraftColor.hairline,
                lineWidth: isSelected ? 3.5 : 0.5
            )
        )
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.10), radius: isSelected ? 10 : 5, y: 3)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var cardBody: some View {
        switch model.content {
        case .text(let text, let count):
            VStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                Text("\(count) characters")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(12)

        case .link(let title, let host, let urlString):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.sourceColor)
                    Text(host)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                Spacer()
                Text(urlString)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)

        case .image(let image, let width, let height, let format, let ocr):
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 236, height: 182)
                    .clipped()

                VStack(alignment: .trailing, spacing: 4) {
                    if let ocr, !ocr.isEmpty {
                        Text(ocr)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text("\(width) × \(height) · \(format)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.62), in: Capsule())
                }
                .padding(8)
            }

        case .color(let hex, let nsColor):
            let rgb = nsColor.usingColorSpace(.sRGB) ?? .black
            let fg: Color = AOMSwatchContrast.prefersBlack(rgb) ? .black : .white
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: nsColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hex.uppercased())
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(fg)
                    Text("RGB \(Int(rgb.redComponent * 255)), \(Int(rgb.greenComponent * 255)), \(Int(rgb.blueComponent * 255))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(fg)
                }
                .padding(12)
                .background(Color(nsColor: rgb.withAlphaComponent(1)))
            }

        case .code(let snippet, let language):
            VStack(alignment: .leading, spacing: 6) {
                Text(ClipboardCodeHighlighter.attributed(snippet))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                Text(language)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .padding(12)

        case .files(let names, let folderPath, let icon):
            VStack(spacing: 8) {
                Spacer()
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 52, height: 52)
                }
                Text(names.count == 1 ? names[0] : "\(names.count) files")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folderPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(12)
        }
    }
}

// MARK: - 2. matchedGeometryEffect 슬라이딩 핀보드 탭 바

enum AOMSwatchContrast {
    /// Compares WCAG contrast ratios on the opaque sRGB preview.
    static func prefersBlack(_ rgb: NSColor) -> Bool {
        func linear(_ channel: CGFloat) -> CGFloat {
            let c = min(1, max(0, channel))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }
}
