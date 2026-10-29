import SwiftUI

/// The BetterTouchTool import report: what was imported, what was mapped
/// approximately and why, and what was skipped, with BTT names and IDs.
/// Presented as the accessory of the import review alert by
/// `AppState.reviewCompatiblePresetImport(from:)`.
struct BTTImportReportView: View {
    let report: BTTPresetImport.Report
    var namedTriggerCollisions: [String] = []
    @State private var collapsed: Set<BTTPresetImport.Entry.Group> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(BTTPresetImport.Entry.Group.allCases) { group in
                        let entries = report.entries(in: group)
                        if !entries.isEmpty { section(group, entries) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("BetterTouchTool import report")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = report.presetName {
                Text("Preset “\(name)”").font(.headline)
            }
            Text(report.summary).font(.callout)
            Text("Exact matches keep their BTT enabled state. Approximate matches and every script step are added disabled. Nothing runs during import, and your current preset is kept.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if report.reviewCount > 0 {
                Label("\(report.reviewCount) item(s) contain scripts, Shortcuts, executable files or app links. Read them before enabling.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !namedTriggerCollisions.isEmpty {
                Label("Named triggers that already exist: \(namedTriggerCollisions.joined(separator: ", ")). Rename or remove duplicates before enabling.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func section(_ group: BTTPresetImport.Entry.Group, _ entries: [BTTPresetImport.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down").font(.caption.weight(.semibold))
                    Image(systemName: icon(group)).foregroundStyle(tint(group))
                    Text("\(group.rawValue) (\(entries.count))").font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.rawValue), \(entries.count) items")
            if !collapsed.contains(group) {
                ForEach(entries) { entry in row(entry) }
            }
        }
    }

    private func row(_ entry: BTTPresetImport.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                if entry.needsReview {
                    Text("Review").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(entry.scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("BTT \(entry.kind.rawValue.lowercased()): \(entry.bttName) · \(entry.bttID)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !entry.detail.isEmpty {
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.reasons.enumerated()), id: \.offset) { _, reason in
                Text("• " + reason).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
    }

    private func icon(_ group: BTTPresetImport.Entry.Group) -> String {
        switch group {
        case .imported: return "checkmark.circle.fill"
        case .approximate: return "arrow.triangle.branch"
        case .skipped: return "xmark.circle.fill"
        }
    }
    private func tint(_ group: BTTPresetImport.Entry.Group) -> Color {
        switch group {
        case .imported: return .green
        case .approximate: return .orange
        case .skipped: return .secondary
        }
    }
}
