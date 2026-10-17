import Foundation

enum ActionCategory: String, CaseIterable, Identifiable, Codable {
    case workflow = "Workflow"
    case windowManagement = "Window Management"
    case keyboardActions = "Keyboard"
    case applicationControl = "Application Control"
    case systemActions = "System Actions"
    case scriptExecution = "Script Execution"
    case mediaControls = "Media Controls"
    case mouseActions = "Mouse & Trackpad"
    case screenCapture = "Screen Capture"
    case clipboard = "Clipboard"
    // Added in 1.1.4. Appended so persisted/ordered lists of categories keep their meaning.
    case spacesMissionControl = "Spaces & Mission Control"
    case controlFlow = "Control Flow"
    case utilityActions = "Utility"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .workflow: return "list.bullet.indent"
        case .windowManagement: return "macwindow.on.rectangle"
        case .keyboardActions: return "keyboard"
        case .applicationControl: return "app.badge"
        case .systemActions: return "gearshape"
        case .scriptExecution: return "terminal"
        case .mediaControls: return "play.circle"
        case .mouseActions: return "computermouse"
        case .screenCapture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .spacesMissionControl: return "rectangle.3.group"
        case .controlFlow: return "arrow.triangle.2.circlepath"
        case .utilityActions: return "wrench.and.screwdriver"
        }
    }
}

enum ActionType: String, Codable, Identifiable, CaseIterable {
    case actionGroup = "Action Group"
    case ifElse = "If / Else"
    case setVariable = "Set Variable"
    case wait = "Wait"
    case triggerNamedTrigger = "Run Named Trigger"
    case showHUD = "Show HUD"
    case showCheatSheet = "Show Cheat Sheet"

    // Window Management
    case maximizeWindow = "Maximize Window"
    case minimizeWindow = "Minimize Window"
    case snapWindowLeft = "Snap Window Left Half"
    case snapWindowRight = "Snap Window Right Half"
    case snapWindowTopLeft = "Snap Window Top Left"
    case snapWindowTopRight = "Snap Window Top Right"
    case snapWindowBottomLeft = "Snap Window Bottom Left"
    case snapWindowBottomRight = "Snap Window Bottom Right"
    case centerWindow = "Center Window"
    case moveWindowNextMonitor = "Move Window to Next Monitor"
    case moveWindowPreviousMonitor = "Move Window to Previous Monitor"
    case moveWindowNextMonitorAndMaximize = "Move to Next Monitor and Maximize"
    case restoreWindowSize = "Restore Window Size"
    case undoWindowPlacement = "Undo Last Window Placement"
    case saveWindowLayout = "Save Window Layout"
    case restoreWindowLayout = "Restore Window Layout"
    case customSnapWindow = "Snap to Custom Area"
    case snapWindowLeftThird = "Snap Window Left Third"
    case snapWindowCenterThird = "Snap Window Center Third"
    case snapWindowRightThird = "Snap Window Right Third"
    case snapWindowLeftTwoThirds = "Snap Window Left Two Thirds"
    case snapWindowRightTwoThirds = "Snap Window Right Two Thirds"
    case snapWindowTopLeftSixth = "Snap Window Top Left Sixth"
    case snapWindowTopCenterSixth = "Snap Window Top Center Sixth"
    case snapWindowTopRightSixth = "Snap Window Top Right Sixth"
    case snapWindowBottomLeftSixth = "Snap Window Bottom Left Sixth"
    case snapWindowBottomCenterSixth = "Snap Window Bottom Center Sixth"
    case snapWindowBottomRightSixth = "Snap Window Bottom Right Sixth"
    case moveWindowLeft = "Move Window Left"
    case moveWindowRight = "Move Window Right"
    case moveWindowUp = "Move Window Up"
    case moveWindowDown = "Move Window Down"
    case bringWindowToFront = "Bring Window to Front"
    case maximizeWindowUnderCursor = "Maximize Window Under Cursor"
    case minimizeWindowUnderCursor = "Minimize Window Under Cursor"
    case closeWindowUnderCursor = "Close Window Under Cursor"

    // Mouse & Trackpad
    case leftClick = "Left Click"
    case rightClick = "Right Click"
    case middleClick = "Middle Click"
    case doubleLeftClick = "Double Left Click"
    case commandLeftClick = "Command + Left Click"
    case moveMouseToPosition = "Move Mouse To Position"
    case saveMousePosition = "Save Current Mouse Position"
    case restoreMousePosition = "Restore Saved Mouse Position"
    case startDrag = "Start Drag"
    case stopDrag = "Stop Drag"
    case scrollUp = "Scroll Up"
    case scrollDown = "Scroll Down"
    case scrollLeft = "Scroll Left"
    case scrollRight = "Scroll Right"

    // Keyboard Actions
    case sendKeyStroke = "Send Keyboard Shortcut"
    case typeText = "Type Text"

