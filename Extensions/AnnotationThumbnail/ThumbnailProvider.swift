import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let maximum = Int(min(1024, max(32, max(request.maximumSize.width, request.maximumSize.height) * request.scale)))
            let (document, scale) = try AnnotationProject.read(from: request.fileURL, thumbnailMaxPixelSize: maximum)
            guard let rendered = document.render(scale: scale) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let factor = min(request.maximumSize.width / CGFloat(rendered.width),
                             request.maximumSize.height / CGFloat(rendered.height))
            let size = CGSize(width: max(1, CGFloat(rendered.width) * factor),
                              height: max(1, CGFloat(rendered.height) * factor))
            handler(QLThumbnailReply(contextSize: size) { context in
                context.interpolationQuality = .high
                context.draw(rendered, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch { handler(nil, error) }
    }
}
