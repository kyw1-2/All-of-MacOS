import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image waiting for a side ("Add Screenshot From File…").
struct AnnotationPlacementRequest: Identifiable {
    let id = UUID()
    let image: CGImage
    /// The image's own backing scale (from its DPI), used to match point sizes.
    let scale: CGFloat
}

/// Sheet asking where an added image goes. Arrow keys pick a side, Return
/// places it below (the default), Esc cancels.
struct AnnotationPlacementChooser: View {
    let thumbnail: CGImage
    let choose: (AnnotationCombinePlacement?) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Place Screenshot").font(.headline)
            Text("Choose which side of the current image the new screenshot goes on.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    button(.top, key: .upArrow)
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    button(.left, key: .leftArrow)
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                        .frame(width: 96, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    button(.right, key: .rightArrow)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    button(.bottom, key: .downArrow)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { choose(nil) }.keyboardShortcut(.cancelAction)
                Button("Place Below") { choose(.bottom) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func button(_ placement: AnnotationCombinePlacement, key: KeyEquivalent) -> some View {
        Button { choose(placement) } label: {
            Image(systemName: placement.symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 36)
        }
        .keyboardShortcut(key, modifiers: [])
        .help("\(placement.title) (arrow key)")
        .accessibilityLabel(placement.title)
    }
}

/// Drop-zone arrows over the canvas while an image is dragged onto it
/// (CleanShot "Place on the right / left / top / bottom").
struct AnnotationDropZoneOverlay: View {
    let active: AnnotationCombinePlacement

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                ForEach(AnnotationCombinePlacement.allCases) { placement in
                    arrow(placement, highlighted: placement == active)
                        .position(position(for: placement, in: size))
                }
                Text(active.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .position(x: size.width / 2, y: size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(active.title)
    }

    private func arrow(_ placement: AnnotationCombinePlacement, highlighted: Bool) -> some View {
        Image(systemName: placement.symbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(highlighted ? Color.white : Color.accentColor)
            .frame(width: 40, height: 40)
            .background(highlighted ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.9),
                        in: Circle())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .scaleEffect(highlighted ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    private func position(for placement: AnnotationCombinePlacement, in size: CGSize) -> CGPoint {
        switch placement {
        case .top: return CGPoint(x: size.width / 2, y: 28)
        case .bottom: return CGPoint(x: size.width / 2, y: size.height - 28)
        case .left: return CGPoint(x: 28, y: size.height / 2)
        case .right: return CGPoint(x: size.width - 28, y: size.height / 2)
        }
    }
}

/// Accepts image files or image data dropped on the canvas and reports the
/// side under the pointer while dragging.
struct AnnotationCanvasDropDelegate: DropDelegate {
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    let canvasSize: CGSize
    @Binding var placement: AnnotationCombinePlacement?
    let onDrop: (CGImage, CGFloat?, AnnotationCombinePlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) { placement = AnnotationCombinePlacement.zone(for: info.location, in: canvasSize) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = AnnotationCombinePlacement.zone(for: info.location, in: canvasSize)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { placement = nil }

    func performDrop(info: DropInfo) -> Bool {
        let side = AnnotationCombinePlacement.zone(for: info.location, in: canvasSize)
        placement = nil
        let handler = onDrop
        if let provider = info.itemProviders(for: [.fileURL]).first {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let entry = AnnotationEditorControllerBridge.entry(at: url) else { return }
                DispatchQueue.main.async { handler(entry.image, entry.scale, side) }
            }
            return true
        }
        if let provider = info.itemProviders(for: [.image]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, data.count <= 300_000_000, let image = NSImage(data: data),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let imageScale = image.size.width > 0 ? CGFloat(cgImage.width) / image.size.width : nil
                DispatchQueue.main.async { handler(cgImage, imageScale, side) }
            }
            return true
        }
        return false
    }
}

/// Off-main image loading for drops (the controller's helper is main-actor free).
enum AnnotationEditorControllerBridge {
    static func entry(at url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (image, CGFloat(max(1, min(4, (dpi / 72).rounded()))))
    }
}
