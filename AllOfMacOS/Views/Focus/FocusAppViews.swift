import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Add App" pull-down: running apps first (most people add an app they
/// have open), then Choose… for anything in Applications. Finder and AOM
/// are never offered; apps already listed are left out.
struct FocusAddAppMenu: View {
    var title = "Add App"
    let excluded: Set<String>
    let add: (FocusAppRef) -> Void

    var body: some View {
        Menu {
            let choices = FocusAppCatalog.runningChoices().filter { !excluded.contains($0.bundleID) }
            if choices.isEmpty {
                Text("No other open apps")
            } else {
                Section("Open Apps") {
                    ForEach(choices) { app in
                        Button {
                            add(app)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: FocusAppIcon.menuImage(for: app.bundleID)) }
                        }
                    }
                }
            }
            Divider()
            Button("Choose…") { choose() }
        } label: {
            Label(title, systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Adds an open app, or one you choose in Applications")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let ref = FocusAppCatalog.ref(forAppAt: url), !FocusIdlePolicy.isProtected(ref.bundleID),
                  !excluded.contains(ref.bundleID) else { continue }
            add(ref)
        }
    }
}

/// App icons at text size, cached by bundle identifier.
@MainActor
enum FocusAppIcon {
    private static var menuImages: [String: NSImage] = [:]

    static func menuImage(for bundleID: String) -> NSImage {
        if let cached = menuImages[bundleID] { return cached }
        let source = FocusAppCatalog.icon(for: bundleID)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        menuImages[bundleID] = image
        return image
    }
}

/// An app's icon in a row (20 pt, decorative).
struct FocusAppIconView: View {
    let bundleID: String
    var size: CGFloat = AOMIcon.row

    var body: some View {
        Image(nsImage: FocusAppCatalog.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A removable app chip (icon, name, ×) for the distracting-apps list.
struct FocusAppChip: View {
    let app: FocusAppRef
    let remove: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    init(app: FocusAppRef, remove: @escaping () -> Void) {
        self.app = app
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: AOMSpace.x1) {
            FocusAppIconView(bundleID: app.bundleID, size: 16)
            Text(app.name)
                .font(AOMFont.token)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(app.name)")
            .accessibilityLabel("Remove \(app.name)")
        }
        .padding(.leading, AOMSpace.x1 + AOMSpace.x0_5)
        .padding(.trailing, AOMSpace.x1)
        .frame(minHeight: AOMSize.tokenHeight)
        .background(AOMColor.sunken, in: Capsule())
        .overlay { if contrast == .increased { Capsule().strokeBorder(AOMColor.strongLine, lineWidth: 1) } }
        .contextMenu {
            Button("Remove", action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
        .accessibilityAction(named: "Remove", remove)
    }
}

/// Lays sections side by side when the page is wide enough (design-3.4.0
/// b.2: settings-style pages put two related sections side by side), and
/// stacks them otherwise.
struct FocusColumns<Leading: View, Trailing: View>: View {
    var threshold: CGFloat = 900
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var width: CGFloat = 0

    init(threshold: CGFloat = 900, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.threshold = threshold
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            if width >= threshold {
                HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                    leading.frame(maxWidth: .infinity, alignment: .topLeading)
                    trailing.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                    leading
                    trailing
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
            }
        }
    }
}
