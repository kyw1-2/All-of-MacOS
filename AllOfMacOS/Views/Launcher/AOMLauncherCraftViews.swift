import SwiftUI

// MARK: - 1. 검색창 + 뒤로가기 토큰 + 인라인 스코프 드롭다운 (Raycast Accessory)

// MARK: - 2. 계산기 & 단위 변환 카드

struct AOMCalculatorSplitCard: View {
    let expression: String
    let expressionLabel: String
    let answer: String
    let answerLabel: String

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(expression)
                    .font(.system(size: 20, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(expressionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            VStack(spacing: 4) {
                Text(answer)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(answerLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: AOMCraftRadius.card, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AOMCraftRadius.card, style: .continuous)
                .strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 3. 42:58 우측 Split Detail Preview 레이아웃

struct AOMLauncherSplitView<ListPane: View, DetailPane: View>: View {
    let list: () -> ListPane
    let detail: () -> DetailPane

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 520 {
                VStack(spacing: 0) {
                    list().frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    list()
                        .frame(width: max(250, proxy.size.width * 0.42))
                    Rectangle()
                        .fill(AOMCraftColor.hairline)
                        .frame(width: 1)
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Window Management 하위 화면용 실시간 16:10 미니 모니터 프리뷰
struct AOMWindowLayoutMiniPreview: View {
    let normalizedTarget: CGRect
    let title: String
    let shortcut: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AOMCraftColor.hairline, lineWidth: 1)
                        )
                    // 미니 메뉴바
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 10)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))

                    // 창 스냅 영역 애니메이션
                    let inset: CGFloat = 5
                    let usableW = w - inset * 2
                    let usableH = h - 10 - inset * 2
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        )
                        .frame(
                            width: max(12, usableW * normalizedTarget.width),
                            height: max(12, usableH * normalizedTarget.height)
                        )
                        .offset(
                            x: inset + usableW * normalizedTarget.minX,
                            y: 10 + inset + usableH * normalizedTarget.minY
                        )
                        .animation(AOMCraftMotion.resolve(AOMCraftMotion.stackPush, reduceMotion: reduceMotion), value: normalizedTarget)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxWidth: 260)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let shortcut {
                    AOMCraftKeycap(text: shortcut)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - 4. 3구역 푸터 액션 바 (38pt)

/// 7.0: the launcher's footer — where you are on the left, the primary
/// action with its key and Actions ⌘K on the right. `bindsKeys` registers
/// ↩ and ⌘K; the launcher handles those keys itself and passes false.
struct AOMLauncherFooterBar: View {
    let breadcrumbSymbol: String
    let breadcrumbPath: String
    let primaryTitle: String?
    var primaryDestructive = false
    var primaryKeys = "↩"
    /// Said instead of the primary action (a protected row, a pending answer).
    var status: String? = nil
    var showsActions = true
    var bindsKeys = true
    let onPrimary: () -> Void
    let onActionsPanel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: breadcrumbSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .accessibilityHidden(true)
                Text(breadcrumbPath)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if let status {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .lineLimit(1)
            } else if let primaryTitle {
                Button(role: primaryDestructive ? .destructive : nil, action: onPrimary) {
                    HStack(spacing: 6) {
                        Text(primaryTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(primaryDestructive ? Color(nsColor: .systemRed) : AOMCraftColor.ink)
                            .lineLimit(1)
                        if !primaryDestructive || !bindsKeys { AOMCraftKeycap(text: primaryKeys) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(LauncherDefaultAction(enabled: bindsKeys && !primaryDestructive))
                .aomCalmHover(radius: 6)
                .accessibilityLabel("\(primaryTitle), \(primaryKeys)")
            }

            if showsActions {
                Rectangle()
                    .fill(AOMCraftColor.hairline)
                    .frame(width: 1, height: 14)

                Button(action: onActionsPanel) {
                    HStack(spacing: 6) {
                        Text("Actions")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                        AOMCraftKeycap(text: "⌘K")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(LauncherActionsKey(enabled: bindsKeys))
                .aomCalmHover(radius: 6)
                .accessibilityLabel("Actions, command K")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(AOMCraftColor.well)
        .overlay(alignment: .top) {
            Rectangle().fill(AOMCraftColor.hairline).frame(height: 0.5)
        }
    }
}

private struct LauncherActionsKey: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut("k", modifiers: .command) }
        else { content }
    }
}

private struct LauncherDefaultAction: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.defaultAction) }
        else { content }
    }
}
