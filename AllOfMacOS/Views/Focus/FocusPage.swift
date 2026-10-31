import SwiftUI

/// 3.4 scaffold: the Focus page. The module's agent replaces this body.
struct FocusPage: View {
    var body: some View {
        AOMPage {
            AOMPageHeader("Focus", module: .focus, subtitle: AOMMainTab.focus.subtitle)
        }
        .aomPage("Focus")
    }
}
