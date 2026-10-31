import SwiftUI

/// The Focus page (design-3.4.0 b.2: status header + settings-style): the
/// session control with its ring and quick lengths, today's stats, what a
/// focus does, breaks and reminders, idle apps and memory, per-app input
/// sources, and the activity log. Removing a list item never asks; the
/// toast and ⌘Z undo it.
struct FocusPage: View {
    @ObservedObject private var session = FocusModule.environment.session
    @ObservedObject private var settings = FocusModule.environment.settings
    @ObservedObject private var lists = FocusModule.environment.lists
    @ObservedObject private var idle = FocusModule.environment.idleApps
    @ObservedObject private var activity = FocusModule.environment.activity
    @ObservedObject private var inputSources = FocusModule.environment.inputSources
    @StateObject private var toast = AOMToastModel()
    @Environment(\.undoManager) private var undoManager

    init() {}

    var body: some View {
        ScrollViewReader { scroller in
            page
                .task {
                    FocusPreviewSystem.seed(FocusModule.environment)
                    session.tick()
                    session.refreshStats()
                    idle.refreshPressure()
                    inputSources.reloadSources()
                    // Isolated previews: `--aom-preview-focus-scroll idle|memory|inputSources`.
                    if let section = FocusPreviewSystem.requestedSection {
                        try? await Task.sleep(for: .milliseconds(600))
                        scroller.scrollTo("focus.\(section)", anchor: .top)
                    }
                }
        }
    }

    private var page: some View {
        AOMPage {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                FocusSessionHeader(session: session, ticker: session.ticker, settings: settings)
                FocusLengthPicker(session: session, settings: settings)
            }
            AOMTipCard(id: "focus.memory", symbol: "memorychip", title: "Free memory on this Mac",
                       message: "List apps you leave open, like chat and mail. Focus hides or quits them once they've been idle, and quits the idlest first when memory runs low.")
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
            FocusInputSourcesSection(controller: inputSources, lists: lists, settings: settings,
                                     remove: removeInputSourceRule) { count in
                toast.show(count == 0 ? "No suggestions: the apps aren't installed or already listed"
                                      : "Added \(count) \(count == 1 ? "app" : "apps")",
                           tone: count == 0 ? .info : .success)
            }
            .id("focus.inputSources")
            AOMLogSection("Activity", entries: activity.items.map(\.logEntry), limit: 6, emptySymbol: "list.bullet.rectangle",
                          emptyMessage: "Nothing yet. Hidden and quit apps and shortcut runs appear here.",
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

    private func removeInputSourceRule(_ rule: FocusInputSourceRule) {
        guard let index = lists.lists.inputSourceRules.firstIndex(where: { $0.id == rule.id }) else { return }
        AOMUndo.perform("Remove \(rule.appName)", undoManager: undoManager, perform: {
            lists.removeInputSourceRule(rule.id)
        }, revert: {
            if !lists.lists.inputSourceRules.contains(where: { $0.id == rule.id }) {
                lists.lists.inputSourceRules.insert(rule, at: min(index, lists.lists.inputSourceRules.count))
            }
        })
        toast.show("Removed \(rule.appName)", action: { undoManager?.undo() })
    }
}
