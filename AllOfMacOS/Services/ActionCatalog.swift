import Foundation

/// Human-readable metadata for every action: a one-line description for the
/// action picker, a parameter hint, and the safety classification used by the
/// executor and the editor. Kept apart from the enum so the wording and the
/// validation live in one reviewable place.
extension ActionType {
    /// One line shown under the action's name in the picker and in the editor.
    var description: String {
        switch self {
        case .matchScreenImage: return "Finds a local image template on the pointer display and optionally clicks its center."
        case .pressAccessibilityElement: return "Finds a UI element by exact title or accessibility identifier, and presses it."
        case .setAccessibilityValue: return "Sets the value of a UI element identified by title or accessibility identifier."
        case .runSwiftScript: return "Runs Swift through xcrun (requires Apple command line tools) and can capture its output."
        case .showFloatingMenu: return "Opens a saved native menu with action buttons, clocks, and variable widgets."
        case .hideFloatingMenus: return "Closes all floating menus."
        case .editFloatingMenus: return "Opens the menu and widget editor, with native JSON import and export."
        // Workflow
        case .actionGroup: return "Runs a list of actions in order, as one step."
        case .ifElse: return "Runs one list of actions when a condition holds, another when it does not."
        case .setVariable: return "Stores a text value in a named variable for later conditions."
        case .wait: return "Pauses the sequence for a number of milliseconds."
        case .triggerNamedTrigger: return "Runs the actions of a trigger that has a matching Named Trigger name."
        case .showHUD: return "Shows a short message on screen."
        case .showCheatSheet: return "Shows or hides the list of triggers that apply right now."
        case .showPinnedWindowPicker: return "Choose a live window to keep above other apps."
        case .selectWindowToPin: return "Point at a window and click to pin or unpin it."
        case .togglePinFrontWindow: return "Toggle always on top for the front window."
        case .togglePinWindowUnderCursor: return "Toggle always on top for the window under the pointer."
        case .unpinAllWindows: return "Remove live window pins without closing their source windows."
        // Window management
        case .maximizeWindow: return "Fills the visible area of the window's display."
        case .minimizeWindow: return "Minimizes the focused window to the Dock."
        case .snapWindowLeft: return "Snaps the window to the left half of the display."
        case .snapWindowRight: return "Snaps the window to the right half of the display."
        case .snapWindowTopHalf: return "Snaps the window to the top half of the display."
        case .snapWindowBottomHalf: return "Snaps the window to the bottom half of the display."
        case .snapWindowTopLeft: return "Snaps the window to the top-left quarter."
        case .snapWindowTopRight: return "Snaps the window to the top-right quarter."
        case .snapWindowBottomLeft: return "Snaps the window to the bottom-left quarter."
        case .snapWindowBottomRight: return "Snaps the window to the bottom-right quarter."
        case .centerWindow: return "Centers the window on its display without resizing it."
        case .moveWindowNextMonitor: return "Moves the window to the next display."
        case .moveWindowPreviousMonitor: return "Moves the window to the previous display."
        case .moveWindowNextMonitorAndMaximize: return "Moves the window to the next display and maximizes it there."
        case .restoreWindowSize: return "Puts the window back to the size and position it had before AOM moved it."
        case .undoWindowPlacement: return "Reverts the last window placement AOM made."
        case .saveWindowLayout: return "Saves where every open window is, under a name."
        case .restoreWindowLayout: return "Puts windows back where a saved layout had them."
        case .customSnapWindow: return "Snaps the window to an area you define as percentages of the display."
        case .snapWindowLeftThird: return "Snaps the window to the left third of the display."
        case .snapWindowCenterThird: return "Snaps the window to the center third of the display."
        case .snapWindowRightThird: return "Snaps the window to the right third of the display."
        case .snapWindowLeftTwoThirds: return "Snaps the window to the left two thirds of the display."
        case .snapWindowRightTwoThirds: return "Snaps the window to the right two thirds of the display."
        case .snapWindowTopLeftSixth: return "Snaps the window to the top-left sixth (3×2 grid)."
        case .snapWindowTopCenterSixth: return "Snaps the window to the top-center sixth (3×2 grid)."
        case .snapWindowTopRightSixth: return "Snaps the window to the top-right sixth (3×2 grid)."
        case .snapWindowBottomLeftSixth: return "Snaps the window to the bottom-left sixth (3×2 grid)."
        case .snapWindowBottomCenterSixth: return "Snaps the window to the bottom-center sixth (3×2 grid)."
        case .snapWindowBottomRightSixth: return "Snaps the window to the bottom-right sixth (3×2 grid)."
        case .moveWindowLeft: return "Nudges the window left by a tenth of the display."
        case .moveWindowRight: return "Nudges the window right by a tenth of the display."
        case .moveWindowUp: return "Nudges the window up by a tenth of the display."
        case .moveWindowDown: return "Nudges the window down by a tenth of the display."
        case .bringWindowToFront: return "Raises the window above other windows of the same app."
        case .showWindowSwitcher: return "Opens a thumbnail switcher for every open window; arrows move, Return activates."
        case .showPinnedWindowPicker: return "Choose a live window to keep above other windows."
        case .selectWindowToPin: return "Point at a window and click to pin or unpin it. Escape cancels."
        case .togglePinFrontWindow: return "Keep the front window on top, or remove its pin."
        case .togglePinWindowUnderCursor: return "Keep the window under the pointer on top, or remove its pin."
        case .unpinAllWindows: return "Remove all live window pins without closing their source windows."
        case .maximizeWindowUnderCursor: return "Maximizes the window under the pointer, not the focused one."
        case .minimizeWindowUnderCursor: return "Minimizes the window under the pointer."
        case .closeWindowUnderCursor: return "Closes the window under the pointer."
        case .moveResizeWindow: return "Moves and resizes a window to an exact size and position, in percent or pixels."
        case .toggleFullscreenWindow: return "Enters or leaves native full screen for the window."
        case .zoomWindow: return "Presses the window's green Zoom button."
        case .closeWindow: return "Presses the window's red Close button."
        case .startMovingWindow: return "The window under the pointer follows the pointer until you stop or click."
        case .stopMovingWindow: return "Ends a move started with Start Moving Window."
        case .toggleMovingWindow: return "Starts moving the window under the pointer, or stops if already moving."
        case .startResizingWindow: return "The window under the pointer is resized by pointer movement until you stop or click."
        case .stopResizingWindow: return "Ends a resize started with Start Resizing Window."
        case .toggleResizingWindow: return "Starts resizing the window under the pointer, or stops if already resizing."
        // Spaces & Mission Control
        case .switchSpaceLeft: return "Switches to the Space on the left (needs the ⌃← system shortcut enabled)."
        case .switchSpaceRight: return "Switches to the Space on the right (needs the ⌃→ system shortcut enabled)."
        case .switchToDesktop: return "Switches to Desktop 1–9 (needs the ⌃1…⌃9 system shortcuts enabled)."
        case .moveWindowToPreviousSpace: return "Carries the focused window to the Space on the left."
        case .moveWindowToNextSpace: return "Carries the focused window to the Space on the right."
        case .missionControl: return "Opens Mission Control."
        case .appExpose: return "Shows all windows of the frontmost app (needs the ⌃↓ system shortcut enabled)."
        case .launchpad: return "Opens Launchpad (Apps on recent macOS)."
        case .showDesktop: return "Slides windows aside to reveal the desktop (uses the system Show Desktop key)."
        // Mouse
        case .leftClick: return "Clicks the left button at the pointer."
        case .rightClick: return "Right-clicks at the pointer."
        case .middleClick: return "Middle-clicks at the pointer."
        case .doubleLeftClick: return "Double-clicks the left button at the pointer."
        case .commandLeftClick: return "Left-clicks with ⌘ held."
        case .ctrlLeftClick: return "Left-clicks with ⌃ held (a secondary click in most apps)."
        case .optionLeftClick: return "Left-clicks with ⌥ held."
        case .shiftLeftClick: return "Left-clicks with ⇧ held (extends a selection)."
        case .cmdDoubleClick: return "Double-clicks with ⌘ held."
        case .customClick: return "Clicks any mouse button, any number of times, with any modifiers."
        case .moveMouseToPosition: return "Moves the pointer to a position on its display."
        case .moveMouseRelative: return "Moves the pointer by a number of points from where it is."
        case .saveMousePosition: return "Remembers where the pointer is."
        case .restoreMousePosition: return "Moves the pointer back to the remembered position."
        case .startDrag: return "Presses and holds the left button."
        case .stopDrag: return "Releases the left button."
        case .scrollUp: return "Scrolls up by a number of lines."
        case .scrollDown: return "Scrolls down by a number of lines."
        case .scrollLeft: return "Scrolls left by a number of lines."
        case .scrollRight: return "Scrolls right by a number of lines."
        case .scrollCustom: return "Scrolls in any direction by lines or pixels, instantly or smoothly over time."
        // Keyboard
        case .sendKeyStroke: return "Sends a recorded keyboard shortcut."
        case .typeText: return "Types text into the focused app."
        case .pasteString: return "Pastes a string via the clipboard, then puts your previous clipboard back."
        case .pressFunctionKey: return "Presses F1–F20."
        case .modifierKeyDown: return "Holds a modifier key (⌘ ⌥ ⇧ ⌃ fn) down until released."
        case .modifierKeyUp: return "Releases a modifier key held by Hold Modifier Key Down."
        case .allModifiersUp: return "Releases every modifier key AOM is holding."
        case .toggleCapsLock: return "Turns Caps Lock on or off."
        case .pressPageUp: return "Presses Page Up."
        case .pressPageDown: return "Presses Page Down."
        case .pressHome: return "Presses Home."
        case .pressEnd: return "Presses End."
        case .pressArrowKey: return "Presses an arrow key one or more times."
        case .pressContextMenuKey: return "Presses the Context Menu key."
        // Application control
        case .activateApplication: return "Brings an app to the front, launching it if needed."
        case .launchApplication: return "Opens an app."
        case .quitApplication: return "Asks an app to quit."
        case .forceQuitApplication: return "Kills an app immediately (the frontmost one when none is named)."
        case .hideApplication: return "Hides an app."
        case .toggleApplication: return "Hides the app if it is visible, shows it otherwise."
        case .hideOtherApps: return "Hides every app except the frontmost one."
        // System
        case .sleepComputer: return "Puts the Mac to sleep."
        case .toggleKeepAwake: return "Keeps the Mac awake until it is toggled off or the optional minutes run out."
        case .setAppVolume: return "Sets one app’s volume from 0–200%, preserving its mute setting."
        case .toggleAppMute: return "Mutes or unmutes the selected app, or the frontmost app."
        case .setAppAudioOutput: return "Routes one application to a selected audio output."
        case .toggleMuteAllApps: return "Mutes all applications; toggling again restores their previous mute states."
        case .muteFrontAppAudio: return "Toggles a per-app mute on the frontmost app's audio (macOS 14.2+)."
        case .showAudioMixer: return "Opens the per-app audio mixer panel (macOS 14.2+)."
        case .lockScreen: return "Locks the screen."
        case .toggleDarkMode: return "Switches AOM between light and dark appearance."
        case .toggleDoNotDisturb: return "Not implemented; use a script or shortcut instead."
        case .volumeUp: return "Raises the output volume."
        case .volumeDown: return "Lowers the output volume."
        case .brightnessUp: return "Raises the display brightness."
        case .brightnessDown: return "Lowers the display brightness."
        case .setSoundOutput: return "Switches the sound output device."
        case .muteVolume: return "Mutes or unmutes the output."
        case .setVolume: return "Sets the output volume to an exact percentage."
        case .setBrightness: return "Sets the display brightness to an exact percentage."
        case .toggleMuteMicrophone: return "Mutes or unmutes the default microphone."
        case .startScreenSaver: return "Starts the screen saver."
        case .emptyTrash: return "Permanently deletes everything in the Trash (asks first by default)."
        case .sleepDisplay: return "Turns the displays off without sleeping the Mac."
        case .logOut: return "Logs the current user out (asks first by default)."
        case .toggleHiddenFiles: return "Shows or hides hidden files in Finder."
        case .openNotificationCenter: return "Opens Notification Center from the menu bar clock."
        case .openControlCenter: return "Opens Control Center from the menu bar."
        case .startDictation: return "Starts macOS Dictation."
        // Utility
        case .playSoundFile: return "Plays an audio file."
        case .speakText: return "Reads text aloud with the system voice."
        case .showNotification: return "Posts a notification, or an on-screen message if notifications are off."
        case .copyTextToClipboard: return "Puts text on the clipboard."
        case .openFileOrFolder: return "Opens a file or folder with its default app."
        case .revealInFinder: return "Shows a file or folder in Finder."
        // Scripts
        case .runAppleScript: return "Runs an AppleScript in AOM's sandboxed script helper."
        case .runShellScript: return "Runs a shell script in AOM's sandboxed script helper."
        case .openURL: return "Opens a web address or other URL."
        case .runAppleShortcut: return "Runs a shortcut from the Shortcuts app by name."
        case .runJavaScript: return "Runs JavaScript for Automation (JXA) in AOM's sandboxed script helper."
        // Media
        case .playPause: return "Plays or pauses the current media."
        case .nextTrack: return "Skips to the next track."
        case .previousTrack: return "Goes back to the previous track."
        // Clipboard
        case .showClipboardHistory: return "Opens the clipboard history."
        case .showPasteStack: return "Opens the paste stack."
        case .pasteNextClipboardItem: return "Pastes the next item of the paste stack."
        case .toggleClipboardRecording: return "Pauses or resumes clipboard recording."
        // Capture
        case .captureArea, .captureFullscreen, .captureWindow, .captureWindowUnderCursor, .recordScreen,
             .capturePreviousArea, .captureScrolling, .captureText, .captureTextWithLineBreaks,
             .captureTextWithoutLineBreaks, .captureAllDisplays, .captureSelfTimer, .annotateLastCapture,
             .pinLastCapture, .copyLastCapture, .saveLastCapture, .ocrLastCapture, .openCaptureHistory,
             .unpinAllCaptures, .toggleCaptureOverlay:
            return ActionType.describeCaptureAction(self)
        // Control flow
        case .repeatLoop: return "Runs the actions inside it N times; Break Loop leaves early."
        case .breakLoop: return "Leaves the nearest Repeat N Times loop; outside a loop, ends the sequence."
        case .cycleActions: return "Each run executes the next inner action, wrapping around at the end."
        case .toggleOnOff: return "Alternates between two lists of actions on every run."
        case .increaseVariable: return "Adds a number to a variable (starts from 0 if it is empty)."
        case .decreaseVariable: return "Subtracts a number from a variable (starts from 0 if it is empty)."
        case .askForInput: return "Asks you to type something and stores it in a variable; Cancel stops the sequence."
        case .debounce: return "Waits, and only the last run within that time continues."
        case .stopAllSequences: return "Cancels every action sequence that is currently running."
        case .enableTrigger: return "Turns a configured trigger on, found by name or UUID."
        case .disableTrigger: return "Turns a configured trigger off, found by name or UUID."
        case .waitFor: return "Pauses until an app launches or comes forward, a file appears or the clipboard changes."
        case .disableTriggersForSeconds: return "Turns every trigger off for a while, then back on by itself."
        case .resumeTriggers: return "Ends a pause started by Disable Triggers For X Seconds."
        }
    }