    // Application Control
    case activateApplication = "Activate Application"
    case launchApplication = "Launch Application"
    case quitApplication = "Quit Application"
    case forceQuitApplication = "Force Quit Application"
    case hideApplication = "Hide Application"
    case toggleApplication = "Toggle Application"

    // System Actions
    case sleepComputer = "Sleep Computer"
    case lockScreen = "Lock Screen"
    case toggleDarkMode = "Toggle Dark Mode"
    case toggleDoNotDisturb = "Toggle Do Not Disturb"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case brightnessUp = "Brightness Up"
    case brightnessDown = "Brightness Down"
    case setSoundOutput = "Set Sound Output"
    case muteVolume = "Mute/Unmute"

    // Script Execution
    case runAppleScript = "Run AppleScript"
    case runShellScript = "Run Shell Script"
    case openURL = "Open URL"

    // Media Controls
    case playPause = "Play/Pause"
    case nextTrack = "Next Track"
    case previousTrack = "Previous Track"

    // Clipboard
    case showClipboardHistory = "Show Clipboard History"
    case showPasteStack = "Show Paste Stack"
    case pasteNextClipboardItem = "Paste Next Clipboard Item"
    case toggleClipboardRecording = "Pause / Resume Clipboard Recording"

    // Screen Capture
    case captureArea = "Capture Area"
    case captureFullscreen = "Capture Fullscreen"
    case captureWindow = "Capture Window"
    case captureWindowUnderCursor = "Capture Window Under Cursor"
    case recordScreen = "Record Screen"
    case capturePreviousArea = "Capture Previous Area"
    case captureScrolling = "Capture Scrolling"
    case captureText = "Capture Text (OCR)"
    case captureTextWithLineBreaks = "Capture Text With Line Breaks"
    case captureTextWithoutLineBreaks = "Capture Text Without Line Breaks"
    case captureAllDisplays = "Capture All Displays"
    case captureSelfTimer = "Capture With Self-Timer"
    case annotateLastCapture = "Annotate Last Capture"
    case pinLastCapture = "Pin Last Capture"
    case copyLastCapture = "Copy Last Capture"
    case saveLastCapture = "Save Last Capture"
    case ocrLastCapture = "Copy Text From Last Capture"
    case openCaptureHistory = "Open Capture History"
    case unpinAllCaptures = "Unpin All Captures"
    case toggleCaptureOverlay = "Toggle Quick Access Overlay"

    // MARK: Added in 1.1.4 (BTT action parity). Raw values are persisted strings.

    // Window Management
    case snapWindowTopHalf = "Snap Window Top Half"
    case snapWindowBottomHalf = "Snap Window Bottom Half"
    case moveResizeWindow = "Move / Resize Window"
    case toggleFullscreenWindow = "Toggle Fullscreen"
    case zoomWindow = "Zoom Window"
    case closeWindow = "Close Window"
    case startMovingWindow = "Start Moving Window"
    case stopMovingWindow = "Stop Moving Window"
    case toggleMovingWindow = "Toggle Moving Window"
    case startResizingWindow = "Start Resizing Window"
    case stopResizingWindow = "Stop Resizing Window"
    case toggleResizingWindow = "Toggle Resizing Window"

    // Spaces & Mission Control
    case switchSpaceLeft = "Switch Space Left"
    case switchSpaceRight = "Switch Space Right"
    case switchToDesktop = "Switch to Desktop"
    case moveWindowToPreviousSpace = "Move Window to Previous Space"
    case moveWindowToNextSpace = "Move Window to Next Space"
    case missionControl = "Mission Control"
    case appExpose = "Application Exposé"
    case launchpad = "Launchpad"
    case showDesktop = "Show Desktop"

    // Application Control
    case hideOtherApps = "Hide Other Apps"

    // Mouse & Trackpad
    case ctrlLeftClick = "Control + Left Click"
    case optionLeftClick = "Option + Left Click"
    case shiftLeftClick = "Shift + Left Click"
    case cmdDoubleClick = "Command + Double Click"
    case customClick = "Custom Click"
    case scrollCustom = "Scroll (Custom)"
    case moveMouseRelative = "Move Mouse Relative"

    // Keyboard
    case pasteString = "Paste String"
    case pressFunctionKey = "Press Function Key"
    case modifierKeyDown = "Hold Modifier Key Down"
    case modifierKeyUp = "Release Modifier Key"
    case allModifiersUp = "Release All Modifier Keys"
    case toggleCapsLock = "Toggle Caps Lock"
    case pressPageUp = "Press Page Up"
    case pressPageDown = "Press Page Down"
    case pressHome = "Press Home"
    case pressEnd = "Press End"
    case pressArrowKey = "Press Arrow Key"
    case pressContextMenuKey = "Press Context Menu Key"

