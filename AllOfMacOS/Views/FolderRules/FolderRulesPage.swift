import SwiftUI

/// 3.4 scaffold: the Folder Rules page. The module's agent replaces this body.
struct FolderRulesPage: View {
    var body: some View {
        AOMPage {
            AOMPageHeader("Folder Rules", module: .folderRules, subtitle: AOMMainTab.folderRules.subtitle)
        }
        .aomPage("Folder Rules")
    }
}
