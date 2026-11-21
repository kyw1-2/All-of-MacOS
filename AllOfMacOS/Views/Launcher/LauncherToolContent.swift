import SwiftUI

enum LauncherTool: Hashable {
    case brew(HomebrewModel.Tab, String)
    case files(String)
    case pasteStack
    case rulePreview
    case vpn
    case network

    static let entries: [Self] = [.brew(.outdated, ""), .brew(.installed, ""), .brew(.services, ""),
                                  .brew(.search, ""), .vpn, .network, .files(""), .rulePreview, .pasteStack]
    static func packageQuery(_ text: String) -> String {
        text.lowercased().hasPrefix("search ") ? String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) : text
    }
    var id: String {
        switch self {
        case .brew(.outdated, _): return "go.homebrew"
        case .brew(let tab, _): return "brew." + tab.rawValue
        case .files: return "files.lookup"
        case .pasteStack: return "clipboard.stack.inspect"
        case .rulePreview: return "rules.preview"
        case .vpn: return "network.vpn"
        case .network: return "network.info"
        }
    }
    var title: String {
        switch self {
        case .brew(.outdated, _): return "Homebrew Updates"
        case .brew(.installed, _): return "Installed Homebrew Packages"
        case .brew(.services, _): return "Homebrew Services"
        case .brew(.search, _): return "Search Homebrew"
        case .files: return "Search Files"
        case .pasteStack: return "Paste Stack"
        case .rulePreview: return "Preview Folder Rules"
        case .vpn: return "VPN and Tailscale"
        case .network: return "Network Info"
        }
    }
    var aliases: [String] {
        switch self {
        case .brew(.outdated, _): return ["brew", "homebrew", "홈브루", "brew outdated", "brew upgrades", "홈브루 업데이트"]
        case .brew(.installed, _): return ["brew list", "brew installed", "홈브루 설치 목록"]
        case .brew(.services, _): return ["brew services", "홈브루 서비스"]
        case .brew(.search, _): return ["brew search", "홈브루 검색"]
        case .files: return ["files", "spotlight", "파일 검색"]
        case .pasteStack: return ["paste stack", "붙여넣기 대기열", "클립보드 스택"]
        case .rulePreview: return ["rule preview", "폴더 규칙", "규칙 미리보기"]
        case .vpn: return ["vpn", "tailscale", "테일스케일"]
        case .network: return ["ip", "dns", "wifi", "wi-fi", "네트워크", "아이피"]
        }
    }
    var subtitle: String {
        switch self {
        case .brew(.outdated, _): return "Check installed and available versions · 홈브루 업데이트"
        case .brew(.installed, _): return "Filter installed formulae and casks · 설치 목록"
        case .brew(.services, _): return "Inspect and control background services · 서비스"
        case .brew(.search, _): return "Find formulae and casks by name · 패키지 검색"
        case .files: return "Find files using Spotlight · 파일 검색"
        case .pasteStack: return "See the queued items in paste order · 대기열"
        case .rulePreview: return "Inspect matching files and planned actions · 규칙 미리보기"
        case .vpn: return "Connection status, profiles and exit node · 연결 상태"
        case .network: return "Local and public IP, Wi-Fi and DNS · 네트워크 정보"
        }
    }
    var symbol: String {
        switch self {
        case .brew: return "mug"
        case .files: return "doc.text.magnifyingglass"
        case .pasteStack: return "square.stack"
        case .rulePreview: return "folder.badge.gearshape"
        case .vpn: return "lock.shield"
        case .network: return "network"
        }
    }
}

struct LauncherToolContent: View {
    let tool: LauncherTool
    let back: () -> Void
    @StateObject private var toasts = AOMToastModel()

    var body: some View {
        switch tool {
        case .brew: HomebrewSheet(model: .shared, back: back)
        case .files(let query): LauncherFileSearch(initial: query, back: back)
        case .pasteStack: LauncherStackContents(back: back)
        case .rulePreview: LauncherRulePreview(back: back)
        case .vpn: VPNSheet(model: .shared, back: back)
        case .network: NetworkInfoSheet(toasts: toasts, back: back)
        }
    }
}

/// Handle an unmodified Tab before AppKit's field editor moves focus. Keep
/// IME composition, keyboard navigation in other windows and Shift-Tab native.
struct PaletteTabKey: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    final class Anchor: NSView {
        var monitor: Any?
        var handle: ((NSEvent) -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      event.keyCode == 48, event.modifierFlags.intersection([.shift, .command, .control, .option, .function]).isEmpty,
                      let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText(),
                      self.handle?(event) == true else { return event }
                return nil
            }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.handle = nil
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
}
