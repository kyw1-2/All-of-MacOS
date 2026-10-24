import AppKit
import Foundation

/// Favourite and recently used actions for the action picker. Backed by
/// UserDefaults (injectable so tests use a throwaway suite). Unknown raw values,
/// for example from a newer build, are dropped on read rather than crashing.
struct ActionPickerStore {
    static let favoritesKey = "AOMActionFavorites.v1"
    static let recentsKey = "AOMActionRecents.v1"
    static let maxRecents = 8
    static let maxFavorites = 24

    var defaults: UserDefaults = .standard

    private func read(_ key: String) -> [ActionType] {
        var seen = Set<ActionType>()
        return (defaults.stringArray(forKey: key) ?? []).compactMap(ActionType.init(rawValue:)).filter { seen.insert($0).inserted }
    }
    private func write(_ types: [ActionType], _ key: String) { defaults.set(types.map(\.rawValue), forKey: key) }

    var favorites: [ActionType] { read(Self.favoritesKey) }
    var recents: [ActionType] { read(Self.recentsKey) }

    func isFavorite(_ type: ActionType) -> Bool { favorites.contains(type) }

    /// Adds or removes a favourite; returns the new state.
    @discardableResult
    func toggleFavorite(_ type: ActionType) -> Bool {
        var list = favorites
        if let index = list.firstIndex(of: type) { list.remove(at: index); write(list, Self.favoritesKey); return false }
        list.append(type)
        write(Array(list.suffix(Self.maxFavorites)), Self.favoritesKey)
        return true
    }

    /// Moves `type` to the front of the recents list.
    func recordUse(_ type: ActionType) {
        var list = recents.filter { $0 != type }
        list.insert(type, at: 0)
        write(Array(list.prefix(Self.maxRecents)), Self.recentsKey)
    }

    func clearRecents() { defaults.removeObject(forKey: Self.recentsKey) }
}

/// Ranks actions for a search query. Every whitespace-separated word must appear
/// somewhere in the name, category, description or parameter hint; name matches
/// outrank description matches, and earlier matches outrank later ones.
enum ActionSearch {
    static func results(for query: String, in types: [ActionType] = ActionType.allCases) -> [ActionType] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return types }
        let scored: [(ActionType, Int)] = types.compactMap { type in
            let name = type.rawValue.lowercased()
            let rest = [type.category.rawValue, type.description, type.parameterHint].joined(separator: " ").lowercased()
            var score = 0
            for word in words {
                if name.hasPrefix(word) { score += 100 }
                else if name.split(separator: " ").contains(where: { $0.hasPrefix(word) }) { score += 80 }
                else if name.contains(word) { score += 60 }
                else if rest.contains(word) { score += 20 }
                else { return nil }
            }
            return (type, score)
        }
        // Stable for equal scores: keep catalog order.
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }
}

/// In-memory copy buffer for Copy / Paste action. Not the system clipboard, so
/// copying an action never pollutes clipboard history.
enum ActionClipboard {
    static var copied: TriggerAction?
    /// A paste always gets fresh ids so it can sit next to its source.
    static func pasteCopy() -> TriggerAction? { copied.map(ActionTree.duplicate) }
}

