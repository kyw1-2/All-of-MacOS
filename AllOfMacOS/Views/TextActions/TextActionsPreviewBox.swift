import SwiftUI

/// Sample selections for the page's live preview: each one brings out the
/// actions that only appear for that kind of text.
enum TextActionsPreviewSample: String, CaseIterable, Identifiable {
    case text, korean, link, email, sum, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .korean: return "Korean"
        case .link: return "Link"
        case .email: return "Email"
        case .sum: return "Sum"
        case .json: return "JSON"
        }
    }

    var text: String {
        switch self {
        case .text: return "The quick brown fox jumps over the lazy dog"
        case .korean: return "선택한 문장을 바로 번역해 보세요"
        case .link: return "github.com/apple/swift"
        case .email: return "hello@example.com"
        case .sum: return "(1280 × 3) + 64"
        case .json: return #"{"name": "AOM", "version": "3.4.0"}"#
        }
    }

    /// The sample that shows an action at its best.
    static func best(for id: TextActionID) -> Self {
        switch id {
        case .openLink: return .link
        case .newEmail: return .email
        case .calculate: return .sum
        case .formatJSON: return .json
        case .translate: return .korean
        default: return .text
        }
    }
}

/// The bar exactly as it will look with the current settings, over a mock
/// selection in a text field. The items show their tooltips; clicking runs
/// nothing except paging and the transform menus.
struct TextActionsPreviewBox: View {
    let settings: TextActionsSettings
    let sample: TextActionsPreviewSample
    @StateObject private var model = TextActionBarModel()
    @State private var hasItems = true

    /// The preview pages at a width that fits the detail column.
    static let maxBarWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            if hasItems {
                TextActionBarView(model: model, inWindow: true)
                    .accessibilityLabel("Preview of the Text Actions bar")
            } else {
                Text("No switched-on action applies to this text.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(height: TextActionBarMetrics.height)
            }
            Text(sample.text)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, AOMSpace.x0_5)
                .background(AOMColor.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: AOMRadius.keycap - 2, style: .continuous))
                .accessibilityLabel("Selected text: \(sample.text)")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AOMSpace.x5)
        .padding(.horizontal, AOMSpace.x3)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        .task(id: PreviewKey(settings: settings, sample: sample)) { rebuild() }
    }

    private struct PreviewKey: Equatable {
        let settings: TextActionsSettings
        let sample: TextActionsPreviewSample
    }

    private func rebuild() {
        let traits = TextSelectionClassifier.classify(sample.text)
        let context = TextActionContext(
            editability: .editable,
            calculation: traits.isCalculatorCandidate ? AOMCalculator.evaluate(traits.text) : nil,
            chatGPTInstalled: TextActionPerformer.chatGPTApplicationURL() != nil,
            clipboardHasContent: true)
        let actions = TextActionApplicability.actions(settings: settings, traits: traits, context: context)
        let items = TextActionBarItems.make(actions, traits: traits, context: context, speaking: false)
        hasItems = !items.isEmpty
        model.set(items, showsNames: settings.showsNames, maxWidth: Self.maxBarWidth)
        model.perform = { _, _, _ in }
    }
}