    // System Actions
    case startScreenSaver = "Start Screen Saver"
    case emptyTrash = "Empty Trash"
    case sleepDisplay = "Sleep Display"
    case logOut = "Log Out"
    case toggleHiddenFiles = "Show/Hide Hidden Files"
    case openNotificationCenter = "Open Notification Center"
    case openControlCenter = "Open Control Center"
    case setVolume = "Set Volume"
    case setBrightness = "Set Brightness"
    case toggleMuteMicrophone = "Mute/Unmute Microphone"
    case startDictation = "Start Dictation"

    // Utility
    case playSoundFile = "Play Sound File"
    case speakText = "Speak Text"
    case showNotification = "Show Notification"
    case copyTextToClipboard = "Copy Text to Clipboard"
    case openFileOrFolder = "Open File or Folder"
    case revealInFinder = "Reveal in Finder"

    // Script Execution
    case runAppleShortcut = "Run Apple Shortcut"
    case runJavaScript = "Run JavaScript (JXA)"

    // Control Flow
    case repeatLoop = "Repeat N Times"
    case breakLoop = "Break Loop"
    case cycleActions = "Cycle Through Actions"
    case toggleOnOff = "Toggle On/Off"
    case increaseVariable = "Increase Variable"
    case decreaseVariable = "Decrease Variable"
    case askForInput = "Ask For Input"
    case debounce = "Debounce"
    case stopAllSequences = "Stop All Running Sequences"
    case enableTrigger = "Enable Trigger"
    case disableTrigger = "Disable Trigger"
    case waitFor = "Wait For…"
    case disableTriggersForSeconds = "Disable Triggers For X Seconds"
    case resumeTriggers = "Resume Triggers"

    var id: String { rawValue }

    var category: ActionCategory {
        switch self {
        case .actionGroup, .ifElse, .setVariable, .wait, .triggerNamedTrigger, .showHUD, .showCheatSheet: return .workflow
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight,
             .snapWindowTopLeft, .snapWindowTopRight, .snapWindowBottomLeft,
             .snapWindowBottomRight, .centerWindow, .moveWindowNextMonitor,
             .restoreWindowSize, .moveWindowPreviousMonitor, .moveWindowNextMonitorAndMaximize, .customSnapWindow, .undoWindowPlacement, .saveWindowLayout, .restoreWindowLayout,
             .snapWindowLeftThird, .snapWindowCenterThird, .snapWindowRightThird,
             .snapWindowLeftTwoThirds, .snapWindowRightTwoThirds,
             .snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
             .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth,
             .moveWindowLeft, .moveWindowRight, .moveWindowUp, .moveWindowDown,
             .bringWindowToFront, .maximizeWindowUnderCursor, .minimizeWindowUnderCursor, .closeWindowUnderCursor:
            return .windowManagement
        case .showClipboardHistory, .showPasteStack, .pasteNextClipboardItem, .toggleClipboardRecording: return .clipboard
        case .sendKeyStroke, .typeText:
            return .keyboardActions
        case .activateApplication, .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
            return .applicationControl
        case .sleepComputer, .lockScreen, .toggleDarkMode, .toggleDoNotDisturb,
             .volumeUp, .volumeDown, .brightnessUp, .brightnessDown, .muteVolume, .setSoundOutput:
            return .systemActions
        case .runAppleScript, .runShellScript, .openURL:
            return .scriptExecution
        case .playPause, .nextTrack, .previousTrack:
            return .mediaControls
        case .leftClick, .rightClick, .middleClick, .doubleLeftClick, .commandLeftClick,
             .moveMouseToPosition, .saveMousePosition, .restoreMousePosition,
             .startDrag, .stopDrag, .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return .mouseActions
        case .captureArea, .captureFullscreen, .captureWindow, .captureWindowUnderCursor,
             .recordScreen, .capturePreviousArea, .captureScrolling, .captureText, .captureTextWithLineBreaks,
             .captureTextWithoutLineBreaks, .captureAllDisplays, .captureSelfTimer,
             .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
             .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
            return .screenCapture
        case .snapWindowTopHalf, .snapWindowBottomHalf, .moveResizeWindow, .toggleFullscreenWindow,
             .zoomWindow, .closeWindow, .startMovingWindow, .stopMovingWindow, .toggleMovingWindow,
             .startResizingWindow, .stopResizingWindow, .toggleResizingWindow:
            return .windowManagement
        case .switchSpaceLeft, .switchSpaceRight, .switchToDesktop, .moveWindowToPreviousSpace,
             .moveWindowToNextSpace, .missionControl, .appExpose, .launchpad, .showDesktop:
            return .spacesMissionControl
        case .hideOtherApps: return .applicationControl
        case .ctrlLeftClick, .optionLeftClick, .shiftLeftClick, .cmdDoubleClick, .customClick,
             .scrollCustom, .moveMouseRelative:
            return .mouseActions
        case .pasteString, .pressFunctionKey, .modifierKeyDown, .modifierKeyUp, .allModifiersUp,
             .toggleCapsLock, .pressPageUp, .pressPageDown, .pressHome, .pressEnd, .pressArrowKey,
             .pressContextMenuKey:
            return .keyboardActions
        case .startScreenSaver, .emptyTrash, .sleepDisplay, .logOut, .toggleHiddenFiles,
             .openNotificationCenter, .openControlCenter, .setVolume, .setBrightness,
             .toggleMuteMicrophone, .startDictation:
            return .systemActions
        case .playSoundFile, .speakText, .showNotification, .copyTextToClipboard, .openFileOrFolder, .revealInFinder:
            return .utilityActions
        case .runAppleShortcut, .runJavaScript: return .scriptExecution
        case .repeatLoop, .breakLoop, .cycleActions, .toggleOnOff, .increaseVariable, .decreaseVariable,
             .askForInput, .debounce, .stopAllSequences, .enableTrigger, .disableTrigger, .waitFor,
             .disableTriggersForSeconds, .resumeTriggers:
            return .controlFlow
        }
    }

