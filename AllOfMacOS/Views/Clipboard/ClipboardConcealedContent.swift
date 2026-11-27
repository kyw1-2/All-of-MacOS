import SwiftUI

/// 7.22 (DeepSeek 7.21 report §4.1): what a clipboard surface draws in place
/// of an item that looks like a credential. No characters of the value are
/// laid out — not even blurred — so a screenshot, a screen share or someone
/// beside the Mac sees a lock and a length, never the text. Revealing is an
/// explicit click and lasts until the surface closes.
///
/// This protects the screen, not the data: the item is still stored and
/// pasted in full (ClipboardStore keeps the original).
struct ClipboardConcealedContent: View {
    var compact: Bool = false
    /// Characters in the hidden text, shown as a rough length so two secrets
    /// can be told apart without revealing either.
    var length: Int?
    var reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? AOMSpace.x1 : AOMSpace.x2) {
            Label("Hidden secret", systemImage: "lock.fill")
                .font((compact ? AOMFont.badge : AOMFont.headline))
                .foregroundStyle(AOMColor.textSecondary)
            Text(Self.mask(length: length, compact: compact))
                .font(compact ? AOMFont.caption : AOMFont.body).monospaced()
                .foregroundStyle(AOMColor.textTertiary)
                .lineLimit(compact ? 1 : 2)
                .accessibilityHidden(true)
            if !compact {
                Spacer(minLength: 0)
                Button("Show", action: reveal)
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Show this item until the panel closes")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            // ⌥-click reveals without moving to the button (compact cards
            // have none); a plain click keeps selecting the card.
            if NSEvent.modifierFlags.contains(.option) { reveal() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hidden secret")
        .accessibilityHint("Show reveals it until the panel closes")
        .accessibilityAction(named: "Show", reveal)
    }

    /// Dots in groups of four, about as long as the value (capped), so the
    /// card is not empty yet nothing of the value is drawn.
    nonisolated static func mask(length: Int?, compact: Bool) -> String {
        let count = min(compact ? 12 : 24, max(8, length ?? 12))
        return stride(from: 0, to: count, by: 4)
            .map { String(repeating: "•", count: min(4, count - $0)) }
            .joined(separator: " ")
    }
}

/// One test for every clipboard surface: conceal when the preference is on
/// and the item classifies as a secret (the classification is cached per
/// content digest in ClipboardIntelligence).
@MainActor
enum ClipboardSecretDisplay {
    static func conceals(_ entry: ClipboardEntry, revealed: Set<UUID> = []) -> Bool {
        ClipboardPreferences.shared.concealSecrets && !revealed.contains(entry.id)
            && ClipboardIntelligence.shared.itemClass(entry) == .secret
    }

    /// A one-line label for list rows (the stack, the launcher): the lock
    /// text instead of the value.
    static let rowLabel = "Hidden secret"

    /// A row title: the lock label for a concealed secret, else the title.
    /// Launcher rows match their title, so a secret is not found by typing
    /// part of its value either.
    static func title(_ entry: ClipboardEntry) -> String {
        conceals(entry) ? "🔒 \(rowLabel)" : entry.title
    }

    static func rowText(_ entry: ClipboardEntry, revealed: Set<UUID> = []) -> String {
        conceals(entry, revealed: revealed) ? "🔒 \(rowLabel) · \(ClipboardConcealedContent.mask(length: entry.text?.count, compact: true))"
            : (entry.previewText.isEmpty ? entry.title : entry.previewText)
    }
}
