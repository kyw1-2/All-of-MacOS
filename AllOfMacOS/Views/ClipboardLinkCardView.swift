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
        VStack(alignment: .leading, spacing: compact ? AOMSpace.x1 : AOMSpace.x2) {
            ZStack {
                RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                    .fill(accent.opacity(0.12))
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "safari")
                        .font(compact ? AOMFont.pageStatus.weight(.regular) : AOMFont.title.weight(.regular))
                        .imageScale(compact ? .medium : .large)
                        .foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity).frame(height: compact ? AOMSpace.x10 + AOMSpace.x1 : side * 0.36)
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            Text(userTitled ? title : (card?.title ?? title))
                .font(compact ? AOMFont.caption.weight(.semibold) : AOMFont.headline)
                .foregroundStyle(AOMColor.text)
                .lineLimit(2)
            if !compact, let site = card?.siteName, site.caseInsensitiveCompare(card?.title ?? "") != .orderedSame {
                Text(site).font(AOMFont.caption.weight(.medium)).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Text(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.previewText)
                .font(compact ? AOMFont.badge : AOMFont.caption)
                .foregroundStyle(AOMColor.accent)
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
