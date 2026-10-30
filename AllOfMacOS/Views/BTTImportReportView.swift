import SwiftUI

/// The BetterTouchTool import report: what was imported, what was mapped
/// approximately and why, and what was skipped, with BTT names and IDs.
/// Presented as the accessory of the import review alert by
/// `AppState.reviewCompatiblePresetImport(from:)`.
///
/// Layout (e.2): the summary with an ⓘ, at most two notices, then one section
/// per group: its title with a status pill for the count above an opaque card
/// of entry rows. Each group collapses from its title.
struct BTTImportReportView: View {
    let report: BTTPresetImport.Report
    var namedTriggerCollisions: [String] = []
    @State private var collapsed: Set<BTTPresetImport.Entry.Group> = []

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    ForEach(BTTPresetImport.Entry.Group.allCases) { group in
                        let entries = report.entries(in: group)
                        if !entries.isEmpty { section(group, entries) }
                    }
                }
                .padding(.vertical, AOMSpace.x1)
            }
        }
        .frame(minWidth: AOMEditorSize.importReport.width, minHeight: AOMEditorSize.importReport.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("BetterTouchTool import report")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            if let name = report.presetName {
                Text("Preset “\(name)”")
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
            }
            HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x1) {
                Text(report.summary)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                AOMInfoButton("Exact matches keep their BTT enabled state. Approximate matches and every script step are added disabled. Nothing runs during import, and your current preset is kept.",
                              topic: "the import")
            }
            if report.reviewCount > 0 {
                AOMNotice(.warning, "\(report.reviewCount) item(s) contain scripts, Shortcuts, executable files or app links.",
                          detail: "Read them before enabling.")
            }
            if !namedTriggerCollisions.isEmpty {
                AOMNotice(.warning, "Named triggers that already exist: \(namedTriggerCollisions.joined(separator: ", ")).",
                          detail: "Rename or remove duplicates before enabling.")
            }
        }
    }

    private func section(_ group: BTTPresetImport.Entry.Group, _ entries: [BTTPresetImport.Entry]) -> some View {
        let open = !collapsed.contains(group)
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle(group.rawValue, help: Self.help(group)) {
                AOMStatusPill("\(entries.count)", tone: Self.tone(group), symbol: Self.symbol(group))
                Button { toggle(group) } label: {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(AOMColor.textSecondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide \(group.rawValue)" : "Show \(group.rawValue)")
                .accessibilityLabel("\(group.rawValue), \(entries.count) items")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, showsDivider: index > 0)
                    }
                }
                .aomCard(padding: 0)
                .transition(.opacity)
            }
        }
    }

    private func row(_ entry: BTTPresetImport.Entry, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
            HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                Text(entry.title)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(2)
                if entry.needsReview {
                    AOMStatusPill("Review", tone: .warning, symbol: "exclamationmark.shield")
                }
                Spacer(minLength: AOMSpace.x2)
                Text(entry.scope)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            Text("BTT \(entry.kind.rawValue.lowercased()): \(entry.bttName) · \(entry.bttID)")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .textSelection(.enabled)
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
            }
            ForEach(Array(entry.reasons.enumerated()), id: \.offset) { _, reason in
                Text("• " + reason)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail, alignment: .leading)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider() } }
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ group: BTTPresetImport.Entry.Group) {
        withAnimation(AOMMotion.standard) {
            if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        }
    }

    private static func symbol(_ group: BTTPresetImport.Entry.Group) -> String {
        switch group {
        case .imported: return "checkmark.circle.fill"
        case .approximate: return "arrow.triangle.branch"
        case .skipped: return "xmark.circle.fill"
        }
    }

    private static func tone(_ group: BTTPresetImport.Entry.Group) -> AOMTone {
        switch group {
        case .imported: return .success
        case .approximate: return .warning
        case .skipped: return .neutral
        }
    }

    private static func help(_ group: BTTPresetImport.Entry.Group) -> String {
        switch group {
        case .imported:
            return "Exact matches. They keep their BTT names, notes, app scope and enabled state; script steps still arrive disabled."
        case .approximate:
            return "Close matches that AOM can't reproduce exactly. They arrive disabled, and each reason is kept in the trigger's notes."
        case .skipped:
            return "BTT triggers and actions with no AOM equivalent, by BTT name and ID. A dropped step stays in its trigger as a disabled placeholder."
        }
    }
}
