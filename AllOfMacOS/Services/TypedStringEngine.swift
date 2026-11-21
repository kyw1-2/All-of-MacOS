import AppKit
import CoreGraphics

/// Text-expansion engine (espanso / BTT Typed Strings parity).
///
/// The keyboard tap feeds every printable keyDown here. Characters accumulate
/// in a short per-context buffer; when the buffer ends with a rule's
/// abbreviation the final key is swallowed by the tap and the rest of the
/// abbreviation is erased with synthesized backspaces before the replacement
/// is typed or the trigger's actions fire.
///
/// The buffer resets on app switches, gaps
/// longer than two seconds, Secure Event Input (never expand into a password
/// field), our own typing sessions, and any moment an AOM window is key.
@MainActor
final class TypedStringEngine {
    static let shared = TypedStringEngine()

    struct Match {
        let trigger: Trigger
        /// Backspaces to synthesize before the expansion runs: every typed
        /// character of the abbreviation except the swallowed final key.
        let backspaces: Int
    }

    private struct Entry {
        var text: String
        var at: TimeInterval
        var bundleID: String
    }
    private var buffer: [Entry] = []
    /// Events we inject ourselves carry this tag and the keyboard tap skips
    /// them, so an expansion can never feed back into its own matcher.
    private static let gapSeconds: TimeInterval = 2.0

    func reset() { buffer.removeAll() }

    /// The last `count` characters typed, as typed (7.3: put back when an
    /// expansion can't be inserted after its abbreviation was erased).
    func typedTail(_ count: Int) -> String {
        buffer.suffix(count).map(\.text).joined()
    }

    /// Feeds one typed character. Returns a match when the buffer now ends
    /// with a registered abbreviation and the final key should be swallowed.
    /// 7.3 (Codex 7.2.3 report): the typed strings with their lowercased
    /// abbreviations, made once per registration instead of on every key.
    private var prepared: (generation: UUID?, entries: [(trigger: Trigger, abbreviation: String, last: Character)]) = (nil, [])

    private func entries(_ registered: [Trigger], generation: UUID?) -> [(trigger: Trigger, abbreviation: String, last: Character)] {
        if let generation, prepared.generation == generation { return prepared.entries }
        let entries = registered.compactMap { trigger -> (trigger: Trigger, abbreviation: String, last: Character)? in
            guard case .typedString(let spec) = trigger.input else { return nil }
            let abbreviation = spec.abbreviation.lowercased()
            guard abbreviation.count >= 2, let last = abbreviation.last else { return nil }
            return (trigger, abbreviation, last)
        }
        if let generation { prepared = (generation, entries) }
        return entries
    }

    func observe(text: String, bundleID: String,
                 registered: [Trigger], activationGroups: [ActivationGroup], generation: UUID? = nil) -> Match? {
        guard text.count == 1, let character = text.first, character.isPrintableCharacter else {
            reset(); return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if buffer.last?.bundleID != bundleID || now - (buffer.last?.at ?? 0) > Self.gapSeconds { reset() }
        buffer.append(Entry(text: text, at: now, bundleID: bundleID))
        if buffer.count > 64 { buffer.removeFirst(buffer.count - 64) }
        // Character(_:) would trap on a lowercase form of two characters.
        guard let lastTyped = text.lowercased().last else { return nil }
        let possible = entries(registered, generation: generation).filter { $0.last == lastTyped }
        guard !possible.isEmpty else { return nil }
        let typed = buffer.map(\.text).joined().lowercased()
        let candidates = possible.filter { typed.count >= $0.abbreviation.count && typed.hasSuffix($0.abbreviation) }.map(\.trigger)
        guard let winner = TriggerResolver.resolve(candidates, payload: true, frontBundleID: bundleID,
            payloadOf: { _ in true }, appBundleIDOf: { $0.appBundleID },
            groups: activationGroups, activationGroupIDOf: { $0.activationGroupID }).max(by: {
                typedStringAbbreviation($0).count < typedStringAbbreviation($1).count }) else { return nil }
        guard case .typedString(let spec) = winner.input else { return nil }
        return Match(trigger: winner, backspaces: max(0, spec.abbreviation.count - 1))
    }

    private func typedStringAbbreviation(_ trigger: Trigger) -> String {
        if case .typedString(let spec) = trigger.input { return spec.abbreviation.lowercased() }
        return ""
    }

    /// Erases the already-typed part of the abbreviation with tagged synthetic
    /// backspaces (down+up pairs), then types the replacement. Nonisolated:
    /// event posting is thread-safe and this must not block the tap callback.
    nonisolated func erase(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: down) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
                event.post(tap: .cghidEventTap)
            }
            usleep(6000)
        }
    }
}

private extension Character {
    /// Anything that would normally land in a text field as visible input.
    var isPrintableCharacter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 32 && scalar.value != 0x7F
    }
}
