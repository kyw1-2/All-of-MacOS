import AppKit
import AVKit
import SwiftUI

/// A larger non-destructive Quick Look-like native window for one capture.
@MainActor
final class QuickAccessExpandedPreview: NSObject, NSWindowDelegate {
    static let shared = QuickAccessExpandedPreview()
    private var windows: [UUID: NSWindow] = [:]

    func open(entry: CaptureHistoryEntry) {
        if let existing = windows[entry.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let size = CGSize(width: min(1000, max(500, entry.pointSize.width)),
                          height: min(720, max(370, entry.pointSize.height + 55)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = entry.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: QuickAccessExpandedPreviewContent(entry: entry))
        window.makeKeyAndOrderFront(nil)
        windows[entry.id] = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

private struct QuickAccessExpandedPreviewContent: View {
    let entry: CaptureHistoryEntry
    @State private var showingVideoEditor = false
    var body: some View {
        VStack(spacing: 0) {
            if let url = entry.playableVideoURL {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                GeometryReader { geometry in
                    Image(nsImage: NSImage(cgImage: entry.image,
                                           size: NSSize(width: entry.pointSize.width,
                                                        height: entry.pointSize.height)))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(entry.displayName).lineLimit(1)
                Spacer()
                Text("\(entry.image.width) × \(entry.image.height) px")
                    .monospacedDigit()
                if let url = entry.playableVideoURL {
                    Button("Edit Video…") { showingVideoEditor = true }
                        .sheet(isPresented: $showingVideoEditor) {
                            RecordingExportEditor(source: url)
                        }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
