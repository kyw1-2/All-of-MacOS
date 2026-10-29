import SwiftUI

/// The body of a link card in the shelf. With link cards off (the default)
/// it is the offline site tile AOM has always drawn and nothing touches the
/// network. With them on, the page's title, site name and image load once
/// per session (parity gap P03); a title the user gave the item still wins.
@MainActor
struct ClipboardLinkCardContent: View {
    let entry: ClipboardEntry
    let compact: Bool
    let side: CGFloat
    let accent: Color
    /// The user's title, or the host when the item was never renamed.
    let title: String
    let userTitled: Bool
    let fetches: Bool

    @State private var card: ClipboardLinkCard?
    @State private var image: CGImage?

    private struct LoadKey: Equatable { let version: UUID; let fetches: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.12))
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "safari")
                        .font(.system(size: compact ? 22 : 34, weight: .light))
                        .foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity).frame(height: compact ? 44 : side * 0.36)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(userTitled ? title : (card?.title ?? title))
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .lineLimit(2)
            if !compact, let site = card?.siteName, site.caseInsensitiveCompare(card?.title ?? "") != .orderedSame {
                Text(site).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.previewText)
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(Color.accentColor)
                .lineLimit(card?.siteName == nil ? 2 : 1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: LoadKey(version: entry.contentVersion, fetches: fetches)) {
            guard fetches, let url = ClipboardLinkPolicy.fetchableURL(for: entry) else {
                card = nil
                image = nil
                return
            }
            let store = ClipboardLinkMetadataStore.shared
            card = store.cachedCard(for: url)
            guard let loaded = await store.card(for: url, enabled: fetches), !Task.isCancelled else { return }
            card = loaded
            guard !compact, let picture = await store.image(for: loaded, enabled: fetches), !Task.isCancelled else { return }
            image = picture
        }
    }
}
