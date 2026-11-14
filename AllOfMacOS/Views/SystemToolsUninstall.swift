import AppKit
import UniformTypeIdentifiers

/// The app uninstaller: choose an app (or drop one on the tile), quit it
/// after asking if it is running, then review it with its leftovers grouped
/// by folder.
extension SystemToolsModel {
    /// Choose an app (or take one dropped on the tile), quit it after asking
    /// if it is running, then review it with its leftovers grouped by folder.
    func reviewUninstall(_ dropped: URL?) {
        let app: URL
        if let dropped {
            app = dropped
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Review"
            panel.message = "Choose an app. You'll see it with its leftovers before anything moves to the Trash."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            app = url
        }
        guard let bundleID = Bundle(url: app)?.bundleIdentifier else {
            fail(.uninstall, CleanupTools.UninstallRefusal.notAnApp); return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard !running.isEmpty else { reviewUninstall(app); return }
        let name = running.first?.localizedName ?? app.deletingPathExtension().lastPathComponent
        guard confirm("Quit \(name) First?", "\(name) is open. AOM asks it to quit the normal way (it can still ask to save), then shows what would move to the Trash.",
                      button: "Quit and Review", destructive: false) else { return }
        running.forEach { $0.terminate() }
        self.running.insert(.uninstall)
        waitForQuit(running, app: app, name: name, triesLeft: 20)
    }

    private func waitForQuit(_ apps: [NSRunningApplication], app: URL, name: String, triesLeft: Int) {
        if apps.allSatisfy(\.isTerminated) {
            running.remove(.uninstall)
            reviewUninstall(app)
        } else if triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForQuit(apps, app: app, name: name, triesLeft: triesLeft - 1) }
        } else {
            running.remove(.uninstall)
            fail(.uninstall, "\(name) Didn't Quit", "\(name) is still open, probably asking about unsaved work. Nothing was moved.")
        }
    }

    private func reviewUninstall(_ app: URL) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.uninstall, { try CleanupTools.uninstallReview(for: app, library: library) }) { review in
            let name = app.deletingPathExtension().lastPathComponent
            let nameOnly = review.items.count - review.preselected.count
            self.cleanupTool = .uninstall
            self.cleanupReview = CleanupReview(
                title: "Uninstall \(name)",
                detail: "The app and the files it left in ~/Library, by folder. Files named with its bundle ID are checked"
                    + (nameOnly > 0 ? "; \(nameOnly) that only share its name are not, because other apps may use them" : "")
                    + ". Everything goes to the Trash, so Finder's Put Back works.",
                candidates: review.items, selected: review.preselected, groupsByNote: true, safeDefault: true,
                hints: Dictionary(uniqueKeysWithValues: review.nameOnly.map { ($0, "Matches the app's name only; check it if it's this app's") }))
        }
    }
}