    var iconName: String {
        switch self {
        case .actionGroup: return "folder"
        case .ifElse: return "arrow.triangle.branch"
        case .setVariable: return "textformat.123"
        case .wait: return "hourglass"
        case .triggerNamedTrigger: return "arrow.triangle.branch"
        case .showHUD: return "text.bubble"
        case .showCheatSheet: return "list.bullet.rectangle"
        case .maximizeWindow: return "arrow.up.left.and.arrow.down.right"
        case .minimizeWindow: return "arrow.down.right.and.arrow.up.left"
        case .snapWindowLeft: return "rectangle.lefthalf.filled"
        case .snapWindowRight: return "rectangle.righthalf.filled"
        case .snapWindowTopLeft: return "rectangle.topleft.filled"
        case .snapWindowTopRight: return "rectangle.topright.filled"
        case .snapWindowBottomLeft: return "rectangle.bottomleft.filled"
        case .snapWindowBottomRight: return "rectangle.bottomright.filled"
        case .centerWindow: return "rectangle.center.inset.filled"
        case .snapWindowLeftThird, .snapWindowCenterThird, .snapWindowRightThird,
             .snapWindowLeftTwoThirds, .snapWindowRightTwoThirds: return "rectangle.split.3x1"
        case .snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
             .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth:
            return "rectangle.split.3x2"
        case .moveWindowLeft: return "arrow.left.square"
        case .moveWindowRight: return "arrow.right.square"
        case .moveWindowUp: return "arrow.up.square"
        case .moveWindowDown: return "arrow.down.square"
        case .bringWindowToFront: return "macwindow.on.rectangle"
        case .maximizeWindowUnderCursor, .minimizeWindowUnderCursor, .closeWindowUnderCursor:
            return "cursorarrow.rays"
        case .leftClick, .doubleLeftClick: return "cursorarrow.click"
        case .rightClick, .middleClick, .commandLeftClick: return "cursorarrow.click.2"
        case .moveMouseToPosition: return "cursorarrow.motionlines"
        case .saveMousePosition: return "square.and.arrow.down"
        case .restoreMousePosition: return "square.and.arrow.up"
        case .startDrag, .stopDrag: return "hand.draw"
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return "scroll"
        case .moveWindowNextMonitor, .moveWindowPreviousMonitor, .moveWindowNextMonitorAndMaximize: return "display.2"
        case .undoWindowPlacement: return "arrow.uturn.backward.circle"
        case .saveWindowLayout: return "square.and.arrow.down"
        case .restoreWindowLayout: return "rectangle.3.group"
        case .restoreWindowSize: return "arrow.uturn.backward"
        case .customSnapWindow: return "rectangle.dashed.badge.record"
        case .showClipboardHistory: return "doc.on.clipboard"
        case .showPasteStack: return "square.stack"
        case .pasteNextClipboardItem: return "text.insert"
        case .toggleClipboardRecording: return "pause.circle"
        case .sendKeyStroke: return "command"
        case .typeText: return "text.cursor"
        case .activateApplication: return "app.badge"
        case .launchApplication: return "app"
        case .quitApplication: return "xmark.app"
        case .forceQuitApplication: return "xmark.octagon"
        case .hideApplication: return "eye.slash"
        case .toggleApplication: return "app.badge.checkmark"
        case .sleepComputer: return "moon"
        case .lockScreen: return "lock"
        case .toggleDarkMode: return "circle.lefthalf.filled"
        case .toggleDoNotDisturb: return "moon.circle"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
        case .muteVolume: return "speaker.slash"
        case .setSoundOutput: return "hifispeaker"
        case .runAppleScript: return "applescript"
        case .runShellScript: return "terminal"
        case .openURL: return "link"
        case .playPause: return "playpause"
        case .nextTrack: return "forward.end"
        case .previousTrack: return "backward.end"
        case .captureArea: return "viewfinder"
        case .captureFullscreen: return "rectangle.inset.filled"
        case .captureWindow: return "macwindow"
        case .captureWindowUnderCursor: return "macwindow.badge.plus"
        case .recordScreen: return "record.circle"
        case .capturePreviousArea: return "arrow.counterclockwise.square"
        case .captureScrolling: return "scroll"
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks, .ocrLastCapture:
            return "text.viewfinder"
        case .captureAllDisplays: return "display.2"
        case .captureSelfTimer: return "timer"
        case .annotateLastCapture: return "pencil.tip.crop.circle"
        case .pinLastCapture: return "pin"
        case .copyLastCapture: return "doc.on.doc"
        case .saveLastCapture: return "square.and.arrow.down"
        case .openCaptureHistory: return "clock.arrow.circlepath"
        case .unpinAllCaptures: return "pin.slash"
        case .toggleCaptureOverlay: return "rectangle.on.rectangle"
        case .snapWindowTopHalf: return "rectangle.tophalf.filled"
        case .snapWindowBottomHalf: return "rectangle.bottomhalf.filled"
        case .moveResizeWindow: return "rectangle.dashed"
        case .toggleFullscreenWindow: return "arrow.up.left.and.arrow.down.right.square"
        case .zoomWindow: return "plus.magnifyingglass"
        case .closeWindow: return "xmark.rectangle"
        case .startMovingWindow, .stopMovingWindow, .toggleMovingWindow: return "arrow.up.and.down.and.arrow.left.and.right"
        case .startResizingWindow, .stopResizingWindow, .toggleResizingWindow: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .switchSpaceLeft: return "arrow.left.to.line"
        case .switchSpaceRight: return "arrow.right.to.line"
        case .switchToDesktop: return "desktopcomputer"
        case .moveWindowToPreviousSpace: return "arrow.left.square.fill"
        case .moveWindowToNextSpace: return "arrow.right.square.fill"
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "square.grid.3x3"
        case .launchpad: return "square.grid.2x2"
        case .showDesktop: return "menubar.dock.rectangle"
        case .hideOtherApps: return "eye.slash.circle"
        case .ctrlLeftClick, .optionLeftClick, .shiftLeftClick: return "cursorarrow.click"
        case .cmdDoubleClick: return "cursorarrow.click.2"
        case .customClick: return "cursorarrow.rays"
        case .scrollCustom: return "arrow.up.and.down.text.horizontal"
        case .moveMouseRelative: return "cursorarrow.motionlines"
        case .pasteString: return "doc.on.clipboard.fill"
        case .pressFunctionKey: return "fn"
        case .modifierKeyDown: return "arrow.down.to.line"
        case .modifierKeyUp: return "arrow.up.to.line"
        case .allModifiersUp: return "keyboard.chevron.compact.down"
        case .toggleCapsLock: return "capslock"
        case .pressPageUp: return "arrow.up.doc"
        case .pressPageDown: return "arrow.down.doc"
        case .pressHome: return "arrow.up.to.line"
        case .pressEnd: return "arrow.down.to.line"
        case .pressArrowKey: return "arrow.up.arrow.down"
        case .pressContextMenuKey: return "contextualmenu.and.cursorarrow"
        case .startScreenSaver: return "display"
        case .emptyTrash: return "trash"
        case .sleepDisplay: return "display.trianglebadge.exclamationmark"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .toggleHiddenFiles: return "eye.trianglebadge.exclamationmark"
        case .openNotificationCenter: return "bell"
        case .openControlCenter: return "switch.2"
        case .setVolume: return "speaker.wave.2"
        case .setBrightness: return "sun.max.fill"
        case .toggleMuteMicrophone: return "mic.slash"
        case .startDictation: return "mic"
        case .playSoundFile: return "music.note"
        case .speakText: return "waveform"
        case .showNotification: return "bell.badge"
        case .copyTextToClipboard: return "doc.on.doc.fill"
        case .openFileOrFolder: return "folder"
        case .revealInFinder: return "magnifyingglass.circle"
        case .runAppleShortcut: return "square.stack.3d.up"
        case .runJavaScript: return "curlybraces"
        case .repeatLoop: return "repeat"
        case .breakLoop: return "xmark.circle"
        case .cycleActions: return "arrow.triangle.2.circlepath"
        case .toggleOnOff: return "togglepower"
        case .increaseVariable: return "plus.circle"
        case .decreaseVariable: return "minus.circle"
        case .askForInput: return "questionmark.bubble"
        case .debounce: return "timer"
        case .stopAllSequences: return "stop.circle"
        case .enableTrigger: return "checkmark.circle"
        case .disableTrigger: return "nosign"
        case .waitFor: return "hourglass.bottomhalf.filled"
        case .disableTriggersForSeconds: return "pause.circle"
        case .resumeTriggers: return "play.circle"
        }
    }

