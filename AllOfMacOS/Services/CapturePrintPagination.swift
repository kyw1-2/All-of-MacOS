import CoreGraphics

/// Pure pagination math for printing tall (scrolling) captures.
///
/// The image is scaled to fit the printable width (never enlarged), then cut
/// into page-high strips. Consecutive strips can overlap so a line of text cut
/// at a page boundary appears whole on one of the two pages. All rects are in
/// the print view's flipped coordinate space (origin top-left, points).
struct CapturePrintPagination: Equatable {
    /// Image points → printed points.
    var scale: CGFloat
    /// The image as printed.
    var contentSize: CGSize
    /// Height of one page's content strip (printable height minus footer).
    var pageHeight: CGFloat
    /// The effective overlap between consecutive pages.
    var overlap: CGFloat
    /// One rect per page, in order.
    var pages: [CGRect]

    var pageCount: Int { pages.count }

    /// The print view must be at least this tall so the last page rect is valid.
    var viewSize: CGSize {
        CGSize(width: pages.first?.width ?? contentSize.width,
               height: max(contentSize.height, pages.last?.maxY ?? contentSize.height))
    }

    /// Choices offered in the print panel accessory, in points.
    static let overlapChoices: [CGFloat] = [0, 12, 24, 48]

    /// - Parameters:
    ///   - imageSize: the capture in points (pixels ÷ backing scale).
    ///   - printableSize: paper size minus margins, in points.
    ///   - overlap: requested overlap; clamped to half a page so pagination always advances.
    ///   - footerHeight: space reserved at the bottom of each page (page numbers).
    static func compute(imageSize: CGSize, printableSize: CGSize, overlap: CGFloat,
                        footerHeight: CGFloat = 0) -> CapturePrintPagination {
        let printableWidth = max(1, printableSize.width.isFinite ? printableSize.width : 1)
        let pageHeight = max(1, (printableSize.height.isFinite ? printableSize.height : 1) - max(0, footerHeight))
        let imageWidth = max(1, imageSize.width.isFinite ? imageSize.width : 1)
        let imageHeight = max(1, imageSize.height.isFinite ? imageSize.height : 1)
        let scale = min(1, printableWidth / imageWidth)
        let content = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let overlap = min(max(0, overlap.isFinite ? overlap : 0), pageHeight / 2)
        let step = pageHeight - overlap

        let count: Int
        if content.height <= pageHeight + 0.5 {
            count = 1
        } else {
            count = 1 + Int(((content.height - pageHeight) / step - 0.0001).rounded(.up))
        }
        let pages = (0..<max(1, count)).map { index in
            CGRect(x: 0, y: CGFloat(index) * step, width: printableWidth, height: pageHeight)
        }
        return CapturePrintPagination(scale: scale, contentSize: content, pageHeight: pageHeight,
                                      overlap: overlap, pages: pages)
    }

    /// "Page 2 of 5".
    static func pageLabel(_ page: Int, of count: Int) -> String { "Page \(page) of \(count)" }
}
