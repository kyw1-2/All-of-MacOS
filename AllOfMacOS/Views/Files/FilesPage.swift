import SwiftUI

/// 3.4 scaffold: the Files page. The module's agent replaces this body.
struct FilesPage: View {
    var body: some View {
        AOMPage {
            AOMPageHeader("Files", module: .files, subtitle: AOMMainTab.files.subtitle)
        }
        .aomPage("Files")
    }
}