    /// What the action needs configured, for the picker's detail line.
    var parameterHint: String {
        switch self {
        case .moveResizeWindow: return "Unit, anchor, X/Y, width/height, display, window"
        case .switchToDesktop: return "Desktop number 1–9"
        case .customClick: return "Button, click count, modifiers"
        case .scrollCustom: return "Direction, amount, unit, duration"
        case .moveMouseRelative: return "Δx, Δy in points"
        case .pasteString, .typeText, .copyTextToClipboard, .speakText: return "Text"
        case .pressFunctionKey: return "F1–F20"
        case .modifierKeyDown, .modifierKeyUp: return "Modifier key"
        case .pressArrowKey: return "Direction, repeat count"
        case .setVolume, .setBrightness: return "0–100 %"
        case .playSoundFile, .openFileOrFolder, .revealInFinder: return "File path"
        case .showNotification: return "Title, message"
        case .runAppleShortcut: return "Shortcut name"
        case .runJavaScript, .runAppleScript, .runShellScript, .runSwiftScript: return "Script, timeout, output variable"
        case .showFloatingMenu: return "Saved menu name or UUID"
        case .emptyTrash, .logOut: return "Confirmation (on by default)"
        case .repeatLoop: return "Count 1–100, inner actions"
        case .cycleActions: return "Inner actions, optional reset time"
        case .toggleOnOff: return "On list, Off list"
        case .increaseVariable, .decreaseVariable: return "Variable, step"
        case .askForInput: return "Prompt, variable"
        case .debounce: return "Delay in ms (use Restart policy)"
        case .enableTrigger, .disableTrigger: return "Trigger name or UUID"
        case .waitFor: return "Condition, target, timeout"
        case .disableTriggersForSeconds: return "Seconds"
        case .startMovingWindow, .toggleMovingWindow, .startResizingWindow, .toggleResizingWindow: return "Safety timeout"
        case .ifElse: return "Condition, then / else actions"
        case .setVariable: return "Variable, value"
        case .wait: return "Milliseconds"
        case .sendKeyStroke: return "Recorded shortcut"
        case .customSnapWindow: return "Area, display"
        default: return ""
        }
    }