/// One-line summary under an action's name in the sequence list (new actions).
enum ActionSummary {
    static func detail(_ action: TriggerAction) -> String? {
        let p = action.parameters
        func short(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } }
        switch action.actionType {
        case .moveResizeWindow:
            let unit = (p.moveResizeUnit ?? "percent") == "percent" ? "%" : " px"
            let size = [p.moveResizeWidth, p.moveResizeHeight].compactMap { $0 }.map { String(Int($0)) + unit }.joined(separator: " × ")
            return "\(ActionParameterForm.anchorTitle(p.moveResizeAnchor ?? "topLeft"))\(size.isEmpty ? "" : " · " + size)"
        case .switchToDesktop: return "Desktop \(p.desktopNumber ?? 1)"
        case .customClick: return "button \((p.clickButton ?? 0) + 1) × \(p.clickCount ?? 1)"
        case .scrollCustom: return "\(p.scrollDirection ?? "down") \(abs(p.scrollAmount ?? 3)) \(p.scrollUnit ?? "lines")"
        case .moveMouseRelative: return "Δ \(Int(p.mouseDeltaX ?? 0)), \(Int(p.mouseDeltaY ?? 0))"
        case .pasteString, .copyTextToClipboard, .speakText: return p.text.map { "\($0.count) characters" }
        case .pressFunctionKey: return "F\(p.functionKeyNumber ?? 1)"
        case .modifierKeyDown, .modifierKeyUp: return p.modifierKey ?? "command"
        case .pressArrowKey: return "\(p.arrowDirection ?? "down") × \(p.keyRepeatCount ?? 1)"
        case .setVolume, .setBrightness: return "\(Int(p.levelPercent ?? 0)) %"
        case .playSoundFile, .openFileOrFolder, .revealInFinder: return short(p.filePath)
        case .showNotification: return short(p.notificationTitle)
        case .runAppleShortcut: return short(p.shortcutName)
        case .runJavaScript: return "\(p.scriptContent?.utf8.count ?? 0) bytes · timeout \(Int(p.scriptTimeoutSeconds ?? 30)) s"
        case .repeatLoop: return "\(p.loopCount ?? 2)× · \(p.children?.count ?? 0) steps"
        case .cycleActions: return "\(p.children?.count ?? 0) steps"
        case .toggleOnOff: return "ON \(p.children?.count ?? 0) / OFF \(p.elseChildren?.count ?? 0)"
        case .increaseVariable, .decreaseVariable: return "\(p.variableName ?? "") by \(ControlFlowActions.format(p.variableStep ?? 1))"
        case .askForInput: return "→ \(p.variableName ?? "")"
        case .debounce: return "\(p.waitMs ?? 500) ms"
        case .enableTrigger, .disableTrigger: return short(p.triggerSelector)
        case .waitFor: return "\(p.waitCondition ?? "appRunning") \(short(p.waitTarget) ?? "")"
        case .disableTriggersForSeconds: return "\(ControlFlowActions.format(p.pauseSeconds ?? 5)) s"
        case .startMovingWindow, .toggleMovingWindow, .startResizingWindow, .toggleResizingWindow:
            return "timeout \(Int(p.windowDragTimeoutSeconds ?? 60)) s"
        case .zoomWindow, .closeWindow, .toggleFullscreenWindow:
            return (p.windowTarget ?? "focused") == "underCursor" ? "window under pointer" : nil
        case .emptyTrash, .logOut: return p.requiresConfirmation == false ? "no confirmation" : "asks first"
        case .sendKeyStroke:
            guard let keyCode = p.shortcutKeyCode else { return "no shortcut recorded" }
            return KeyboardShortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: p.shortcutModifiers ?? 0)).displayString
        case .setSoundOutput: return short(p.audioOutputName) ?? "no device chosen"
        case .activateApplication, .launchApplication, .quitApplication, .forceQuitApplication,
             .hideApplication, .toggleApplication:
            return short(p.applicationName)
        case .openURL: return short(p.url)
        case .wait: return "\(p.waitMs ?? 250) ms"
        default: return nil
        }
    }

    /// One phrase for a list row: the first enabled action with its key
    /// value, and how many follow. Type Text never shows its text or length.
    static func summary(_ actions: [TriggerAction]) -> String {
        let enabled = actions.filter(\.isEnabled)
        guard let first = enabled.first else { return actions.isEmpty ? "No actions" : "All actions off" }
        var phrase = first.displayName
        if first.actionType != .typeText, let value = detail(first), !value.isEmpty { phrase += " · \(value)" }
        if enabled.count > 1 { phrase += "  +\(enabled.count - 1)" }
        return phrase
    }
}
