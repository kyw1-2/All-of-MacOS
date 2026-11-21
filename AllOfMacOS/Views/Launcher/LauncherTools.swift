import AppKit
import SwiftUI

/// 7.2: the System Tools the launcher opens in place (Raycast's Brew,
/// Network and File Search extensions), each a screen of its own rows.
enum LauncherTool: Hashable {
    case brew(HomebrewModel.Tab, String)
    case files(String)
    case pasteStack
    case rulePreview
    case vpn
    case network

    static let entries: [Self] = [.brew(.outdated, ""), .brew(.installed, ""), .brew(.services, ""),
                                  .brew(.search, ""), .vpn, .network, .files(""), .rulePreview, .pasteStack]
    /// What the field says: the search itself, or a filter of the rows.
    var placeholder: String {
        switch self {
        case .brew(.search, _): return "Formula or app name, such as ripgrep or firefox…"
        case .brew: return "Filter packages…"
        case .files: return "File or folder name…"
        case .pasteStack: return "Filter the queue…"
        case .rulePreview: return "Search folder rules…"
        case .vpn: return "Filter connections…"
        case .network: return "Filter addresses…"
        }
    }

    /// The field is the search itself (brew search, Spotlight), not a filter.
    var takesQuery: Bool {
        switch self {
        case .brew(.search, _), .files: return true
        default: return false
        }
    }

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

/// 7.2: the launcher's own keys, read before AppKit's field editor acts on
/// them — Tab (Quick AI, the next filter), Esc on a screen, ⌘1…⌘9, ⌥↩,
/// ⌘- and ⌘=, and the key a new hotkey is recorded from — plus ⌘ held,
/// for the ⌘1…⌘9 hints. A key typed while an input method composes
/// (Korean, Japanese) always goes to the field; other windows and sheets
/// keep their keys.
struct PaletteNavigationKeys: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    var flagsChanged: ((NSEvent.ModifierFlags) -> Void)? = nil

    final class Anchor: NSView {
        var monitor: Any?
        var handle: ((NSEvent) -> Bool)?
        var flagsChanged: ((NSEvent.ModifierFlags) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                if event.type == .flagsChanged {
                    self.flagsChanged?(event.modifierFlags)
                    return event
                }
                guard (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      self.handle?(event) == true else { return event }
                return nil
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.handle = handle
        view.flagsChanged = flagsChanged
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.handle = nil
        view.flagsChanged = nil
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
}