    /// Actions that can lose data or end the session. They require confirmation
    /// unless `requiresConfirmation == false` is set explicitly.
    var isDestructive: Bool { self == .emptyTrash || self == .logOut || self == .forceQuitApplication }

    /// Whether this action needs an accessible focused window up front. The
    /// executor refuses to run window actions without one so a failed capture is
    /// reported rather than silently doing nothing.
    var needsFocusedWindow: Bool {
        guard category == .windowManagement else { return false }
        switch self {
        case .showPinnedWindowPicker, .selectWindowToPin, .togglePinWindowUnderCursor, .unpinAllWindows:
            return false
        case .undoWindowPlacement, .saveWindowLayout, .restoreWindowLayout,
             .startMovingWindow, .stopMovingWindow, .toggleMovingWindow,
             .startResizingWindow, .stopResizingWindow, .toggleResizingWindow:
            return false
        default: return true
        }
    }

    /// The macOS "symbolic hotkey" an action posts, when it relies on a system
    /// keyboard shortcut. `desktop` is only used by Switch to Desktop.
    func requiredHotKeyID(desktop: Int = 1) -> Int? {
        switch self {
        case .switchSpaceLeft, .moveWindowToPreviousSpace: return SymbolicHotKeys.spaceLeft
        case .switchSpaceRight, .moveWindowToNextSpace: return SymbolicHotKeys.spaceRight
        case .switchToDesktop: return SymbolicHotKeys.desktop(min(9, max(1, desktop)))
        case .appExpose: return SymbolicHotKeys.appWindows
        case .showDesktop: return SymbolicHotKeys.showDesktop
        default: return nil
        }
    }

