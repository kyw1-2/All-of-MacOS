import AppKit

/// Print options shown in the print panel (overlap, page numbers), remembered.
final class CapturePrintOptions: NSObject {
    static let overlapKey = "AOMPrintOverlap"
    static let pageNumbersKey = "AOMPrintPageNumbers"

    /// Nil for transient options (tests) that must not touch preferences.
    private let defaults: UserDefaults?

    @objc dynamic var overlap: Double {
        didSet { defaults?.set(overlap, forKey: Self.overlapKey) }
    }
    @objc dynamic var showsPageNumbers: Bool {
        didSet { defaults?.set(showsPageNumbers, forKey: Self.pageNumbersKey) }
    }

    /// Remembered options.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overlap = defaults.object(forKey: Self.overlapKey) as? Double ?? 24
        showsPageNumbers = defaults.object(forKey: Self.pageNumbersKey) as? Bool ?? true
        super.init()
    }

    /// Transient options (not persisted).
    init(overlap: Double, showsPageNumbers: Bool) {
        defaults = nil
        self.overlap = overlap
        self.showsPageNumbers = showsPageNumbers
        super.init()
    }
}

/// Paginates one capture across as many pages as it needs
/// (`knowsPageRange` / `rectForPage`), with optional overlap and page numbers.
final class CapturePrintView: NSView {
    let image: NSImage
    /// The capture's size in points.
    let imageSize: CGSize
    let options: CapturePrintOptions
    private(set) var pagination: CapturePrintPagination
    static let footerHeight: CGFloat = 18

    init(image: CGImage, scale: CGFloat, options: CapturePrintOptions) {
        let s = scale.isFinite && scale > 0 ? scale : 1
        imageSize = CGSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s)
        self.image = NSImage(cgImage: image, size: imageSize)
        self.options = options
        pagination = CapturePrintPagination.compute(imageSize: imageSize, printableSize: imageSize, overlap: 0)
        super.init(frame: CGRect(origin: .zero, size: imageSize))
        setAccessibilityLabel("Print preview of the capture")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Printable area of `info` (paper minus margins).
    static func printableSize(for info: NSPrintInfo) -> CGSize {
        CGSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
               height: info.paperSize.height - info.topMargin - info.bottomMargin)
    }

    /// Recomputes pages for `info` and resizes the view to cover them.
    @discardableResult
    func paginate(for info: NSPrintInfo) -> CapturePrintPagination {
        pagination = CapturePrintPagination.compute(
            imageSize: imageSize, printableSize: Self.printableSize(for: info),
            overlap: CGFloat(options.overlap),
            footerHeight: options.showsPageNumbers ? Self.footerHeight : 0)
        setFrameSize(pagination.viewSize)
        return pagination
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        paginate(for: info)
        range.pointee = NSRange(location: 1, length: pagination.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let index = min(max(page - 1, 0), pagination.pageCount - 1)
        return pagination.pages[index]
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let content = pagination.contentSize
        let x = ((pagination.pages.first?.width ?? content.width) - content.width) / 2
        image.draw(in: CGRect(x: x, y: 0, width: content.width, height: content.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// Page numbers go in the bottom margin of each sheet.
    override func drawPageBorder(with borderSize: NSSize) {
        guard options.showsPageNumbers, let operation = NSPrintOperation.current else { return }
        let info = operation.printInfo
        let saved = frame
        setFrameOrigin(.zero)
        setFrameSize(borderSize)
        let label = CapturePrintPagination.pageLabel(operation.currentPage, of: pagination.pageCount)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.darkGray,
        ]
        let size = label.size(withAttributes: attributes)
        // Flipped: y grows downwards; the label sits in the footer strip that
        // pagination reserved below each page's content.
        let footerTop = info.topMargin + pagination.pageHeight + (Self.footerHeight - size.height) / 2
        let origin = CGPoint(x: (borderSize.width - size.width) / 2, y: footerTop)
        label.draw(at: origin, withAttributes: attributes)
        frame = saved
    }
}

/// Print panel accessory: overlap and page numbers (CleanShot has Print…, AOM
/// adds controls that matter for long scrolling captures).
final class CapturePrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    @objc let options: CapturePrintOptions

    init(options: CapturePrintOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
        title = "Capture"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let overlapLabel = NSTextField(labelWithString: "Page overlap:")
        let overlap = NSPopUpButton(frame: .zero, pullsDown: false)
        for value in CapturePrintPagination.overlapChoices {
            overlap.addItem(withTitle: value == 0 ? "None" : "\(Int(value)) pt")
            overlap.lastItem?.tag = Int(value)
        }
        overlap.selectItem(withTag: Int(options.overlap))
        if overlap.selectedItem == nil { overlap.selectItem(at: 0) }
        overlap.target = self
        overlap.action = #selector(overlapChanged(_:))
        overlap.setAccessibilityLabel("Page overlap")
        overlap.toolTip = "Repeat this much of the previous page at the top of the next one"

        let numbers = NSButton(checkboxWithTitle: "Print page numbers", target: self,
                               action: #selector(pageNumbersChanged(_:)))
        numbers.state = options.showsPageNumbers ? .on : .off
        numbers.toolTip = "Adds “Page N of M” to the bottom margin"

        let row = NSStackView(views: [overlapLabel, overlap])
        row.orientation = .horizontal
        let stack = NSStackView(views: [row, numbers])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.frame = CGRect(x: 0, y: 0, width: 360, height: 80)
        view = stack
    }

    @objc private func overlapChanged(_ sender: NSPopUpButton) {
        options.overlap = Double(sender.selectedTag())
    }

    @objc private func pageNumbersChanged(_ sender: NSButton) {
        options.showsPageNumbers = sender.state == .on
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Page overlap", .itemDescription: options.overlap == 0 ? "None" : "\(Int(options.overlap)) pt"],
         [.itemName: "Page numbers", .itemDescription: options.showsPageNumbers ? "On" : "Off"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["options.overlap", "options.showsPageNumbers"]
    }
}

/// Entry point used by Quick Access (Print…) and the annotate editor (⌘P).
@MainActor
enum CapturePrintController {
    /// Keeps the accessory alive for the duration of a sheet-modal print.
    private static var active: (NSPrintOperation, CapturePrintAccessoryController)?

    static func makeOperation(image: CGImage, scale: CGFloat, title: String,
                              options: CapturePrintOptions = CapturePrintOptions()) -> NSPrintOperation {
        let view = CapturePrintView(image: image, scale: scale, options: options)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        // Room for the page number in the bottom margin.
        info.bottomMargin = max(info.bottomMargin, 36)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let accessory = CapturePrintAccessoryController(options: options)
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview,
                                                .showsPageSetupAccessory])
        operation.printPanel.addAccessoryController(accessory)
        active = (operation, accessory)
        return operation
    }

    static func print(image: CGImage, scale: CGFloat, title: String, window: NSWindow?) {
        let operation = makeOperation(image: image, scale: scale, title: title)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
            active = nil
        }
    }
}
