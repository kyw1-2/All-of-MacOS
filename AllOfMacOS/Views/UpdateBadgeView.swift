import SwiftUI

struct UpdateBadgeView: View {
    @ObservedObject var updateChecker: UpdateChecker
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// A quiet version chip: the version is metadata, so it reads like a
    /// keycap, not like a coloured call to action.
    var body: some View {
        Text("v\(currentVersion)")
            .font(AOMFont.badge.weight(.semibold).monospacedDigit())
            .foregroundStyle(AOMColor.textSecondary)
            .padding(.horizontal, AOMSpace.x2)
            .padding(.vertical, AOMSpace.x0_5 + 1)
            .background(AOMColor.track, in: Capsule())
            .overlay(Capsule().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
            .help("All of MacOS v\(currentVersion) (Custom Build)")
    }
}
