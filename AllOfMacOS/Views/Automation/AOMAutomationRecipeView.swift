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
    /// False inside the Automation editor, which already scrolls.
    var scrolls = true
    var canRun = true

    var body: some View {
        if scrolls {
            ScrollView { spine.padding(AOMSpace.pageMargin) }.background(AOMPageTint())
        } else {
            spine
        }
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: triggerSymbol, size: AOMIcon.tileBadge)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("WHEN").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
                    Text(triggerName).font(AOMFont.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(scopeLabel).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                Button(action: onRun) { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(AOMSoftButtonStyle())
                    .disabled(!canRun)
            }
            .aomContentCard(radius: AOMRadius.card, padding: AOMSpace.x3)

            if !conditionChips.isEmpty {
                spineConnector
                HStack(spacing: AOMSpace.x2) {
                    Text("IF").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.warningText)
                    ForEach(conditionChips, id: \.self) { chip in
                        Text(chip).font(AOMFont.caption)
                            .padding(.horizontal, AOMSpace.x2).padding(.vertical, AOMSpace.x1)
                            .background(AOMColor.track, in: Capsule())
                    }
                }
                .padding(AOMSpace.x2)
            }

            ForEach(steps) { step in
                spineConnector
                AOMRecipeStepCard(step: step)
            }
            spineConnector
            Button(action: onAddStep) { Label("Add Action", systemImage: "plus") }
                .buttonStyle(AOMTintedButtonStyle())
        }
        .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
    }

    private var spineConnector: some View {
        Rectangle().fill(AOMColor.hairline)
            .frame(width: 1, height: AOMSpace.x3)
            .padding(.leading, AOMSpace.x8)
            .accessibilityHidden(true)
    }
}

struct AOMRecipeStepCard: View {
    let step: AOMRecipeStepViewModel
    var body: some View {
        AOMRecipeStepRows(step: step)
            .aomContentCard(radius: AOMRadius.card, padding: AOMSpace.x3)
    }
}

/// A recursive body, but only the top-level step receives a card surface.
private struct AOMRecipeStepRows: View {
    let step: AOMRecipeStepViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                stepBadge
                Image(systemName: step.symbol)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(step.title).font(AOMFont.body.weight(.medium))
                        .foregroundStyle(step.isEnabled ? AOMColor.text : AOMColor.textSecondary)
                    if let subtitle = step.subtitle {
                        Text(subtitle).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    }
                    if case .failed(let reason) = step.runStatus {
                        Text(reason).font(AOMFont.callout).foregroundStyle(AOMColor.dangerText)
                    }
                }
                Spacer(minLength: 0)
            }
            if step.isBranchContainer {
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    branch("THEN", tint: AOMColor.accent, steps: step.thenChildren)
                    if !step.elseChildren.isEmpty {
                        branch("OTHERWISE", tint: AOMColor.warningText, steps: step.elseChildren)
                    }
                    Text("END").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
                }
                .padding(.leading, AOMSpace.x4)
            }
        }
    }

    private func branch(_ title: String, tint: Color, steps: [AOMRecipeStepViewModel]) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            Text(title).font(AOMFont.caption.weight(.semibold)).foregroundStyle(tint)
            ForEach(steps) { child in
                AOMRecipeStepRows(step: child)
                    .padding(.vertical, AOMSpace.x1)
            }
        }
        .padding(.leading, AOMSpace.x3)
        .overlay(alignment: .leading) {
            Capsule().fill(tint.opacity(0.65)).frame(width: 2).accessibilityHidden(true)
        }
    }

    private var statusLabel: String {
        switch step.runStatus {
        case .idle: "Idle"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        }
    }

    private var stepBadge: some View {
        ZStack {
            Circle().fill(AOMColor.track)
            switch step.runStatus {
            case .idle:
                Text("\(step.index)").font(AOMFont.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(AOMColor.textSecondary)
            case .running:
                ProgressView().controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark").font(AOMFont.caption.weight(.bold)).foregroundStyle(AOMColor.successText)
            case .failed:
                Image(systemName: "xmark").font(AOMFont.caption.weight(.bold)).foregroundStyle(AOMColor.dangerText)
            }
        }
        .frame(width: AOMIcon.tileMark, height: AOMIcon.tileMark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.index)")
        .accessibilityValue(statusLabel)
    }
}
