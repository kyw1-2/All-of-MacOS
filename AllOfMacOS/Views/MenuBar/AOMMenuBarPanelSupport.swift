import AppKit
import CoreAudio

// 7.24 (menu bar spec 2026-11-28 §2.3): what the panel's search, recent
// copies and mute button do.

/// The panel's search: AOM's commands, the menu bar icons AOM hides, and
/// the clipboard — best matches first, eight at most.
@MainActor
enum AOMMenuBarPanelSearch {
    static let limit = 8

    /// Pure: how well `title` matches `query` (nil: not at all). Every word
    /// must be in the title; a title that starts with the query ranks first.
    nonisolated static func score(_ title: String, query: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let lower = title.lowercased()
        guard !words.isEmpty, words.allSatisfy({ lower.contains($0) }) else { return nil }
        if lower.hasPrefix(query.lowercased().trimmingCharacters(in: .whitespaces)) { return 0 }
        if lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(words[0]) }) { return 1 }
        return 2
    }

    static func results(for query: String, close: @escaping () -> Void) -> [AOMMenuBarCraftPanel.SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var scored: [(Int, AOMMenuBarCraftPanel.SearchResult)] = []
        func later(_ work: @escaping @MainActor () -> Void) -> () -> Void {
            { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { MainActor.assumeIsolated { work() } } }
        }
        var seen = Set<String>()
        let features = AOMFeatureMenus.capture() + AOMFeatureMenus.clipboard() + AOMFeatureMenus.keepAwake()
        for command in features where seen.insert(command.title).inserted {
            guard let s = score(command.title, query: trimmed) else { continue }
            scored.append((s, .init(id: "f." + command.id, title: command.title, subtitle: "Command", symbol: command.symbol,
                                    run: later(command.run))))
        }
        for command in AOMMenuCommandCatalog.all() where seen.insert(command.title).inserted {
            guard let s = score(command.title, query: trimmed) else { continue }
            scored.append((s, .init(id: "c." + command.id, title: command.title, subtitle: command.category, symbol: command.symbol,
                                    run: later(command.run))))
        }
        // Ice: a hidden icon comes back into the bar and its menu opens.
        for entry in MenuBarLayoutModel.shared.items where entry.section != .shown {
            let name = entry.item.displayName
            guard let s = score(name, query: trimmed) else { continue }
            let item = entry.item, section = entry.section
            scored.append((s + 1, .init(id: "m." + entry.id, title: name, subtitle: "Hidden menu bar icon · opens its menu",
                                        symbol: "menubar.arrow.up.rectangle",
                                        run: later { MenuBarStripController.shared.openItem(item, section: section) })))
        }
        for entry in ClipboardStore.shared.filtered(query: trimmed).prefix(4) where !ClipboardSecretDisplay.conceals(entry) {
            let id = entry.id
            scored.append((3, .init(id: "p." + id.uuidString, title: entry.title.replacingOccurrences(of: "\n", with: " "),
                                    subtitle: "Copied \(AOMMenuBarPanel.ago(entry.lastCopiedAt)) ago · pastes it",
                                    symbol: AOMMenuBarPanel.symbol(entry.kind),
                                    run: { close(); AOMMenuBarPanelClips.paste(id, copyOnly: false) })))
        }
        return scored.sorted { $0.0 < $1.0 }.prefix(limit).map(\.1)
    }
}

/// Puts a copy back on the clipboard and pastes it into the app that was in
/// front when the panel opened. 7.24.1 (agy §6.1-2): the same delivery as the
/// shelf — give up the keys, activate the target and wait until it is in
/// front, check the clipboard still holds this copy, then ⌘V — instead of a
/// fixed 120 ms wait that raced the panel's own key focus.
@MainActor
enum AOMMenuBarPanelClips {
    static func paste(_ id: UUID, copyOnly: Bool) {
        let target = AOMStatusPanelController.shared.destination
        Task { @MainActor in
            let version: Int
            do { version = try await ClipboardStore.shared.writeAsync(entryIDs: [id], playSound: false) } catch { return }
            guard !copyOnly, AXIsProcessTrusted(), let target, !target.isTerminated else {
                GestureHUD.shared.show(title: "Copied", detail: "Press ⌘V to paste it")
                return
            }
            let outcome = await ClipboardPasteDelivery.deliver(version: version, environment: .init(
                relinquishFocus: { AOMStatusPanelController.shared.close() },
                targetIsAlive: { !target.isTerminated },
                targetIsFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier },
                activateTarget: { NSApp.yieldActivation(to: target); return target.activate(options: []) },
                clipboardVersion: { NSPasteboard.general.changeCount },
                send: { !PresetManager.isUIPreview && !PresetManager.isRunningTests && ClipboardStackPasteMonitor.sendPaste(to: target) }))
            if outcome != .pasted {
                GestureHUD.shared.show(title: "Copied", detail: "Press ⌘V to paste it")
            }
        }
    }
}

/// The output's mute, written to the device (all channels that have one).
enum AOMPanelOutputMute {
    static func set(_ muted: Bool) {
        guard let device = AudioOutputService.currentDeviceID() else { return }
        var value: UInt32 = muted ? 1 : 0
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: element)
            var writable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { continue }
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

/// 7.24 (Itsycal's adjustStatusItemWidthIfNecessary): a status item whose
/// number gains a digit ("9:59" → "10:00", "9°" → "10°") grew by a digit
/// and pushed the icons beside it. Each item keeps the most digits it has
/// shown and pads shorter readings with figure spaces (a digit's width in a
/// monospaced-digit font), so it never shrinks back and forth.
enum AOMStatusItemWidth {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var widest: [String: Int] = [:]

    /// Pure: `text` with `figureSpaces` U+2007 in front of its first digit.
    static func padded(_ text: String, toDigits digits: Int) -> String {
        let have = text.filter(\.isNumber).count
        guard have > 0, digits > have, let first = text.firstIndex(where: \.isNumber) else { return text }
        var out = text
        out.insert(contentsOf: String(repeating: "\u{2007}", count: digits - have), at: first)
        return out
    }

    static func stable(_ text: String, key: String, minimumDigits: Int = 0) -> String {
        lock.lock()
        let digits = max(minimumDigits, widest[key] ?? 0, text.filter(\.isNumber).count)
        widest[key] = digits
        lock.unlock()
        return padded(text, toDigits: digits)
    }

    static func reset(_ key: String) { lock.lock(); widest[key] = nil; lock.unlock() }
}

/// 7.24: AOM's own icon shows another module's reading (the weather).
enum AOMCombinedStatus {
    static let didChange = Notification.Name("AOMCombinedStatusDidChange")
}
