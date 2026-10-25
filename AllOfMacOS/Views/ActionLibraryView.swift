import SwiftUI

/// The complete action catalog is browsable without first guessing a trigger.
/// Configuration creates a disabled draft, so opening a feature never executes
/// a destructive or input-producing action in the currently focused app.
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
        VStack(alignment: .leading, spacing: 14) {
            Text("All Actions").font(.title2.bold())
            Text("Browse every built-in capability and configure it as an automation. New drafts stay off until you enable them.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search actions, descriptions and parameters", text: $query).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(ActionCategory?.none)
                    ForEach(ActionCategory.allCases, id: \.self) { Text($0.rawValue).tag(ActionCategory?.some($0)) }
                }.frame(maxWidth: 240)
            }
            Text("\(actions.count) actions").font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(actions, id: \.self) { type in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: type.iconName).font(.title3).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(type.rawValue).font(.headline)
                            Text(type.description).font(.callout).foregroundStyle(.secondary)
                            if !type.parameterHint.isEmpty {
                                Text(type.parameterHint).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Configure…") { appState.createDraft(for: type) }
                    }
                    .padding(.vertical, 12)
                    Divider()
                }
            }
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
