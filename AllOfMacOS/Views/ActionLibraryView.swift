import SwiftUI

/// The action catalog is browsed through the one `BrowseActionsSheet` picker.
/// System Tools and Automation both call this, so there is a single picker
/// implementation; System Tools shows it until its All Actions section moves
/// out to Automation.
struct ActionLibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingBrowser = false

    var body: some View {
        Button("Browse Actions…") { showingBrowser = true }
            .help("Browse every action AOM can run")
            .sheet(isPresented: $showingBrowser) {
                BrowseActionsSheet().environmentObject(appState)
            }
    }
}
