import AppKit

/// Annotation object copy & paste (CleanShot "Copy Object to Clipboard").
///
/// The pasteboard gets an AOM-private JSON payload (so objects paste back as
/// editable objects, including into another editor window) plus a PNG of the
/// rendered objects for other apps.
enum AnnotationObjectClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("com.kyw.allofmacos.annotation-objects")
    static let maximumObjects = 500
    /// Each successive paste of the same clipboard contents moves this much further.
    static let pasteStep: CGFloat = 10

    struct Payload: Codable, Equatable {
        var version = 1
        var objects: [AnnotationObject]
    }

    @discardableResult
    static func write(_ objects: [AnnotationObject], image: CGImage?, scale: CGFloat,
                      to pasteboard: NSPasteboard = .general) -> Bool {
        guard !objects.isEmpty, objects.count <= maximumObjects,
              let data = try? JSONEncoder().encode(Payload(objects: objects)) else { return false }
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = [pasteboardType]
        let png = image.flatMap { image -> Data? in
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / max(1, scale), height: CGFloat(image.height) / max(1, scale))
            return rep.representation(using: .png, properties: [:])
        }
        if png != nil { types.append(.png) }
        pasteboard.declareTypes(types, owner: nil)
        var ok = pasteboard.setData(data, forType: pasteboardType)
        if let png { ok = pasteboard.setData(png, forType: .png) && ok }
        return ok
    }

    /// Validated objects from the pasteboard, or nil when there are none.
    static func read(from pasteboard: NSPasteboard = .general) -> [AnnotationObject]? {
        guard let data = pasteboard.data(forType: pasteboardType), data.count <= 20_000_000,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1, !payload.objects.isEmpty, payload.objects.count <= maximumObjects else {
            return nil
        }
        func finite(_ r: CGRect) -> Bool {
            [r.minX, r.minY, r.width, r.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
        }
        let valid = payload.objects.allSatisfy { object in
            finite(object.rect) && object.points.count <= 200_000
                && object.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                && object.text.utf8.count <= 1_000_000
                && object.style.opacity.isFinite && (0...1).contains(object.style.opacity)
        }
        return valid ? payload.objects : nil
    }

    static func hasObjects(on pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [pasteboardType]) != nil
    }
}
