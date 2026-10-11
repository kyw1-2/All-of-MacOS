import AppKit
import SwiftUI

/// A safe local drag receiver. It never copies or modifies the received file,
/// sends messages, or contacts any service. Finder/messenger tests remain
/// real-world destination-specific user-driven steps.
struct QuickAccessDropReceiver: NSViewRepresentable {
    var didAccept: (URL) -> Void

    func makeNSView(context: Context) -> Receiver {
        let view = Receiver()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Receiver, context: Context) {
        view.didAccept = didAccept
    }

    final class Receiver: NSView {
        var didAccept: ((URL) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes([.fileURL])
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            QuickAccessDragInterop.urls(from: sender.draggingPasteboard).isEmpty ? [] : .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !QuickAccessDragInterop.urls(from: sender.draggingPasteboard).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let first = QuickAccessDragInterop.urls(from: sender.draggingPasteboard).first else {
                return false
            }
            didAccept?(first)
            return true
        }
    }
}

@MainActor
final class QuickAccessDiagnosticsController: NSObject, NSWindowDelegate {
    static let shared = QuickAccessDiagnosticsController()
    private var window: NSWindow?
    private var fixtureDirectory: URL?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-QA-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Quick-Access-Test.png")
            let cg = try Self.makeImage()
            guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: file, options: .atomic)
            fixtureDirectory = folder
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 720, height: 365),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Quick Access — Local Drag Diagnostics"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: QuickAccessDiagnosticsView(
                file: file, image: NSImage(cgImage: cg, size: NSSize(width: 200, height: 140))))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        } catch {
            try? FileManager.default.removeItem(at: folder)
            GestureHUD.shared.show(title: "Drag Test Failed", detail: error.localizedDescription)
        }
    }

    private static func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: 360, height: 220,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 360, height: 220))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 140, y: 60, width: 80, height: 100))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if let fixtureDirectory {
            // The fixture only belongs to this diagnostic session. Do not
            // touch captures or imported files outside the temporary folder.
            try? FileManager.default.removeItem(at: fixtureDirectory)
            self.fixtureDirectory = nil
        }
    }
}

private struct QuickAccessDiagnosticsView: View {
    let file: URL
    let image: NSImage
    @State private var dragEnded: Bool?
    @State private var receivedURL: URL?
    @State private var receivedBytesMatch = false
    @State private var permissionStates: [AOMPermission: AOMPermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Native file drag — isolated test")
                .font(.headline)
            Text("Drag the sample on the left into the box on the right. No data is sent to another app or network.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 6) {
                    QuickAccessDragSource(
                        preview: image,
                        prepareFile: { file },
                        didFinish: { dragEnded = $0 },
                        didDoubleClick: {},
                        didSwipe: {},
                        isLeftCorner: false)
                        .frame(width: 170, height: 120)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    Text("Drag this PNG").font(.caption)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                            .foregroundStyle(.secondary)
                        VStack {
                            Image(systemName: receivedURL == nil ? "square.and.arrow.down" : "checkmark.circle.fill")
                                .font(.title2)
                            Text(receivedURL == nil ? "Drop here" : "Received valid file")
                                .font(.callout)
                        }
                        .foregroundStyle(receivedURL == nil ? Color.secondary : Color.green)
                    }
                    .overlay {
                        QuickAccessDropReceiver { url in
                            receivedURL = url
                            // Only compare small local test fixtures; never
                            // load arbitrary large dropped user files into RAM.
                            let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                            if let byteCount, byteCount <= 2_000_000 {
                                receivedBytesMatch = (try? Data(contentsOf: url))
                                    == (try? Data(contentsOf: file))
                            } else {
                                receivedBytesMatch = false
                            }
                        }
                    }
                    .frame(width: 205, height: 120)
                    Text("Native AppKit receiver").font(.caption)
                }
                Spacer(minLength: 0)
            }
            Text(resultDescription)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(receivedBytesMatch ? .green : .secondary)

            Divider()
            Text("Live permission checks").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 6) {
                ForEach([AOMPermission.accessibility, .inputMonitoring,
                         .screenRecording, .microphone], id: \.self) { permission in
                    let status = permissionStates[permission] ?? .manualReview
                    Label("\(permission.title): \(status.label)",
                          systemImage: status.symbol)
                        .font(.caption2)
                        .foregroundStyle(status.tint)
                }
            }
            Text("For Finder, drag a real Quick Access card into a temporary Finder folder. For messaging apps, test adding an attachment to a draft only; do not send it. The diagnostic above validates local drag transfer, not third-party acceptance.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var resultDescription: String {
        guard let dragEnded else { return "Drag status: not yet tested" }
        if dragEnded && receivedBytesMatch { return "PASS: drop accepted; URL and bytes match source" }
        if dragEnded { return "Drop accepted by a destination; check target results" }
        return "Drag cancelled or rejected; original file retained"
    }

    private func refreshPermissions() {
        permissionStates = Dictionary(uniqueKeysWithValues:
            AOMPermission.allCases.map { ($0, $0.status) })
    }
}
