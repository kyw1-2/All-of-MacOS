import Foundation
import AppKit

class MouseButtonMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var registeredTriggers: [(id: UUID, button: MouseButton, actions: [TriggerAction], appBundleID: String?, suppressClick: Bool, requiredModifiers: UInt?, activationGroupID: UUID?)] = []

    private var activationGroups: [ActivationGroup] = []
    private var suppressedButtons = Set<Int64>()
    private static var activeMonitor: MouseButtonMonitor?

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        unregisterAll()
        activationGroups = groups
        let mouseTriggers = triggers.filter {
            if case .mouseButton = $0.input { return $0.isEnabled }
            return false
        }

        for trigger in mouseTriggers {
            if case .mouseButton(let button) = trigger.input {
                registeredTriggers.append((
                    id: trigger.id,
                    button: button,
                    actions: trigger.actions,
                    appBundleID: trigger.appBundleID,
                    suppressClick: trigger.suppressClick, requiredModifiers: trigger.requiredModifiers, activationGroupID: trigger.activationGroupID
                ))
            }
        }

        guard !registeredTriggers.isEmpty else { return }

        MouseButtonMonitor.activeMonitor = self

        let eventMask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let monitor = MouseButtonMonitor.activeMonitor else {
                return Unmanaged.passUnretained(event)
            }

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            // Skip events posted by our own ActionExecutor
            if event.getIntegerValueField(.eventSourceUserData) == 0x475454 {
                return Unmanaged.passUnretained(event)
            }

            guard type == .otherMouseDown || type == .otherMouseUp else {
                return Unmanaged.passUnretained(event)
            }

            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            guard let button = MouseButton.from(cgButton: buttonNumber) else {
                return Unmanaged.passUnretained(event)
            }

            if type == .otherMouseUp {
                return monitor.suppressedButtons.remove(buttonNumber) != nil ? nil : Unmanaged.passUnretained(event)
            }
            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let toFire = TriggerResolver.resolve(
                monitor.registeredTriggers,
                payload: button,
                frontBundleID: frontBundleID,
                payloadOf: { $0.button },
                appBundleIDOf: { $0.appBundleID }, modifiers: UInt(event.flags.rawValue), requiredModifiersOf: { $0.requiredModifiers }, groups: monitor.activationGroups, activationGroupIDOf: { $0.activationGroupID }
            )

            guard !toFire.isEmpty else {
                return Unmanaged.passUnretained(event)
            }

            let globalEnabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true
            guard globalEnabled else {
                return Unmanaged.passUnretained(event)
            }

            // Only fire actions on mouseDown (not on mouseUp)
            if type == .otherMouseDown {
                DispatchQueue.main.async {
                    for trigger in toFire {
                        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions, isHeld: { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32(buttonNumber))!) })
                        LiveTouchState.shared.flashTrigger(trigger.id)
                        NotificationCenter.default.post(name: .gestureDidFire, object: nil, userInfo: ["name": trigger.button.rawValue, "actions": trigger.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → ")])
                    }
                }
            }

            // Suppress the click (both down and up) if any matched trigger has suppressClick enabled
            let shouldSuppress = toFire.contains { $0.suppressClick }
            if shouldSuppress {
                monitor.suppressedButtons.insert(buttonNumber)
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        // A tap that never suppresses anything only needs to observe. A
        // listen-only tap is handed a copy it cannot modify, so it stays off
        // the input hot path and out of the tapDisabledByTimeout failure mode
        // where a slow callback makes macOS disable the tap and delay events
        // system-wide. Escalate to an active tap only when a trigger actually
        // needs to swallow the click.
        let needsSuppression = registeredTriggers.contains { $0.suppressClick }
        let tapOptions: CGEventTapOptions = needsSuppression ? .defaultTap : .listenOnly

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: tapOptions,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("[MouseButtonMonitor] Registered %d triggers with a %@ event tap",
                  registeredTriggers.count, needsSuppression ? "active" : "listen-only")
        } else {
            NSLog("[MouseButtonMonitor] Failed to create CGEventTap — check Accessibility permissions")
        }
    }

    func unregisterAll() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if MouseButtonMonitor.activeMonitor === self {
            MouseButtonMonitor.activeMonitor = nil
        }
        registeredTriggers.removeAll()
        suppressedButtons.removeAll()
    }

    deinit {
        unregisterAll()
    }
}
