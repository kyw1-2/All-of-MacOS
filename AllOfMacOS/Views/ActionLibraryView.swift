import SwiftUI

/// The complete action catalog is browsable without first guessing a trigger.
/// Configuration creates a disabled draft, so opening a feature never executes
/// a destructive or input-producing action in the currently focused app.
///
/// Hosted inside the "All Actions" section card on System Tools, so it shows
/// no title of its own: one line of scope, the filter, then one row per action
/// in the shared row style (glyph, name with an ⓘ for its options, one line
/// of what it does, Configure… at the trailing edge).
struct ActionLibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var category: ActionCategory?

    private var actions: [ActionType] {
        ActionType.allCases.filter { type in
            (category == nil || type.category == category) &&
            query.split(whereSeparator: \.isWhitespace).allSatisfy { type.searchText.localizedStandardContains(String($0)) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            AOMEditorNote("Browse every built-in capability and configure it as an automation. New drafts stay off until you enable them.")
            HStack(spacing: AOMSpace.x2) {
                TextField("Search actions, descriptions and parameters", text: $query).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(ActionCategory?.none)
                    ForEach(ActionCategory.allCases, id: \.self) { Text($0.rawValue).tag(ActionCategory?.some($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: AOMEditorSize.libraryCategory)
            }
            Text("\(actions.count) actions")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .monospacedDigit()
            LazyVStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element) { index, type in
                    row(type, showsDivider: index > 0)
                }
            }
        }
    }

    private func row(_ type: ActionType, showsDivider: Bool) -> some View {
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            Image(systemName: type.iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(spacing: AOMSpace.x1) {
                    Text(type.rawValue)
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                    if !type.parameterHint.isEmpty {
                        AOMInfoButton("Options: " + type.parameterHint, topic: type.rawValue)
                    }
                }
                Text(type.description)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x3)
            Button("Configure…") { appState.createDraft(for: type) }
        }
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMIcon.row + AOMSpace.x3, trailingInset: 0) }
        }
    }
}

extension AppState {
    @MainActor func createDraft(for type: ActionType) {
        var trigger = Trigger(name: type.rawValue, input: .namedTrigger("draft-" + UUID().uuidString))
        var action = TriggerAction(actionType: type)
        action.parameters = type.defaultParameters
        trigger.actions = [action]
        trigger.isEnabled = false
        selectedActivationGroupID = nil
        selectedAppTarget = .allApps
        selectedTriggerCategory = .all
        addTrigger(trigger)
        selectedAction = action
        selectedMainTab = .gestures
    }
}