    /// Parameters a freshly added step starts with, so what the editor shows is
    /// exactly what the executor will use (nothing is "defaulted" only on screen).
    var defaultParameters: ActionParameters {
        var p = ActionParameters()
        switch self {
        case .setAppVolume: p.levelPercent = 100
        case .setVolume: p.levelPercent = 50
        case .setBrightness: p.levelPercent = 70
        case .moveResizeWindow:
            p.moveResizeUnit = "percent"; p.moveResizeAnchor = "center"; p.moveResizeX = 0; p.moveResizeY = 0
            p.moveResizeWidth = 60; p.moveResizeHeight = 60; p.windowTarget = "focused"
        case .zoomWindow, .closeWindow, .toggleFullscreenWindow: p.windowTarget = "focused"
        case .startMovingWindow, .toggleMovingWindow, .startResizingWindow, .toggleResizingWindow: p.windowDragTimeoutSeconds = 60
        case .switchToDesktop: p.desktopNumber = 1
        case .customClick: p.clickButton = 0; p.clickCount = 1
        case .scrollCustom: p.scrollDirection = "down"; p.scrollAmount = 3; p.scrollUnit = "lines"; p.scrollDurationMs = 0
        case .moveMouseRelative: p.mouseDeltaX = 50; p.mouseDeltaY = 0
        case .pressFunctionKey: p.functionKeyNumber = 1
        case .modifierKeyDown, .modifierKeyUp: p.modifierKey = "command"
        case .pressArrowKey: p.arrowDirection = "down"; p.keyRepeatCount = 1
        case .playSoundFile: p.levelPercent = 100
        case .speakText: p.speechRate = 0.5
        case .showNotification: p.notificationTitle = "AOM"
        case .repeatLoop: p.loopCount = 2
        case .increaseVariable, .decreaseVariable: p.variableName = "counter"; p.variableStep = 1
        case .askForInput: p.inputPrompt = "Enter a value"; p.variableName = "answer"
        case .debounce: p.waitMs = 500
        case .waitFor: p.waitCondition = "appRunning"; p.waitTimeoutMs = 30_000
        case .disableTriggersForSeconds: p.pauseSeconds = 5
        case .runAppleShortcut: p.scriptTimeoutSeconds = 60
        case .runJavaScript, .runSwiftScript: p.scriptTimeoutSeconds = 30
        case .matchScreenImage: p.imageMatchThreshold = 0.98; p.imageMatchClick = false
        case .setVariable: p.variableName = "state"; p.variableValue = "on"
        case .ifElse: p.variableName = "state"; p.conditionValue = "on"
        default: break
        }
        return p
    }

