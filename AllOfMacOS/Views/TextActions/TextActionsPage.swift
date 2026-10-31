import SwiftUI

/// 3.4 scaffold: the Text Actions page. The module's agent replaces this body.
struct TextActionsPage: View {
    var body: some View {
        AOMPage {
            AOMPageHeader("Text Actions", module: .textActions, subtitle: AOMMainTab.textActions.subtitle)
        }
        .aomPage("Text Actions")
    }
}
