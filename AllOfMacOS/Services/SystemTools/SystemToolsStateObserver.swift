import AppKit
import CoreAudio

/// Visible-page notifications; the page retains a slow fallback for settings
/// (Finder preferences, Wi-Fi, etc.) without a reliable notification contract.
@MainActor
final class SystemToolsStateObserver {
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var audio: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    enum Change { case audio, general }
    private var changed: ((Change) -> Void)?

    func start(changed: @escaping (Change) -> Void) {
        guard self.changed == nil else { return }
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            observe(workspace, name)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observe(.default, name)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification"))
        bindAudio()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed?(.general) }
        }
        notifications.append((center, token))
    }

    private func bindAudio() {
        removeAudio()
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            listen(AudioObjectID(kAudioObjectSystemObject), AudioOutputService.address(selector), topology: true)
        }
        for (device, scope) in [(AudioOutputService.defaultInputDeviceID(), kAudioDevicePropertyScopeInput),
                                (AudioOutputService.currentDeviceID(), kAudioDevicePropertyScopeOutput)] {
            guard let device else { continue }
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                    listen(device, AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element))
                }
            }
        }
    }

    private func listen(_ device: AudioObjectID, _ property: AudioObjectPropertyAddress, topology: Bool = false) {
        var property = property
        guard AudioObjectHasProperty(device, &property) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.changed != nil else { return }
                if topology { self.bindAudio() }
                self.changed?(.audio)
            }
        }
        if AudioObjectAddPropertyListenerBlock(device, &property, .main, block) == noErr {
            audio.append((device, property, block))
        }
    }

    private func removeAudio() {
        for (device, property, block) in audio {
            var property = property
            AudioObjectRemovePropertyListenerBlock(device, &property, .main, block)
        }
        audio.removeAll()
    }

    func stop() {
        changed = nil
        notifications.forEach { $0.0.removeObserver($0.1) }
        notifications.removeAll()
        removeAudio()
    }

    deinit {
        notifications.forEach { $0.0.removeObserver($0.1) }
        for (device, property, block) in audio {
            var property = property
            AudioObjectRemovePropertyListenerBlock(device, &property, .main, block)
        }
    }
}