    /// Actions that hold a nested list of steps. AppState/ActionTree consult this
    /// instead of hard-coding group and If/Else.
    var canContainChildren: Bool {
        switch self {
        case .actionGroup, .ifElse, .repeatLoop, .cycleActions, .toggleOnOff: return true
        default: return false
        }
    }
    /// Only these may also hold an Else/second list.
    var canContainElseChildren: Bool { self == .ifElse || self == .toggleOnOff }

    static func actionsForCategory(_ category: ActionCategory) -> [ActionType] {
        allCases.filter { $0.category == category }
    }

    /// The one-line explanation shown above a capture action's parameters.
    ///
    /// These live next to the enum rather than in the view so the wording stays
    /// with the behaviour it describes.
    static func describeCaptureAction(_ type: ActionType) -> String {
        switch type {
        case .captureArea: return "Dims the screen and lets you drag out a region to capture."
        case .captureFullscreen: return "Captures the display the pointer is on, with no selection step."
        case .captureWindow: return "Shows a grid of open windows to pick from."
        case .captureWindowUnderCursor: return "Captures the frontmost window under the pointer."
        case .recordScreen: return "Records a selected area of the screen to an MP4 video."
        case .capturePreviousArea: return "Re-captures the last region you dragged, without asking again."
        case .captureScrolling: return "Captures a region that scrolls, stitching the frames into one tall image."
        case .captureAllDisplays: return "Captures every connected display as a separate image."
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks:
            return "Reads text out of a region you select and copies it to the clipboard."
        case .captureSelfTimer: return "Waits, then opens the area selection."
        case .annotateLastCapture: return "Opens the annotate editor on the most recent capture."
        case .pinLastCapture: return "Floats the most recent capture on top of every window."
        case .copyLastCapture: return "Puts the most recent capture on the clipboard as an image."
        case .saveLastCapture: return "Writes the most recent capture to disk and reveals it in Finder."
        case .ocrLastCapture: return "Reads text out of the most recent capture and copies it."
        case .openCaptureHistory: return "Shows the captures from this session so a closed overlay can be recovered."
        case .unpinAllCaptures: return "Removes every pinned capture from the screen."
        case .toggleCaptureOverlay: return "Turns the floating capture thumbnail on or off."
        default: return type.rawValue
        }
    }
}

