import SwiftUI

/// The one notice the Automation list shows when none of its automations can
/// run: Accessibility or Input Monitoring is missing, or AOM is paused (e.6:
/// at the top of the affected section, one sentence, one verb button). Shows
/// nothing while everything can run. Polled every 5 s, because neither the
/// permissions nor the timed pause publish their changes.
struct AutomationStatusNotice: View {
    @EnvironmentObject private var appState: AppState
    @State private var blocking: AOMPermission?
    @State private var suppressionPaused = false
    @State private var suppressionDetail: String?

    var body: some View {
        VStack(spacing: 0) {
            // Always present, so the polling task runs while no notice shows.
            Color.clear.frame(height: 0)
            if let permission = blocking {
                // "Accessibility is off." in bold, its consequence underneath:
                // one bold sentence wraps to four lines in the list column.
                let sentence = permission.attentionSentence
                let cut = sentence.range(of: ". ")
                AOMNotice(.warning, cut.map { String(sentence[..<$0.lowerBound]) + "." } ?? sentence,
                          detail: cut.map { String(sentence[$0.upperBound...]) }) {
                    Button("Allow…") { _ = permission.openSettings() }
                }
                .padding([.horizontal, .top], AOMSpace.x2)
            } else if !appState.globalEnabled || suppressionPaused {
                AOMNotice(.info, "AOM is paused, so automations don't run.",
                          detail: suppressionPaused ? suppressionDetail : nil) {
                    Button("Resume", action: resume)
                }
                .padding([.horizontal, .top], AOMSpace.x2)
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refresh() {
        let missing = AOMPermission.required.first { permission in
            guard permission == .accessibility || permission == .inputMonitoring else { return false }
            let status = permission.status
            return status == .denied || status == .notDetermined
        }
        if missing != blocking { blocking = missing }
        let suppression = TriggerSuppression.shared
        let paused = suppression.isPaused
        if paused != suppressionPaused { suppressionPaused = paused }
        let detail = paused ? suppression.statusDescription : nil
        if detail != suppressionDetail { suppressionDetail = detail }
    }

    /// The same resume as the Workspace hero: the master switch and any timed pause.
    private func resume() {
        if !appState.globalEnabled { appState.toggleGlobalEnabled() }
        if suppressionPaused {
            TriggerSuppression.shared.resume()
            suppressionPaused = false
        }
    }
}
