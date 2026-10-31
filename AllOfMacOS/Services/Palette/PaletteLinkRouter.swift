import AppKit
import SwiftUI

/// A link rule: links whose host (or URL) matches open in one browser.
struct PaletteLinkRule: Codable, Equatable, Identifiable {
    enum Match: String, Codable, CaseIterable, Identifiable {
        case hostContains, hostIs, urlContains, urlStartsWith
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hostContains: return "Host contains"
            case .hostIs: return "Host is"
            case .urlContains: return "URL contains"
            case .urlStartsWith: return "URL starts with"
            }
        }
    }

    var id = UUID()
    var match: Match = .hostContains
    var pattern: String = ""
    /// The app the link opens in.
    var browserBundleID: String = "com.apple.Safari"
    var isEnabled = true

    func matches(_ url: URL) -> Bool {
        let needle = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard isEnabled, !needle.isEmpty else { return false }
        let host = url.host?.lowercased() ?? ""
        let whole = url.absoluteString.lowercased()
        switch match {
        case .hostContains: return host.contains(needle)
        case .hostIs: return host == needle || host == "www." + needle
        case .urlContains: return whole.contains(needle)
        case .urlStartsWith: return whole.hasPrefix(needle)
        }
    }
}

/// Settings › Links (design-340 b.17). Stored as JSON under
/// `AOMPaletteLinkRouter`.
struct PaletteLinkRouterSettings: Codable, Equatable {
    /// Route links (only does anything once AOM is the default browser).
    var isEnabled = false
    var removesTracking = true
    /// Exact names, or a prefix with * ("utm_*").
    var trackingParameters = ["utm_*", "fbclid", "gclid", "si", "igshid", "mc_cid", "mc_eid", "msclkid", "yclid"]
    /// Where links no rule matches go; never AOM itself.
    var fallbackBrowserBundleID = "com.apple.Safari"
    /// Figma, Zoom and Notion links open their apps when installed.
    var opensAppLinks = true
    var rules: [PaletteLinkRule] = [
        PaletteLinkRule(match: .hostContains, pattern: "uos.ac.kr", browserBundleID: "com.apple.Safari"),
        // The user's examples (steer f9dff59d): GitHub and local servers in Chrome.
        PaletteLinkRule(match: .hostContains, pattern: "github.com", browserBundleID: "com.google.Chrome"),
        PaletteLinkRule(match: .hostIs, pattern: "localhost", browserBundleID: "com.google.Chrome"),
    ]

    static let storageKey = "AOMPaletteLinkRouter"

    static func load(from defaults: UserDefaults = .standard) -> PaletteLinkRouterSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(PaletteLinkRouterSettings.self, from: data) else { return .init() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum PaletteLinkCleaner {
    /// `url` without tracking parameters; the order of the others, the
    /// fragment and their encoding stay as they were.
    static func clean(_ url: URL, parameters: [String]) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return url }
        let kept = items.filter { item in !parameters.contains { matches(item.name, pattern: $0) } }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// "utm_*" matches utm_source; other names match exactly, without case.
    static func matches(_ name: String, pattern: String) -> Bool {
        let name = name.lowercased()
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return false }
        if pattern.hasSuffix("*") { return name.hasPrefix(String(pattern.dropLast())) }
        return name == pattern
    }
}

enum PaletteLinkRouting {
    struct AppLink: Equatable {
        let bundleID: String
        let url: URL
    }