struct TriggerAction: Identifiable, Codable, Hashable {
    let id: UUID
    var actionType: ActionType
    var isEnabled: Bool
    var parameters: ActionParameters

    init(actionType: ActionType, parameters: ActionParameters = ActionParameters()) {
        self.id = UUID()
        self.actionType = actionType
        self.isEnabled = true
        self.parameters = parameters
    }
}

struct ActionParameters: Codable, Hashable {
    var windowLayoutName: String?
    var namedTriggerName: String?
    var hudText: String?
    var minimumBatteryPercent: Int?
    var maximumBatteryPercent: Int?
    var minimumDisplayCount: Int?
    var maximumDisplayCount: Int?
    var powerSource: String? // ac or battery; nil = any
    var label: String?
    var notes: String?
    var children: [TriggerAction]?
    var elseChildren: [TriggerAction]?
    var variableName: String?
    var variableValue: String?
    var conditionKind: String? // variable, app, window, mouseX, mouseY
    var conditionOperator: String? // equals, notEquals, contains, regex, greater, less
    var conditionValue: String?
    var windowTitleRegex: String?
    var snapX: Double? // normalized within visible display area
    var snapY: Double?
    var snapWidth: Double?
    var snapHeight: Double?
    var snapDisplay: String? // current, primary, next
    var repeatCount: Int?
    var repeatIntervalMs: Int?
    var delayAfterMs: Int?
    var waitMs: Int?
    var continueOnFailure: Bool?
    var onlyAppBundleID: String?
    var windowTitleContains: String?
    var useCurrentWindow: Bool?
    var text: String?
    var applicationPath: String?
    var applicationName: String?
    var scriptContent: String?
    var url: String?
    var shortcutKeyCode: UInt16?
    var shortcutModifiers: UInt?
    var delayBeforeMs: Int?
    var audioOutputName: String?
    /// Normalized to the pointer display's visible frame, y from the top.
    var mouseX: Double?
    var mouseY: Double?
    var scrollAmount: Int?
    var audioOutputUID: String?
    var volumeStepPercent: Double?
    var scriptTimeoutSeconds: Double?
    /// Seconds to wait before a capture, for the self-timer action.
    var selfTimerSeconds: Int?
    /// Whether OCR keeps the visual line structure. Absent means the global
    /// setting applies, so an old preset follows the preference rather than
    /// being frozen to whatever it was when the action was created.
    var ocrKeepsLineBreaks: Bool?

