import SwiftUI

enum AOMStepRunStatus: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)
}

struct AOMRecipeStepViewModel: Identifiable {
    let id: UUID
    let index: Int
    let title: String
    let subtitle: String?
    let symbol: String
    var isEnabled: Bool
    var runStatus: AOMStepRunStatus
    let isBranchContainer: Bool
    var thenChildren: [AOMRecipeStepViewModel]
    var elseChildren: [AOMRecipeStepViewModel]
}

struct AOMAutomationRecipeCanvas: View {
    let triggerName: String
    let triggerSymbol: String
    let scopeLabel: String
    let conditionChips: [String]
    let steps: [AOMRecipeStepViewModel]
    let onRun: () -> Void
    let onAddStep: () -> Void
    /// 7.0: false inside a page that already scrolls (the Automation editor).
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { spine.padding(20) }
                .background(AOMCraftColor.canvas)
        } else {
            spine
        }
    }

    private var spine: some View {
            VStack(alignment: .leading, spacing: 0) {
                // 1. WHEN 카드
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.indigo.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: triggerSymbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WHEN")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                        Text(triggerName)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Text(scopeLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                    Button(action: onRun) {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .aomContentCard(radius: AOMCraftRadius.card, padding: 14)

                // 2. IF 조건 스트립 (조건이 있을 때만 스파인에 연결)
                if !conditionChips.isEmpty {
                    spineConnector(height: 16)
                    HStack(spacing: 6) {
                        Text("IF")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                        ForEach(conditionChips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AOMCraftColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5))
                }

                // 3. DO 스텝 타임라인
                ForEach(steps) { step in
                    spineConnector(height: 14)
                    AOMRecipeStepCard(step: step)
                }

                spineConnector(height: 14)

                Button(action: onAddStep) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Action")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AOMCraftColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 740, alignment: .leading)
    }

    private func spineConnector(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 2, height: height)
            .padding(.leading, 32)
    }
}

struct AOMRecipeStepCard: View {
    let step: AOMRecipeStepViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stepBadge
                Image(systemName: step.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(step.isEnabled ? 1 : 0.45)
                    if let sub = step.subtitle {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                    }
                    if case .failed(let reason) = step.runStatus {
                        Text(reason)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }

            // 중첩 분기 컨테이너: 좌측 컬러 레일 + 명시적 Otherwise / End 경계
            if step.isBranchContainer {
                VStack(alignment: .leading, spacing: 8) {
                    branchSection(label: "THEN", tint: .accentColor, children: step.thenChildren)
                    if !step.elseChildren.isEmpty {
                        branchSection(label: "OTHERWISE", tint: .orange, children: step.elseChildren)
                    }
                    Text("END")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .padding(.leading, 18)
                .padding(.top, 4)
            }
        }
        .aomContentCard(radius: AOMCraftRadius.card, padding: 12)
    }

    private func branchSection(label: String, tint: Color, children: [AOMRecipeStepViewModel]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint.opacity(0.55))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
                ForEach(children) { child in
                    AOMRecipeStepCard(step: child)
                }
            }
        }
    }

    private var statusLabel: LocalizedStringKey {
        switch step.runStatus {
        case .idle: "Idle"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private var stepBadge: some View {
        ZStack {
            switch step.runStatus {
            case .idle:
                Circle().fill(Color.primary.opacity(0.08))
                Text("\(step.index)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AOMCraftColor.inkSecondary)
            case .running:
                Circle().fill(Color.accentColor.opacity(0.16))
                ProgressView().controlSize(.mini)
            case .succeeded:
                Circle().fill(Color.green.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
            case .failed:
                Circle().fill(Color.red.opacity(0.18))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step.index)"))
        .accessibilityValue(Text(statusLabel))
    }
}
