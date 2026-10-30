import SwiftUI

/// An image item in a preview (parity gap P04): the picture, the places
/// where the search matches its text, and a region the user drags out to
/// read (on-device OCR of the full-resolution crop) or copy as an image.
///
/// `selection` is a unit rectangle with a top-left origin, owned by the
/// caller so its key handler can copy the region's text with ⌘C.
@MainActor
struct ClipboardImageInspector: View {
    let entry: ClipboardEntry
    let image: CGImage
    let query: String
    let store: ClipboardStore
    @Binding var selection: CGRect?
    @Binding var regionText: String?
    var onStatus: (String) -> Void = { _ in }

    @State private var lines: [ClipboardOCRLine] = []
    @State private var dragOrigin: CGPoint?
    @State private var reading = false
    @State private var readTask: Task<Void, Never>?

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var terms: [String] { ClipboardSearchQuery(query).highlightValues }
    private var matches: [CGRect] { ClipboardImageText.matchBoxes(in: lines, terms: terms) }

    var body: some View {
        GeometryReader { geometry in
            let fitted = ClipboardImageText.fittedRect(imageSize: imageSize, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(Array(matches.enumerated()), id: \.offset) { _, box in
                    let rect = ClipboardImageText.viewRect(for: box, in: fitted).insetBy(dx: -AOMSpace.x0_5, dy: -1)
                    RoundedRectangle(cornerRadius: AOMRadius.keycap - 1, style: .continuous)
                        .fill(AOMFeatureColor.findHighlight.opacity(0.32))
                        .overlay(RoundedRectangle(cornerRadius: AOMRadius.keycap - 1, style: .continuous)
                            .strokeBorder(AOMFeatureColor.findHighlight, lineWidth: 1.5))
                        .frame(width: max(AOMSpace.x1, rect.width), height: max(AOMSpace.x1, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                if let selection {
                    let rect = ClipboardImageText.viewRect(for: selection, in: fitted)
                    Path { path in
                        path.addRect(fitted)
                        path.addRect(rect)
                    }
                    .fill(AOMFeatureColor.mediaDim, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Rectangle().strokeBorder(AOMColor.accent, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    let origin = dragOrigin ?? value.startLocation
                    if dragOrigin == nil { dragOrigin = origin; regionText = nil; readTask?.cancel() }
                    let drawn = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                       width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y))
                    let unit = ClipboardImageText.unitRect(for: drawn, in: fitted)
                    selection = unit.width > 0 && unit.height > 0 ? unit : nil
                }
                .onEnded { _ in
                    dragOrigin = nil
                    readSelection()
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(matches.isEmpty ? "Image" : "Image, \(matches.count) matching text areas highlighted")
            .accessibilityHint("Drag over the image to read or copy part of it.")
        }
        .overlay(alignment: .bottom) { regionBar }
        .task(id: entry.contentVersion) {
            lines = entry.recognizedLines ?? []
            if entry.recognizedLines == nil { lines = await store.recognizedLayout(for: entry.id) }
        }
        .onDisappear { readTask?.cancel() }
        .help("Drag over the image to read or copy part of it")
    }

    @ViewBuilder private var regionBar: some View {
        if selection != nil {
            HStack(spacing: AOMSpace.x2) {
                if reading {
                    ProgressView().controlSize(.small)
                    Text("Reading text…").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                } else {
                    Text(regionText.map { $0.isEmpty ? "No text found in this area." : $0 } ?? "")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.text).lineLimit(2).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Copy Text") { copyText() }
                    .disabled(reading || (regionText ?? "").isEmpty)
                    .help("Copy the text in the selected area (⌘C)")
                Button("Copy Image") { copyImage() }
                    .help("Copy the selected area as an image")
                Button { clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary) }
                    .buttonStyle(.plain).help("Clear Selection").accessibilityLabel("Clear Selection")
            }
            .font(AOMFont.callout.weight(.medium))
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.horizontal, AOMSpace.x3).padding(.vertical, AOMSpace.x2)
            .aomCard(radius: AOMRadius.well, padding: 0)
            .aomElevation(.raised)
            .padding(AOMSpace.x2)
        }
    }

    private func readSelection() {
        guard let region = selection, let data = entry.imageData else { return }
        readTask?.cancel()
        reading = true
        let stored = lines
        readTask = Task { @MainActor in
            let text = await ClipboardImageText.recognizeRegion(imageData: data, region: region, storedLines: stored)
            guard !Task.isCancelled, selection == region else { return }
            regionText = text
            reading = false
        }
    }

    private func copyText() {
        guard let text = regionText, !text.isEmpty else { return }
        do { try store.copyDerivedText(text); onStatus("Text from the selected area copied.") }
        catch { onStatus(error.localizedDescription) }
    }

    private func copyImage() {
        guard let region = selection, let data = entry.imageData,
              let crop = ClipboardImageText.croppedImage(imageData: data, region: region) else {
            onStatus("Select a larger area to copy.")
            return
        }
        do { try store.copyDerivedImage(crop); onStatus("Selected area copied as an image.") }
        catch { onStatus(error.localizedDescription) }
    }

    private func clear() {
        readTask?.cancel()
        reading = false
        selection = nil
        regionText = nil
    }
}

/// Highlights of search matches on an image card's thumbnail.
struct ClipboardImageMatchOverlay: View {
    let lines: [ClipboardOCRLine]
    let terms: [String]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let fitted = ClipboardImageText.fittedRect(imageSize: imageSize, in: CGRect(origin: .zero, size: geometry.size))
            ForEach(Array(ClipboardImageText.matchBoxes(in: lines, terms: terms, limit: 40).enumerated()), id: \.offset) { _, box in
                let rect = ClipboardImageText.viewRect(for: box, in: fitted).insetBy(dx: -1.5, dy: -1)
                RoundedRectangle(cornerRadius: AOMRadius.keycap - 2, style: .continuous)
                    .fill(AOMFeatureColor.findHighlight.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: AOMRadius.keycap - 2, style: .continuous)
                        .strokeBorder(AOMFeatureColor.findHighlight, lineWidth: 1))
                    .frame(width: max(3, rect.width), height: max(3, rect.height))
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