    // MARK: Added in 1.1.4. Every field is optional so older presets decode unchanged.

    /// Window actions: "focused" (default) or "underCursor".
    var windowTarget: String?
    /// Move / Resize Window. Unit is "percent" or "pixels"; percentages are of the
    /// target display's visible area. Anchor names the window/screen reference point.
    var moveResizeUnit: String?
    var moveResizeAnchor: String? // topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var moveResizeX: Double?
    var moveResizeY: Double?
    var moveResizeWidth: Double?  // nil keeps the window's current width
    var moveResizeHeight: Double? // nil keeps the window's current height
    /// Move/resize-with-pointer safety timeout in seconds.
    var windowDragTimeoutSeconds: Double?
    /// 1…9 for Switch to Desktop.
    var desktopNumber: Int?

    var clickButton: Int?          // 0 left, 1 right, 2 middle, 3… other
    var clickCount: Int?           // 1…3
    var clickModifiers: UInt?      // NSEvent.ModifierFlags raw value
    var modifierKey: String?       // command, option, shift, control, fn (+ "right" prefix variants)
    var functionKeyNumber: Int?    // 1…20
    var keyRepeatCount: Int?       // 1…100
    var arrowDirection: String?    // up, down, left, right
    var scrollDirection: String?   // up, down, left, right
    var scrollUnit: String?        // lines, pixels
    var scrollDurationMs: Int?     // 0 = a single burst; otherwise spread over this time
    var mouseDeltaX: Double?
    var mouseDeltaY: Double?

    /// Destructive actions ask first unless this is explicitly false. nil means "ask".
    var requiresConfirmation: Bool?
    /// 0…100, used by Set Volume and Set Brightness (and Play Sound File volume).
    var levelPercent: Double?
    var filePath: String?
    var speechRate: Double?        // 0…1, AVSpeechUtterance scale
    var speechVoiceID: String?
    var notificationTitle: String?
    var shortcutName: String?

    var loopCount: Int?            // Repeat N Times
    var cycleResetSeconds: Double? // Cycle Through Actions: restart from step 1 after idle time
    var variableStep: Double?      // Increase / Decrease Variable
    var inputPrompt: String?       // Ask For Input
    var triggerSelector: String?   // Enable/Disable Trigger: trigger name or UUID
    /// Wait For…: appRunning, appFrontmost, fileExists, clipboardChange.
    var waitCondition: String?
    var waitTarget: String?
    var waitTimeoutMs: Int?
    var waitContinueOnTimeout: Bool?
    /// Disable Triggers For X Seconds.
    var pauseSeconds: Double?

    init() {}
}

/// Ordered value tree. Parentage is structural; duplicated groups get fresh IDs recursively.
enum ActionTree {
    struct Row: Identifiable {
        let action: TriggerAction
        let depth: Int
        let isElse: Bool
        init(action: TriggerAction, depth: Int, isElse: Bool = false) {
            self.action = action; self.depth = depth; self.isElse = isElse
        }
        var id: UUID { action.id }
    }
    static func rows(_ actions: [TriggerAction], depth: Int = 0, isElse: Bool = false) -> [Row] {
        actions.flatMap { [Row(action: $0, depth: depth, isElse: isElse)]
            + rows($0.parameters.children ?? [], depth: depth + 1)
            + rows($0.parameters.elseChildren ?? [], depth: depth + 1, isElse: true) }
    }
    static func edit(_ actions: inout [TriggerAction], id: UUID, change: (inout [TriggerAction], Int) -> Void) -> Bool {
        if let i = actions.firstIndex(where: { $0.id == id }) { change(&actions, i); return true }
        for i in actions.indices {
            if var children = actions[i].parameters.children, edit(&children, id: id, change: change) {
                actions[i].parameters.children = children; return true
            }
            if var alternate = actions[i].parameters.elseChildren, edit(&alternate, id: id, change: change) {
                actions[i].parameters.elseChildren = alternate; return true
            }
        }
        return false
    }
    static func duplicate(_ action: TriggerAction) -> TriggerAction {
        var copy = TriggerAction(actionType: action.actionType, parameters: action.parameters)
        copy.isEnabled = action.isEnabled
        copy.parameters.children = action.parameters.children.map { $0.map(duplicate) }
        copy.parameters.elseChildren = action.parameters.elseChildren.map { $0.map(duplicate) }
        return copy
    }
    /// Moves `id` to sit directly before `targetID`, in whatever list holds the
    /// target (so dropping onto a nested row also re-parents). Refuses to drop an
    /// action into its own subtree. Returns false and leaves `actions` untouched
    /// on any failure.
    @discardableResult
    static func move(_ actions: inout [TriggerAction], id: UUID, before targetID: UUID) -> Bool {
        guard id != targetID, let moving = rows(actions).first(where: { $0.id == id })?.action,
              !rows([moving]).contains(where: { $0.id == targetID }) else { return false }
        var copy = actions
        guard edit(&copy, id: id, change: { list, i in list.remove(at: i) }),
              edit(&copy, id: targetID, change: { list, i in list.insert(moving, at: i) }) else { return false }
        actions = copy
        return true
    }
    /// Moves `id` to the end of the top-level list.
    @discardableResult
    static func moveToEnd(_ actions: inout [TriggerAction], id: UUID) -> Bool {
        guard let moving = rows(actions).first(where: { $0.id == id })?.action else { return false }
        var copy = actions
        guard edit(&copy, id: id, change: { list, i in list.remove(at: i) }) else { return false }
        copy.append(moving); actions = copy
        return true
    }

