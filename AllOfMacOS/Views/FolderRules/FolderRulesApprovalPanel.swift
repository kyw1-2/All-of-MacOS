import AppKit
import Combine
import SwiftUI

/// The floating "ask first" card: when a rule wants to move something to the
/// Trash, optimize, compress, extract or install, it asks here without taking
/// focus from the app in front. Skip and the approve button act at once;
/// Review… opens the page. Closing the card keeps the question waiting on
/// the page and in the status menu.
@MainActor
final class FolderRulesApprovalPanel {
    static let shared = FolderRulesApprovalPanel()

    private var panel: FolderRulesFloatingPanel?
    private var cancellable: AnyCancellable?
    private var dismissed: Set<UUID> = []
    private weak var engine: FolderRulesEngine?

    func observe(_ engine: FolderRulesEngine) {
        self.engine = engine
        cancellable = engine.$approvals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] approvals in MainActor.assumeIsolated { self?.update(approvals) } }
    }

    private func update(_ approvals: [FolderRuleApproval]) {
        dismissed = dismissed.intersection(approvals.map(\.id))
        let visible = approvals.filter { !dismissed.contains($0.id) }
        guard let engine, let first = visible.first else {
            panel?.orderOut(nil)
            return
        }
        let card = FolderRulesApprovalCard(engine: engine, approval: first, remaining: visible.count - 1) { [weak self] in
            self?.dismissed.insert(first.id)
            self?.update(engine.approvals)
        }
        let hosting = NSHostingView(rootView: AnyView(card))
        let size = hosting.fittingSize
        let panel = self.panel ?? FolderRulesFloatingPanel(size: size)
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - AOMSpace.x4, y: frame.maxY - size.height - AOMSpace.x4))
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: first.question, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// A floating, non-activating panel: clicks work without bringing AOM forward.
final class FolderRulesFloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        title = "Folder Rules"
    }

    override var canBecomeKey: Bool { true }
}

struct FolderRulesApprovalCard: View {
    @ObservedObject var engine: FolderRulesEngine
    let approval: FolderRuleApproval
    let remaining: Int
    let close: () -> Void
    @State private var alwaysAllow = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                AOMModuleBadge(.folderRules, size: AOMIcon.listBadge)
                Text("Folder Rules").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                Spacer(minLength: AOMSpace.x2)
                AOMIconButton("xmark", label: "Ask Later", action: close)
            }
            Text(approval.question)
                .font(AOMFont.bodyEmphasis)
                .foregroundStyle(AOMColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't ask again for this rule", isOn: $alwaysAllow)
                .toggleStyle(.checkbox)
                .font(AOMFont.callout)
            HStack(spacing: AOMSpace.x2) {
                Button("Review…") {
                    FolderRulesModule.openPage()
                    close()
                }
                Spacer(minLength: AOMSpace.x2)
                Button("Skip") { engine.skip(approval.id) }
                    .help("Leaves these items alone; the rule won't ask about them again")
                Button(approval.verb) { engine.approve(approval.id, alwaysAllow: alwaysAllow) }
                    .aomPrimaryButton()
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: 360)
        .aomFloatingSurface(.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder Rules: \(approval.question)")
    }

    private var detail: String {
        let names = approval.requests.map(\.info.name)
        var text = "“\(approval.ruleName)” in \(approval.folderName)"
        if names.count > 1 {
            text += ": " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        }
        if remaining > 0 { text += ". \(remaining) more \(remaining == 1 ? "question waits" : "questions wait") on the page." }
        return text
    }
}
