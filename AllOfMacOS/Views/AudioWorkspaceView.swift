import SwiftUI

/// The Audio page: everything SoundSource users reach for, on one screen —
/// output device and master volume, the 10-band equalizer, and per-app volume
/// with mute. The floating mixer panel and the shortcut actions reuse the same
/// sections; this page is the home.
struct AudioWorkspaceView: View {
    @ObservedObject private var service = AppAudioMixerService.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AOMSpace.l) {
                AOMSectionCard("Output", symbol: "hifispeaker.fill",
                               detail: "The device every app plays through") {
                    MixerOutputSection()
                }
                AOMSectionCard("Equalizer", symbol: "slider.horizontal.3",
                               detail: "Ten bands, applied to every app you've adjusted") {
                    EQSection(service: service)
                }
                AOMSectionCard("Applications", symbol: "app.badge.fill",
                               detail: service.isSupported
                                   ? "Volume and mute per running audio app (macOS 14.2+)"
                                   : "Per-app audio needs macOS 14.2 or newer") {
                    if service.apps.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                            Text(service.isSupported ? "No app is playing audio right now."
                                                     : "Per-app volume needs macOS 14.2 or newer.")
                                .font(AOMType.body).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(service.apps) { app in
                                AppAudioRow(app: app,
                                            onGain: { service.setGain($0, pid: app.pid) },
                                            onMute: { service.toggleMute(pid: app.pid) })
                                if app.id != service.apps.last?.id {
                                    AOMDivider(axis: .horizontal).padding(.leading, 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AOMSpace.xl)
        }
        .background(AOMTheme.workspace)
        .task {
            service.refresh()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            service.refresh()
        }
    }
}
