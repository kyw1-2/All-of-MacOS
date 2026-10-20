import AppKit
import UniformTypeIdentifiers

/// Explicitly stages attachments before handing their local paths to the main
/// application. Provider URLs can expire as soon as this request completes.
final class ShareViewController: NSViewController {
    private let status = NSTextField(labelWithString: "Open shared images in All of MacOS")
    private var busy = false

    override func loadView() {
        let annotate = NSButton(title: "Annotate", target: self, action: #selector(annotateImages))
        let pin = NSButton(title: "Pin to Screen", target: self, action: #selector(pinImages))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRequest))
        let buttons = NSStackView(views: [cancel, pin, annotate])
        buttons.spacing = 12
        let stack = NSStackView(views: [status, buttons])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view = stack
        preferredContentSize = NSSize(width: 440, height: 130)
    }

    @objc private func annotateImages() { send(mode: "annotate") }
    @objc private func pinImages() { send(mode: "pin") }
    @objc private func cancelRequest() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func send(mode: String) {
        guard !busy else { return }
        busy = true
        status.stringValue = "Preparing images…"
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }.prefix(8)
        Task { @MainActor in
            do {
                var paths: [String] = []
                for provider in providers {
                    let imageType = provider.registeredTypeIdentifiers.first {
                        UTType($0)?.conforms(to: .image) == true
                    }
                    var staged: URL?
                    var lastError: Error?
                    let types = (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                        ? [UTType.fileURL.identifier] : []) + [imageType].compactMap { $0 }
                    for type in types {
                        do {
                            let item = try await load(provider, type: type)
                            if let file = try AOMSharedImageStaging.stage(item, in: stagingDirectory()) {
                                staged = file; break
                            }
                        } catch { lastError = error }
                    }
                    guard let staged else { throw lastError ?? CocoaError(.fileReadCorruptFile) }
                    paths.append(staged.path)
                }
                guard !paths.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
                var link = URLComponents()
                link.scheme = "aom"
                link.host = "share-images"
                link.queryItems = [URLQueryItem(name: "mode", value: mode)] + paths.map { URLQueryItem(name: "file", value: $0) }
                guard let url = link.url, NSWorkspace.shared.open(url) else { throw CocoaError(.fileNoSuchFile) }
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                busy = false
                status.stringValue = "Could not open images: \(error.localizedDescription)"
            }
        }
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    private func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOMSharedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: url) }
        }
        return directory
    }
}
