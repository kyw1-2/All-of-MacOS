import SwiftUI

/// The Focus page (design-3.4.0 b.2: status header + settings-style): the
/// session control with its ring and quick lengths, today's stats, what a
/// focus does, breaks and reminders, idle apps and memory, and the
/// activity log. Removing a list item never asks; the
/// toast and ⌘Z undo it.
struct FocusPage: View {
    @ObservedObject private var session = FocusModule.environment.session
    @ObservedObject private var settings = FocusModule.environment.settings
    @ObservedObject private var lists = FocusModule.environment.lists
    @ObservedObject private var idle = FocusModule.environment.idleApps
    @ObservedObject private var activity = FocusModule.environment.activity
    @StateObject private var toast = AOMToastModel()
    @Environment(\.undoManager) private var undoManager

    init() {}

    var body: some View {
        // When the page is selected, unless it was in the last few seconds.
        page.aomPageLifecycle(minimumInterval: 5, onActivate: {
            session.tick()
            session.refreshStats()
            idle.refreshPressure()
        })
    }

    private var page: some View {
        AOMPage {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                FocusSessionHeader(session: session, ticker: session.ticker, settings: settings)
                FocusLengthPicker(session: session, settings: settings)
            }
            // 7.2.3 (audit B08): a Focus file that couldn't be read is kept, never replaced.
            ForEach([session.log.problem, lists.problem, activity.problem].compactMap { $0 }, id: \.file) { problem in
                AOMNotice(problem.blocksSaving ? .error : .warning, problem.title, detail: problem.detail) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([problem.file]) }
                }
            }
            FocusColumns {
                FocusTodaySection(stats: session.stats)
            } trailing: {
                FocusBreaksSection(settings: settings)
            }
            FocusColumns {
                FocusDuringSection(settings: settings, lists: lists, session: session, removeDistraction: removeDistraction)
            } trailing: {
                FocusRemindersSection(settings: settings)
            }
            .id("focus.during")
            FocusIdleAppsSection(idle: idle, lists: lists, settings: settings, remove: removeIdleRule)
                .id("focus.idle")
            FocusMemorySection(idle: idle, settings: settings, activity: activity)
                .id("focus.memory")
            AOMLogSection("Activity", entries: activity.items.map(\.logEntry), limit: 6, emptySymbol: "list.bullet.rectangle",
                          emptyMessage: "No Focus activity yet.",
                          clear: { activity.clear() })
        }
        .aomPage("Focus")
        .aomToast(toast)
    }

    // MARK: Undoable removals

    private func removeDistraction(_ app: FocusAppRef) {
        guard let index = lists.lists.distractingApps.firstIndex(of: app) else { return }
        AOMUndo.perform("Remove \(app.name)", undoManager: undoManager, perform: {
            lists.removeDistraction(app.bundleID)
        }, revert: {
            if !lists.lists.distractingApps.contains(app) {
                lists.lists.distractingApps.insert(app, at: min(index, lists.lists.distractingApps.count))
            }
        })
        toast.show("Removed \(app.name)", action: { undoManager?.undo() })
    }

    private func removeIdleRule(_ rule: FocusIdleRule) {
        guard let index = lists.lists.idleRules.firstIndex(where: { $0.id == rule.id }) else { return }
        AOMUndo.perform("Remove Rule", undoManager: undoManager, perform: {
            lists.removeIdleRule(rule.id)
        }, revert: {
            lists.insertIdleRule(rule, at: index)
        })
        toast.show("Removed \(rule.name)", action: { undoManager?.undo() })
    }
}