    /// Search text for the picker: name, category, description and hint.
    var searchText: String { [rawValue, category.rawValue, description, parameterHint].joined(separator: " ") }
}

/// Parameter checks for the actions added in 1.1.4. `ActionTree.problem`
/// calls this so the editor, the importer and the executor agree on what is valid.
enum ActionParameterValidation {
    static let anchors = ["topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom", "bottomRight"]
    static let directions = ["up", "down", "left", "right"]
    static let modifierNames = ["command", "option", "shift", "control", "fn",
                                "rightCommand", "rightOption", "rightShift", "rightControl"]
    static let waitConditions = ["appRunning", "appFrontmost", "fileExists", "clipboardChange"]

    static func problem(for action: TriggerAction) -> String? {
        let p = action.parameters
        if let name = p.scriptResultVariable, !name.isEmpty,
           name.count > 55 || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
            return "Output variable must use 1–55 ASCII letters, digits, or underscores."
        }
        func finite(_ values: [Double?]) -> Bool { values.compactMap { $0 }.allSatisfy { $0.isFinite } }
        switch action.actionType {
        case .toggleKeepAwake:
            if let minutes = p.keepAwakeMinutes, !minutes.isFinite || !(1...1440).contains(minutes) { return "Duration must be 1–1440 minutes." }
        case .setAppVolume:
            if let level = p.levelPercent, !level.isFinite || !(0...200).contains(level) { return "App volume must be 0–200%." }
        case .matchScreenImage:
            if TriggerSystemPaths.normalized(p.imageTemplatePath ?? "") == nil { return "Choose an absolute local template image path." }
            if let threshold = p.imageMatchThreshold, !threshold.isFinite || !(0.8...1).contains(threshold) { return "Image similarity must be 0.8–1.0." }
            if let name = p.imageMatchVariable, !name.isEmpty,
               name.count > 58 || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                return "Image result variable must use up to 58 ASCII letters, digits, or underscores."
            }
        case .pressAccessibilityElement, .setAccessibilityValue:
            if (p.uiElementTitle ?? "").isEmpty && (p.uiElementIdentifier ?? "").isEmpty { return "Choose an exact UI title or accessibility identifier." }

