import AppKit
import ApplicationServices

/// Acts on the chosen target once the overlay is gone.
enum ClickHintsPerformer {
    /// One way to act, tried in order until one works.
    enum Step: Equatable {
        /// AXPress, AXConfirm, AXPick or AXShowMenu.
        case action(String)
        /// AXFocused = true (text fields, sliders).
        case focus
        /// A click at the centre of the visible part, through the session
        /// tap with AOM's own tag (`SyntheticInput`).
        case click(right: Bool, command: Bool)
        /// Moves the pointer there (a mouse-moved event, so hover updates).
        case movePointer
    }

    /// Roles where acting means typing next: they get the focus.
    static let focusRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                          kAXComboBoxRole as String, kAXSliderRole as String]

    /// The steps for a click kind on an element with these actions.
    static func plan(kind: ClickHintsClickKind, role: String, actions: [String]) -> [Step] {
        switch kind {
        case .movePointer:
            return [.movePointer]
        case .commandClick:
            // An Accessibility action can't carry ⌘, so this is always a click.
            return [.click(right: false, command: true)]
        case .rightClick:
            return actions.contains(ClickHintsAX.showMenu)
                ? [.action(ClickHintsAX.showMenu), .click(right: true, command: false)]
                : [.click(right: true, command: false)]
        case .press:
            if focusRoles.contains(role) { return [.focus, .click(right: false, command: false)] }
            if let action = ClickHintsAX.activationActions.first(where: actions.contains) {
                return [.action(action), .click(right: false, command: false)]
            }
            return [.click(right: false, command: false)]
        }
    }

    enum Outcome: Equatable {
        case done(Step)
        case failed(String)
    }

    /// Runs the plan off the main thread; `completion` comes back on main.
    static func perform(_ target: ClickHintsTarget, kind: ClickHintsClickKind,
                        completion: @escaping @MainActor (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let outcome = run(target, kind: kind)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }

    private static func run(_ target: ClickHintsTarget, kind: ClickHintsClickKind) -> Outcome {
        var actions = target.actions ?? []
        if target.actions == nil, let element = target.element {
            AXUIElementSetMessagingTimeout(element, 0.3)
            var names: CFArray?
            if AXUIElementCopyActionNames(element, &names) == .success { actions = (names as? [String]) ?? [] }
        }
        let point = target.clickPoint
        for step in plan(kind: kind, role: target.role, actions: actions) {
            switch step {
            case .action(let name):
                guard let element = target.element else { continue }
                AXUIElementSetMessagingTimeout(element, 0.5)
                if acted(AXUIElementPerformAction(element, name as CFString)) { return .done(step) }
            case .focus:
                guard let element = target.element else { continue }
                AXUIElementSetMessagingTimeout(element, 0.5)
                if acted(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)) {
                    return .done(step)
                }
            case .click(let right, let command):
                if click(at: point, right: right, command: command) { return .done(step) }
                return .failed("macOS didn't accept the click from All of MacOS")
            case .movePointer:
                if movePointer(to: point) { return .done(step) }
                return .failed("macOS didn't accept the pointer move from All of MacOS")
            }
        }
        return .failed("The app didn't respond")
    }

    /// Success, or a timeout: an app that is busy acting (a button that opens
    /// a dialog answers late) must not get a second, synthetic click.
    static func acted(_ error: AXError) -> Bool {
        error == .success || error == .cannotComplete
    }

    /// Posts mouse-moved, down and up at `point` (Accessibility coordinates
    /// are the event coordinates). Both halves are always posted so a button
    /// is never left held.
    static func click(at point: CGPoint, right: Bool, command: Bool) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = right ? .right : .left
        let flags: CGEventFlags = command ? .maskCommand : []
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button),
              let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: button) else { return false }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        let moved = SyntheticInput.post(move)
        usleep(12_000)
        let pressed = SyntheticInput.post(down)
        usleep(8_000)
        let released = SyntheticInput.post(up)
        return moved && pressed && released
    }

    static func movePointer(to point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        return SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                           mouseCursorPosition: point, mouseButton: .left))
    }
}
