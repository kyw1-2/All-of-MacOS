import AppKit
import SwiftUI

/// Per-app audio mixer (SoundSource-lite): a floating panel listing every app
/// producing audio, with gain and mute per app. Backed by AppAudioEngine's
/// process taps on macOS 14.2+; older systems see an explanatory empty state.
@MainActor
final class AppAudioMixerService: ObservableObject {
    static let shared = AppAudioMixerService()

    @Published private(set) var apps: [AppAudioState] = []
    @Published private(set) var isShowing = false
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?

    var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func refresh() {
        guard isSupported, #available(macOS 14.2, *) else { return }
        apps = AppAudioEngine.shared.runningAudioApps()
    }

    func showPanel() {
        guard panel == nil else { panel?.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                            styleMask: [.titled, .nonactivatingPanel, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AppAudioMixerView(service: self))
        if let screen = NSScreen.main {
            let size = CGSize(width: 380, height: 420)
            let frame = NSRect(origin: screen.visibleFrame.origin, size: size)
                .offsetBy(dx: screen.visibleFrame.width - size.width - 24,
                          dy: (screen.visibleFrame.height - size.height) / 2)
            panel.setFrame(frame, display: false)
        }
        self.panel = panel
        isShowing = true
        panel.orderFrontRegardless()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing, event.keyCode == 53 else { return event }
            self.hide()
            return nil
        }
    }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    /// Per-app gain: starts the tap session lazily on first adjustment.
    func setGain(_ gain: Float, pid: pid_t) {
        guard #available(macOS 14.2, *) else { return }
        _ = AppAudioEngine.shared.setGain(gain, muted: false, pid: pid)
        refresh()
    }

    /// Toggle per-app mute; the tap session persists so unmuting restores gain.
    func toggleMute(pid: pid_t) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let current = AppAudioEngine.shared.session(pid: pid)
        let muted = current == nil ? true : !current!.muted
        let gain = current?.gain ?? 1
        let ok = AppAudioEngine.shared.setGain(gain, muted: muted, pid: pid)
        if ok { refresh() }
        return ok
    }

    /// Audit action: toggle the frontmost app's audio mute.
    func toggleMuteFront() {
        guard isSupported, let front = NSWorkspace.shared.frontmostApplication else { return }
        _ = toggleMute(pid: front.processIdentifier)
    }
}

private struct AppAudioMixerView: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                Text("App Audio").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { service.hide() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }.padding(12)
            Divider()
            if service.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(service.isSupported ? "No app is playing audio right now."
                                             : "Per-app audio needs macOS 14.2 or newer.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(service.apps) { app in
                            AppAudioRow(app: app,
                                        onGain: { service.setGain($0, pid: app.pid) },
                                        onMute: { service.toggleMute(pid: app.pid) })
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AppAudioRow: View {
    let app: AppAudioState
    let onGain: (Float) -> Void
    let onMute: () -> Void
    @State private var gain: Float
    @State private var muted = false
    @State private var tapped = false

    init(app: AppAudioState, onGain: @escaping (Float) -> Void, onMute: @escaping () -> Void) {
        self.app = app
        self.onGain = onGain
        self.onMute = onMute
        _gain = State(initialValue: min(max(app.gain, 0), 2))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(app.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            Button { onMute() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? .red : .secondary)
            }.buttonStyle(.plain).help(muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(gain) }, set: { newValue in
                gain = Float(newValue)
                onGain(gain)
            }), in: 0...2, step: 0.05)
                .frame(width: 130)
                .controlSize(.small)
            Text("\(Int((gain * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tapped.toggle(); onMute() }
    }
}
