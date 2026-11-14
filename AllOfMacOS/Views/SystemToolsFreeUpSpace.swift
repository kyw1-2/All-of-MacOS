import SwiftUI

/// Storage's one sheet: a sidebar of the scans (Folder Sizes, Large Files, Old
/// Downloads, Duplicates, Xcode Junk, Caches, Trash) and the chosen scan's
/// preview, so nothing leaves the sheet to run a scan.
struct FreeUpSpaceSheet: View {
    @ObservedObject var model: SystemToolsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: "externaldrive.badge.minus", hue: .brown, size: AOMIcon.headerBadge)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("Free Up Space").font(AOMFont.pageStatus)
                    Text("Scans read only; what you check moves to the Trash.").font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: AOMSpace.x3) {
                List(selection: Binding(get: { model.cleanupScan }, set: { model.selectCleanup($0 ?? model.cleanupScan) })) {
                    ForEach(SystemToolsModel.CleanupScan.allCases) { scan in
                        Label(scan.title, systemImage: scan.symbol).tag(scan)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                Group {
                    if let review = model.cleanupReview {
                        CleanupReviewContent(review: review,
                                             onTrash: { model.trashSelected($0) },
                                             onCancel: { model.cleanupReview = nil })
                    } else {
                        VStack(spacing: AOMSpace.x3) {
                            Image(systemName: model.cleanupScan.symbol)
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(AOMColor.textSecondary)
                            Text(model.cleanupScan.title).font(AOMFont.section)
                            Text(model.cleanupScan.help).font(AOMFont.callout)
                                .foregroundStyle(AOMColor.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("Start Scan…") { model.startCleanup(model.cleanupScan) }
                            if model.running.contains(.freeUpSpace) {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: 780, height: 560)
        .background(AOMColor.canvas)
        .aomToast(model.toasts)
        .onExitCommand { dismiss() }
    }
}