    /// The desktop app's own link for a Figma, Zoom or Notion page, or nil.
    static func appLink(for url: URL) -> AppLink? {
        guard let host = url.host?.lowercased(), url.scheme?.lowercased().hasPrefix("http") == true else { return nil }
        let path = url.path
        if host == "figma.com" || host.hasSuffix(".figma.com") {
            guard path.hasPrefix("/file/") || path.hasPrefix("/design/") || path.hasPrefix("/board/") || path.hasPrefix("/proto/"),
                  let source = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            // Work on the encoded path: a file name in Korean stays escaped.
            let segments = source.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard let kind = segments.first, !kind.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "figma"
            components.host = String(kind)
            components.percentEncodedPath = "/" + segments.dropFirst().joined(separator: "/")
            components.percentEncodedQuery = source.percentEncodedQuery
            return components.url.map { AppLink(bundleID: "com.figma.Desktop", url: $0) }
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "j" || parts[0] == "my", let meeting = parts.last,
                  meeting.allSatisfy(\.isNumber) else { return nil }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = "zoom.us"
            components.path = "/join"
            var query = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(meeting))]
            if let password = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
                query.append(URLQueryItem(name: "pwd", value: password))
            }
            components.queryItems = query
            return components.url.map { AppLink(bundleID: "us.zoom.xos", url: $0) }
        }
        if host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.site" || host.hasSuffix(".notion.site") {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "notion"
            return components.url.map { AppLink(bundleID: "notion.id", url: $0) }
        }
        return nil
    }

    /// Where `url` goes: the first matching rule's browser, else the
    /// fallback; never `ownBundleID` (that would route the link back to AOM).
    static func destination(for url: URL, settings: PaletteLinkRouterSettings, ownBundleID: String?) -> String {
        if let rule = settings.rules.first(where: { $0.matches(url) }), rule.browserBundleID != ownBundleID {
            return rule.browserBundleID
        }
        return settings.fallbackBrowserBundleID == ownBundleID ? "com.apple.Safari" : settings.fallbackBrowserBundleID
    }

    struct Browser: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let url: URL
    }

    /// Apps that open web links, AOM itself left out.
    @MainActor
    static func installedBrowsers() -> [Browser] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != own,
                  !id.hasPrefix("com.kyw.allofmacos"), seen.insert(id).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return Browser(bundleID: id, name: name, url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Opens links the user clicks elsewhere once AOM is the default browser:
/// tracking parameters removed, app links to their apps, then the rules and
/// the fallback browser; ⌥ held shows a browser menu at the pointer. Only
/// the rule that matched is logged.
@MainActor
final class PaletteLinkRouter {
    static let shared = PaletteLinkRouter()

    var settings: PaletteLinkRouterSettings { PaletteLinkRouterSettings.load() }

    /// Whether macOS sends web links to AOM.
    var isDefaultBrowser: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// The browser that opens web links now, when it is not AOM.
    var currentBrowserBundleID: String? {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let id = Bundle(url: handler)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !id.hasPrefix("com.kyw.allofmacos") else { return nil }
        return id
    }

    /// Asks macOS to make AOM the default browser; macOS shows its own
    /// confirmation first. AOM must declare the http and https URL schemes
    /// in Info.plist for this to succeed.
    func makeDefaultBrowser(completion: @escaping (Error?) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else { DispatchQueue.main.async { completion(error) }; return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { error in
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// AppDelegate hands every http and https URL it is asked to open here.
    func route(_ url: URL, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let settings = self.settings
        let cleaned = settings.removesTracking ? PaletteLinkCleaner.clean(url, parameters: settings.trackingParameters) : url
        if modifiers.contains(.option) {
            showPicker(for: cleaned)
            return
        }
        if settings.opensAppLinks, let appLink = PaletteLinkRouting.appLink(for: cleaned),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: appLink.bundleID) != nil,
           NSWorkspace.shared.open(appLink.url) {
            return
        }
        let target = settings.isEnabled
            ? PaletteLinkRouting.destination(for: cleaned, settings: settings, ownBundleID: Bundle.main.bundleIdentifier)
            : (settings.fallbackBrowserBundleID == Bundle.main.bundleIdentifier ? "com.apple.Safari" : settings.fallbackBrowserBundleID)
        if let rule = settings.rules.first(where: { $0.matches(cleaned) }), settings.isEnabled {
            NSLog("[AOM] Link rule matched: %@ %@", rule.match.title, rule.pattern)
        }
        open(cleaned, in: target)
    }

    private func open(_ url: URL, in bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The ⌥ menu: every installed browser with its icon, at the pointer.
    func showPicker(for url: URL) {
        let menu = NSMenu(title: "Open With")
        menu.addItem(withTitle: url.host ?? url.absoluteString, action: nil, keyEquivalent: "").isEnabled = false
        for browser in PaletteLinkRouting.installedBrowsers() {
            let item = PaletteLinkPickerItem(title: browser.name, url: url, appURL: browser.url)
            item.image = NSWorkspace.shared.icon(forFile: browser.url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class PaletteLinkPickerItem: NSMenuItem {
    let link: URL
    let appURL: URL

    init(title: String, url: URL, appURL: URL) {
        self.link = url
        self.appURL = appURL
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func choose() {
        NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Settings › Links: the default-browser step, the rules, tracking
/// parameters, app links and the fallback browser.
struct PaletteLinkRouterSettingsView: View {
    @State private var settings = PaletteLinkRouterSettings.load()
    @State private var browsers: [PaletteLinkRouting.Browser] = []
    @State private var isDefault = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            AOMSection("Default browser",
                       footer: "macOS sends a clicked link to one app. When that is All of MacOS, it removes tracking parameters and passes the link on by your rules. macOS asks you to confirm the change.") {
                AOMSettingRow(isDefault ? "All of MacOS opens your links" : "Links open in your browser directly",
                              detail: isDefault ? "Rules below decide the browser." : "Make All of MacOS the default browser to use rules.",
                              symbol: isDefault ? "checkmark.seal" : "safari") {
                    if !isDefault {
                        Button("Make Default Browser…") {
                            // Links no rule matches keep going to the browser
                            // used until now, unless another one was chosen.
                            if let previous = PaletteLinkRouter.shared.currentBrowserBundleID,
                               settings.fallbackBrowserBundleID == PaletteLinkRouterSettings().fallbackBrowserBundleID {
                                settings.fallbackBrowserBundleID = previous
                            }
                            PaletteLinkRouter.shared.makeDefaultBrowser { error in
                                isDefault = PaletteLinkRouter.shared.isDefaultBrowser
                                if let error { message = "Couldn't change the default browser because \(error.localizedDescription)" }
                            }
                        }
                    }
                }
            }
            if let message {
                AOMNotice(.error, message)
            }
            AOMSection("Rules", footer: "The first rule that matches wins. Hold ⌥ while clicking a link to choose a browser.") {
                AOMToggleRow("Route links by these rules", symbol: "arrow.triangle.branch", isOn: $settings.isEnabled)
                ForEach($settings.rules) { $rule in
                    AOMConditionRow(canRemove: true, addLabel: "Add Rule", removeLabel: "Remove Rule",
                                    add: { settings.rules.append(PaletteLinkRule()) },
                                    remove: { settings.rules.removeAll { $0.id == rule.id } }) {
                        Picker("Match", selection: $rule.match) {
                            ForEach(PaletteLinkRule.Match.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } value: {
                        HStack(spacing: AOMSpace.x2) {
                            TextField("uos.ac.kr", text: $rule.pattern)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Pattern")
                            Text("open in").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                            browserPicker($rule.browserBundleID)
                        }
                    }
                }
                if settings.rules.isEmpty {
                    AOMInlineEmpty(symbol: "arrow.triangle.branch", message: "No rules yet.", actionTitle: "Add Rule") {
                        settings.rules.append(PaletteLinkRule())
                    }
                }
                AOMSettingRow("Other links open in", symbol: "globe") { browserPicker($settings.fallbackBrowserBundleID) }
            }
            AOMSection("Clean links") {
                AOMToggleRow("Remove tracking parameters", detail: "utm_source, fbclid, gclid and the names below",
                             symbol: "wand.and.stars", isOn: $settings.removesTracking)
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    Text("Parameters")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                    AOMTokenField(tokens: $settings.trackingParameters, placeholder: "Add parameter",
                                  suggestions: ["utm_*", "fbclid", "gclid", "si", "igshid", "mc_cid", "mc_eid", "msclkid", "yclid", "ref_src"],
                                  normalize: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.lowercased() })
                        .disabled(!settings.removesTracking)
                        .accessibilityLabel("Tracking parameters")
                }
                .padding(.leading, AOMSpace.rowSymbolInset)
                .padding(.trailing, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
                AOMToggleRow("Open Figma, Zoom and Notion links in their apps", detail: "Only when the app is installed",
                             symbol: "app.badge", isOn: $settings.opensAppLinks)
            }
        }
        .onAppear {
            browsers = PaletteLinkRouting.installedBrowsers()
            isDefault = PaletteLinkRouter.shared.isDefaultBrowser
        }
        .onChange(of: settings) { _, value in value.save() }
    }

    private func browserPicker(_ selection: Binding<String>) -> some View {
        Picker("Browser", selection: selection) {
            ForEach(browsers) { browser in
                Label {
                    Text(browser.name)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: browser.url.path))
                }
                .tag(browser.bundleID)
            }
            if !browsers.contains(where: { $0.bundleID == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The settings above in a sheet, opened from ⌘K ("Link Rules…") until
/// Settings › Links hosts them.
struct PaletteLinkRouterSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.x3) {
                    Text("Link Rules").font(AOMFont.title)
                    PaletteLinkRouterSettingsView()
                }
                .padding(AOMSpace.x5)
            }
            AOMDivider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .aomPrimaryButton()
            }
            .padding(AOMSpace.x4)
        }
        .frame(width: 720, height: 600)
    }
}

/// The palette's launch hook (AOMProductivityModules.start, integrator):
/// the hold-⌘ shortcut sheet's monitors when its switch is on.
@MainActor
enum PaletteModule {
    static func start() {
        PaletteShortcutSheet.shared.start()
    }
}
