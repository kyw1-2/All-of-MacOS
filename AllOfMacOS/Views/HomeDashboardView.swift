import AppKit
import SwiftUI

/// Landing page: one look at every module, the next useful action for each,
/// and anything that needs attention (permissions, paused automation).
/// Modelled on the "overview first, details on demand" layout of System
/// Settings, Shortcuts and CleanShot's history: cards summarize, and every
/// card is a doorway into its page.
struct HomeDashboardView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var stats = GestureStatistics.shared
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []

    private var triggers: [Trigger] { appState.currentPreset.triggers }
    private var enabledTriggers: [Trigger] { triggers.filter(\.isEnabled) }

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 1060 ? 3 : 2
            ScrollView {
                VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                    hero
                    if needsAttention { attentionBanner }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMDesign.sectionSpacing, alignment: .top),
                                             count: columns),
                              alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                        gesturesCard
                        clipboardCard
                        captureCard
                        tilingCard
                        insightsCard
                        permissionsCard
                    }
                }
                .padding(AOMDesign.pagePadding)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .suppressScrollerReservation()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Cheap preflight checks, refreshed while the page is visible so a
            // grant made in System Settings shows up without reopening.
            while !Task.isCancelled {
                permissions = AOMPermission.required.map { ($0, $0.status) }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: - Hero

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var summary: String {
        var parts = ["\(enabledTriggers.count) of \(triggers.count) gestures on"]
        parts.append("\(clipboard.entries.count) clips")
        parts.append("\(history.entries.count) captures")
        return parts.joined(separator: " · ")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(summary)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button { appState.toggleGlobalEnabled() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(appState.globalEnabled ? Color.green : Color.orange).frame(width: 9, height: 9)
                        Text(appState.globalEnabled ? "Automation On" : "Automation Paused")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(appState.globalEnabled ? "Pause every gesture and shortcut" : "Resume gestures and shortcuts")
            }
            HomeQuickActionBar()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [Color.accentColor, Color.purple.opacity(0.85), Color.indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Attention

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }
    private var needsAttention: Bool { !missingPermissions.isEmpty || !appState.globalEnabled }

    private var attentionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(missingPermissions.isEmpty ? "Automation is paused" : "\(missingPermissions.count) permission\(missingPermissions.count == 1 ? "" : "s") need setup")
                    .font(.headline)
                Text(missingPermissions.isEmpty ? "Gestures, shortcuts and snapping are not listening."
                     : missingPermissions.map(\.title).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let first = missingPermissions.first {
                Button("Open System Settings") { _ = first.openSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Resume") { appState.toggleGlobalEnabled() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
    }

    // MARK: - Cards

    private var gesturesCard: some View {
        HomeCard(tab: .gestures, subtitle: "\(enabledTriggers.count) active · \(triggers.count) total") {
            if triggers.isEmpty {
                HomeEmptyLine(text: "No gestures yet", action: "Create One") {
                    appState.selectedMainTab = .gestures
                    appState.showingAddTrigger = true
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(triggers.sorted { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }.prefix(5).enumerated()), id: \.element.id) { index, trigger in
                        if index > 0 { Divider().padding(.leading, 34) }
                        HStack(spacing: 10) {
                            AOMIconTile(systemImage: trigger.input.category.iconName,
                                        tint: GestureVisual.tint(trigger.input.category), size: 24)
                                .opacity(trigger.isEnabled ? 1 : 0.4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(trigger.displayName).font(.callout.weight(.medium)).lineLimit(1)
                                Text(trigger.actions.first?.displayName ?? "No actions")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                                                                      set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectedTrigger = trigger
                            appState.gestureEditorTriggerID = trigger.id
                            appState.selectedMainTab = .gestures
                        }
                    }
                }
            }
        }
    }

    private var clipboardCard: some View {
        HomeCard(tab: .clipboard, subtitle: clipboard.paused ? "Recording paused" : "\(clipboard.entries.count) items · \(clipboard.boards.count) pinboards",
                 primary: ("Open Shelf", "rectangle.bottomthird.inset.filled", { ClipboardPanelController.shared.show() })) {
            if clipboard.entries.isEmpty {
                HomeEmptyLine(text: "Copy anything to start your history", action: nil, perform: {})
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(clipboard.entries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 34) }
                        HStack(spacing: 10) {
                            Image(systemName: entry.kind.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(entry.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(AOMRelativeTime.string(entry.lastCopiedAt)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .help("Copy “\(entry.title.prefix(60))”")
                        .onTapGesture(count: 2) { _ = try? clipboard.write(entryIDs: [entry.id]) }
                    }
                }
            }
        }
    }

    private var captureCard: some View {
        HomeCard(tab: .capture, subtitle: history.entries.first.map { "Last capture \(AOMRelativeTime.string($0.capturedAt))" } ?? "No captures yet",
                 primary: ("Capture Area", "viewfinder", { CaptureCoordinator.shared.captureArea() })) {
            if history.entries.isEmpty {
                HomeEmptyLine(text: "Screenshots and recordings appear here", action: "Capture Text") {
                    CaptureCoordinator.shared.captureText()
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(history.entries.prefix(6)) { entry in
                        ZStack {
                            Color(nsColor: .underPageBackgroundColor)
                            Image(nsImage: entry.thumbnail).resizable().interpolation(.medium).scaledToFit().padding(3)
                        }
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .overlay(alignment: .bottomTrailing) {
                            if entry.kind == .videoRecording {
                                Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }
                        .help("Double-click to annotate")
                    }
                }
            }
        }
    }

    private var tilingCard: some View {
        let zones = appState.effectiveSnapZones.filter(\.isEnabled).count
        return HomeCard(tab: .snapping, subtitle: appState.currentPreset.snappingEnabled ? "Drag to snap · \(zones) zones" : "Drag to snap is off") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([CustomSnapZone.Layout.leftHalf, .rightHalf, .maximize, .center, .leftThird, .rightThird], id: \.self) { layout in
                        Button { appState.selectedMainTab = .snapping } label: {
                            Image(systemName: layout.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(layout.rawValue)
                    }
                }
                Toggle("Drag windows to screen edges to tile them", isOn: Binding(
                    get: { appState.currentPreset.snappingEnabled }, set: { appState.setSnappingEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.callout)
            }
        }
    }

    private var insightsCard: some View {
        HomeCard(tab: .insights, subtitle: "\(stats.totalGestures.formatted()) detected · \(stats.totalFired.formatted()) fired") {
            if stats.sortedEntries.isEmpty {
                HomeEmptyLine(text: "Use a gesture to see your most used", action: nil, perform: {})
            } else {
                let maxCount = max(1, stats.sortedEntries.first?.totalCount ?? 1)
                VStack(spacing: 9) {
                    ForEach(stats.sortedEntries.prefix(4)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.gesture).font(.callout).lineLimit(1)
                                Spacer()
                                Text("\(entry.totalCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Color.green.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(entry.totalCount) / CGFloat(maxCount)))
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
    }

    private var permissionsCard: some View {
        HomeCard(title: "Permissions", systemImage: "checkmark.shield.fill", tint: missingPermissions.isEmpty ? .green : .orange,
                 subtitle: missingPermissions.isEmpty ? "Everything AOM needs is allowed" : "Some features are limited",
                 destination: nil) {
            VStack(spacing: 0) {
                ForEach(Array(permissions.enumerated()), id: \.element.0.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 34) }
                    HStack(spacing: 10) {
                        Image(systemName: item.0.icon).frame(width: 24).foregroundStyle(.secondary)
                        Text(item.0.title).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        if item.1 == .granted {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Allowed")
                        } else {
                            Button("Allow…") { _ = item.0.openSettings() }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 6)
                }
                if permissions.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8) }
            }
        }
    }
}

// MARK: - Building blocks

/// Shared colours for trigger categories (gallery tiles, rows, Home).
enum GestureVisual {
    static func tint(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return .blue
        }
    }
}

private struct HomeCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let subtitle: String
    let destination: AOMMainTab?
    var primary: (String, String, () -> Void)?
    @ViewBuilder var content: Content
    @EnvironmentObject var appState: AppState

    init(tab: AOMMainTab, subtitle: String, primary: (String, String, () -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: tab.title, systemImage: tab.iconName, tint: tab.accentColor, subtitle: subtitle,
                  destination: tab, primary: primary, content: content)
    }

    init(title: String, systemImage: String, tint: Color, subtitle: String, destination: AOMMainTab?,
         primary: (String, String, () -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.subtitle = subtitle
        self.destination = destination
        self.primary = primary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AOMIconTile(systemImage: systemImage, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let primary {
                    Button(action: primary.2) { Label(primary.0, systemImage: primary.1) }
                        .controlSize(.small)
                }
                if let destination {
                    Button { appState.selectedMainTab = destination } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(.quaternary.opacity(0.6), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(title)")
                    .accessibilityLabel("Open \(title)")
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .aomSurface(radius: 14, padding: nil)
    }
}

private struct HomeEmptyLine: View {
    let text: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action, action: perform).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// The five things people start most often, one click away. On macOS 26
/// and later the bar uses Liquid Glass, as Apple recommends for floating
/// controls over content.
private struct HomeQuickActionBar: View {
    private struct Item: Identifiable {
        let id: String, title: String, symbol: String, run: () -> Void
    }
    private var items: [Item] {
        [Item(id: "aio", title: "All-In-One", symbol: "rectangle.dashed.badge.record") { CaptureCoordinator.shared.captureAllInOne() },
         Item(id: "area", title: "Capture Area", symbol: "viewfinder") { CaptureCoordinator.shared.captureArea() },
         Item(id: "text", title: "Capture Text", symbol: "text.viewfinder") { CaptureCoordinator.shared.captureText() },
         Item(id: "record", title: "Record", symbol: "record.circle") { ScreenRecordingService.shared.promptAndStartRecording() },
         Item(id: "shelf", title: "Clipboard", symbol: "rectangle.bottomthird.inset.filled") { ClipboardPanelController.shared.show() }]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                Button(action: item.run) {
                    Label(item.title, systemImage: item.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(HomeGlassCapsule())
                .help(item.title)
            }
        }
    }
}

private struct HomeGlassCapsule: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(.white.opacity(hovering ? 0.22 : 0.08)).interactive(), in: Capsule())
            } else {
                content
                    .background(.white.opacity(hovering ? 0.28 : 0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            }
        }
        .onHover { hovering = $0 }
    }
}