        case .moveResizeWindow:
            guard finite([p.moveResizeX, p.moveResizeY, p.moveResizeWidth, p.moveResizeHeight]) else { return "Move / Resize values must be numbers." }
            if let unit = p.moveResizeUnit, !["percent", "pixels"].contains(unit) { return "Unit must be percent or pixels." }
            if let anchor = p.moveResizeAnchor, !anchors.contains(anchor) { return "Unknown anchor." }
            if let w = p.moveResizeWidth, w <= 0 { return "Width must be greater than zero." }
            if let h = p.moveResizeHeight, h <= 0 { return "Height must be greater than zero." }
            if (p.moveResizeUnit ?? "percent") == "percent" {
                if let w = p.moveResizeWidth, w > 100 { return "Width cannot exceed 100 %." }
                if let h = p.moveResizeHeight, h > 100 { return "Height cannot exceed 100 %." }
            }
            if let target = p.windowTarget, !["focused", "underCursor"].contains(target) { return "Window must be focused or under cursor." }
            if let display = p.snapDisplay, !["current", "primary", "next", "pointer"].contains(display) { return "Unknown display." }
        case .zoomWindow, .closeWindow, .toggleFullscreenWindow:
            if let target = p.windowTarget, !["focused", "underCursor"].contains(target) { return "Window must be focused or under cursor." }
        case .startMovingWindow, .toggleMovingWindow, .startResizingWindow, .toggleResizingWindow:
            if let t = p.windowDragTimeoutSeconds, !t.isFinite || !(1...600).contains(t) { return "Safety timeout must be 1–600 seconds." }
        case .switchToDesktop:
            if let n = p.desktopNumber, !(1...9).contains(n) { return "Desktop number must be 1–9." }
        case .customClick:
            if let b = p.clickButton, !(0...31).contains(b) { return "Mouse button must be 0–31." }
            if let c = p.clickCount, !(1...3).contains(c) { return "Click count must be 1–3." }
        case .scrollCustom:
            if let d = p.scrollDirection, !directions.contains(d) { return "Unknown scroll direction." }
            if let u = p.scrollUnit, !["lines", "pixels"].contains(u) { return "Scroll unit must be lines or pixels." }
            if let a = p.scrollAmount, a == 0 || !(-10_000...10_000).contains(a) { return "Scroll amount must be 1–10,000." }
            if let ms = p.scrollDurationMs, !(0...10_000).contains(ms) { return "Scroll duration must be 0–10,000 ms." }
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            if let a = p.scrollAmount, a == 0 || !(-10_000...10_000).contains(a) { return "Scroll amount must be 1–10,000." }
        case .moveMouseRelative:
            guard finite([p.mouseDeltaX, p.mouseDeltaY]) else { return "Mouse offsets must be numbers." }
            if abs(p.mouseDeltaX ?? 0) > 10_000 || abs(p.mouseDeltaY ?? 0) > 10_000 { return "Mouse offset is too large." }
        case .pressFunctionKey:
            if let n = p.functionKeyNumber, !(1...20).contains(n) { return "Function key must be F1–F20." }
        case .modifierKeyDown, .modifierKeyUp:
            if let k = p.modifierKey, !modifierNames.contains(k) { return "Unknown modifier key." }
        case .pressArrowKey:
            if let d = p.arrowDirection, !directions.contains(d) { return "Unknown arrow direction." }
            if let n = p.keyRepeatCount, !(1...100).contains(n) { return "Key repeat must be 1–100." }
        case .setVolume, .setBrightness, .playSoundFile:
            if let l = p.levelPercent, !l.isFinite || !(0...100).contains(l) { return "Level must be 0–100 %." }
        case .speakText:
            if let r = p.speechRate, !r.isFinite || !(0...1).contains(r) { return "Speech rate must be 0–1." }
        case .increaseVariable, .decreaseVariable:
            if let s = p.variableStep, !s.isFinite { return "Step must be a number." }
        case .cycleActions:
            if let r = p.cycleResetSeconds, !r.isFinite || !(0...86_400).contains(r) { return "Reset time must be 0–86,400 seconds." }
        case .waitFor:
            if let c = p.waitCondition, !waitConditions.contains(c) { return "Unknown wait condition." }
            if let t = p.waitTimeoutMs, !(0...600_000).contains(t) { return "Wait timeout must be 0–600,000 ms." }
        case .disableTriggersForSeconds:
            if let s = p.pauseSeconds, !s.isFinite || !(0.1...86_400).contains(s) { return "Pause must be 0.1–86,400 seconds." }
        case .debounce:
            if let w = p.waitMs, !(0...60_000).contains(w) { return "Debounce must be 0–60,000 ms." }
        case .runJavaScript, .runAppleShortcut, .runSwiftScript, .runShellScript, .runAppleScript:
            if let timeout = p.scriptTimeoutSeconds, !timeout.isFinite || !(0.1...120).contains(timeout) { return "Timeout must be 0.1–120 seconds." }
        default: break
        }
        return nil
    }
}
