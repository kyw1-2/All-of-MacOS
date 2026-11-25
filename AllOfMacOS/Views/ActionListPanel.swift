import SwiftUI

/// One step of an automation as an opaque card: a row in the shared row
/// style (step number, monochrome glyph, name over one line of detail, item
/// menu, disclosure chevron), and the step's options as groups inside the
/// same card when it is expanded.
struct ActionCardView: View {
    let action: TriggerAction
    let index: Int
    let depth: Int
    let isElse: Bool
    let isExpanded: Bool
    let trigger: Trigger
    @ObservedObject var keyboardMonitor: KeyboardMonitor
    let onToggleExpand: () -> Void
    let onChangeAction: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onToggleEnable: () -> Void
    var onCopy: () -> Void = {}
    var onAddInside: () -> Void = {}
    var onAddElse: () -> Void = {}
    /// Workbench 2 (D12): this step's options are open in the step inspector;
    /// the card is outlined in the accent instead of expanding.
    var isInspected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                // In-place parameter configuration; its groups draw their own
                // hairline above, so it needs no divider of its own.
                ActionConfigView(keyboardMonitor: keyboardMonitor, trigger: trigger, action: action)
            }
        }
        .aomCard(padding: 0)
        .overlay {
            if isInspected {
                RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                    .strokeBorder(AOMColor.accent, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isInspected ? .isSelected : [])
        .padding(.leading, CGFloat(depth) * AOMSpace.x5)
        .opacity(action.isEnabled ? 1 : 0.55)
        .animation(AOMMotion.panel, value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x2) {
            // 6.0: the step's mark with its number in a corner badge, the
            // way Shortcuts numbers nothing and Raycast marks every command.
            AOMAppIcon(AOMIdentity(symbol: action.actionType.iconName,
                                   color: action.isEnabled ? AOMModule.automation.hue : AOMBrand.graphite),
                       size: 26, active: action.isEnabled)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(index)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(AOMColor.surface, in: Capsule())
                        .overlay { Capsule().strokeBorder(AOMColor.hairline, lineWidth: 0.5) }
                        .offset(x: 5, y: 4)
                }
                .padding(.trailing, AOMSpace.x0_5)
                .accessibilityLabel("Step \(index)")

            if isElse {
                AOMStatusPill("Else", tone: .neutral, symbol: "arrow.triangle.branch")
            }

            // The name; its parameter value rides at the trailing edge.
            Text(action.displayName)
                .font(AOMFont.bodyEmphasis)
                .foregroundStyle(action.isEnabled ? AOMColor.text : AOMColor.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: AOMSpace.x2)

            if let detail = actionDetail {
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }

            // The step's own switch (it was a row inside the options).
            Toggle("Enabled", isOn: Binding(get: { action.isEnabled }, set: { _ in onToggleEnable() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(action.isEnabled ? "Turn this step off" : "Turn this step on")
                .accessibilityLabel("Step \(index) enabled")

            Menu {
                Button("Change Action…", action: onChangeAction)
                if action.actionType.canContainChildren {
                    Button(action.actionType == .toggleOnOff ? "Add to On…" : "Add Inside…", action: onAddInside)
                }
                if action.actionType.canContainElseChildren {
                    Button(action.actionType == .toggleOnOff ? "Add to Off…" : "Add to Else…", action: onAddElse)
                }
                Divider()
                Button("Move Up", action: onMoveUp)
                Button("Move Down", action: onMoveDown)
                Button("Copy", action: onCopy)
                Button("Duplicate", action: onDuplicate)
                Button(action.isEnabled ? "Disable" : "Enable", action: onToggleEnable)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(AOMColor.textSecondary)
            .fixedSize()
            .help("Action options")
            .accessibilityLabel("Options for \(action.displayName)")

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(AOMColor.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide options" : "Show options")
            .accessibilityLabel(isExpanded ? "Collapse action options" : "Expand action options")
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.rowDetail)
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
    }

    private var actionDetail: String? {
        switch action.actionType {
        case .actionGroup: return "\(action.parameters.children?.count ?? 0) actions"
        case .ifElse: return "Then \(action.parameters.children?.count ?? 0) · Else \(action.parameters.elseChildren?.count ?? 0)"
        case .setVariable: return "\(action.parameters.variableName ?? "") = \(action.parameters.variableValue ?? "")"
        case .customSnapWindow: return "\(Int((action.parameters.snapWidth ?? 0.5) * 100))% × \(Int((action.parameters.snapHeight ?? 1) * 100))%"
        case .wait: return "\(action.parameters.waitMs ?? 250) ms"
        case .typeText: return "\(action.parameters.text?.count ?? 0) characters"
        case .runAppleScript, .runShellScript: return "\(action.parameters.scriptContent?.utf8.count ?? 0) bytes · timeout \(action.parameters.scriptTimeoutSeconds ?? 30) s"
        case .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
            return action.parameters.applicationName
        case .openURL: return action.parameters.url
        case .captureArea: return "drag a region"
        case .captureFullscreen: return "pointer display"
        case .captureWindow: return "choose from list"
        case .captureWindowUnderCursor: return "window under pointer"
        case .capturePreviousArea: return CaptureSettings.lastArea.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "no previous area"
        case .captureScrolling: return "stitch a scrolling region"
        case .captureAllDisplays: return "every display"
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: return "OCR to clipboard"
        case .captureSelfTimer: return "\(action.parameters.selfTimerSeconds ?? 5) s delay"
        case .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
             .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
            return CaptureHistory.shared.mostRecent?.displayName ?? "no capture yet"
        default: return ActionSummary.detail(action)
        }
    }
}
