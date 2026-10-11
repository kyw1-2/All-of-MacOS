import SwiftUI

struct UpdateBadgeView: View {
    @ObservedObject var updateChecker: UpdateChecker
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        Text("v\(currentVersion)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        .linearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .help("All of MacOS v\(currentVersion) (Custom Build)")
    }
}