    static func problem(_ actions: [TriggerAction]) -> String? {
        var ids = Set<UUID>(); var count = 0
        func inspect(_ list: [TriggerAction], _ depth: Int, _ multiplier: Int) -> String? {
            guard depth <= 8 else { return "Groups can be nested at most 8 levels." }
            for action in list {
                guard ids.insert(action.id).inserted else { return "Action identifiers must be unique." }
                let p = action.parameters; let repeats = p.repeatCount ?? 1
                if let name = p.windowLayoutName, name.count > 128 { return "Layout names must be at most 128 characters." }
                guard (1...100).contains(repeats) else { return "Repeat count must be 1–100." }
                if let loops = p.loopCount, !(1...100).contains(loops) { return "Loop count must be 1–100." }
                let loopFactor = action.actionType == .repeatLoop ? (p.loopCount ?? 2) : 1
                let cost = multiplier * repeats; count += cost
                guard count <= 1000 else { return "A sequence can contain at most 1,000 expanded steps." }
                for delay in [p.delayBeforeMs, p.delayAfterMs, p.repeatIntervalMs, p.waitMs].compactMap({ $0 }) {
                    guard (0...60000).contains(delay) else { return "Timing must be between 0 and 60,000 ms." }
                }
                for percent in [p.minimumBatteryPercent, p.maximumBatteryPercent].compactMap({ $0 }) {
                    guard (0...100).contains(percent) else { return "Battery percentage must be 0–100." }
                }
                for count in [p.minimumDisplayCount, p.maximumDisplayCount].compactMap({ $0 }) {
                    guard (1...32).contains(count) else { return "Display count must be 1–32." }
                }
                if (p.minimumBatteryPercent ?? 0) > (p.maximumBatteryPercent ?? 100) || (p.minimumDisplayCount ?? 1) > (p.maximumDisplayCount ?? 32) { return "Condition minimum cannot exceed maximum." }
                if let source = p.powerSource, !["ac", "battery"].contains(source) { return "Unknown power source." }
                if let timeout = p.scriptTimeoutSeconds, !timeout.isFinite || !(0.1...120).contains(timeout) { return "Script timeout must be 0.1–120 seconds." }
                if let children = p.children, !children.isEmpty {
                    guard action.actionType.canContainChildren else { return "Only groups, If/Else, loops, cycles and toggles may contain child actions." }
                    if let error = inspect(children, depth + 1, cost * loopFactor) { return error }
                }
                if let alternate = p.elseChildren, !alternate.isEmpty {
                    guard action.actionType.canContainElseChildren else { return "Only If/Else and Toggle On/Off may contain a second action list." }
                    if let error = inspect(alternate, depth + 1, cost) { return error }
                }
                if let error = ActionParameterValidation.problem(for: action) { return error }
                if [.setVariable, .increaseVariable, .decreaseVariable, .askForInput].contains(action.actionType)
                    || action.actionType == .ifElse && (p.conditionKind ?? "variable") == "variable" {
                    let name = (p.variableName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.count <= 64, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return "Invalid variable name." }
                }
                if action.actionType == .customSnapWindow {
                    guard WindowGeometry.normalizedRect(x: p.snapX ?? 0, y: p.snapY ?? 0, width: p.snapWidth ?? 0.5, height: p.snapHeight ?? 1) != nil,
                        ["current", "primary", "next", "pointer"].contains(p.snapDisplay ?? "current") else { return "Custom snap area must fit within display (0–100%)." }
                }
                if let pattern = p.windowTitleRegex, !pattern.isEmpty, (pattern.count > 256 || (try? NSRegularExpression(pattern: pattern)) == nil) { return "Invalid window title regex." }
            }
            return nil
        }
        return inspect(actions, 0, 1)
    }
}

extension TriggerAction {
    var displayName: String {
        let name = parameters.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? actionType.rawValue : name
    }
}
