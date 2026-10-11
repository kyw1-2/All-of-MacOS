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
        }
    }

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
    static func problem(_ actions: [TriggerAction]) -> String? {
        var ids = Set<UUID>(); var count = 0
        func inspect(_ list: [TriggerAction], _ depth: Int, _ multiplier: Int) -> String? {
            guard depth <= 8 else { return "Groups can be nested at most 8 levels." }
            for action in list {
                guard ids.insert(action.id).inserted else { return "Action identifiers must be unique." }
                let p = action.parameters; let repeats = p.repeatCount ?? 1
                if let name = p.windowLayoutName, name.count > 128 { return "Layout names must be at most 128 characters." }
                guard (1...100).contains(repeats) else { return "Repeat count must be 1–100." }
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
                    guard action.actionType == .actionGroup || action.actionType == .ifElse else { return "Only groups and If/Else may contain child actions." }
                    if let error = inspect(children, depth + 1, cost) { return error }
                }
                if let alternate = p.elseChildren, !alternate.isEmpty {
                    guard action.actionType == .ifElse else { return "Only If/Else may contain Else actions." }
                    if let error = inspect(alternate, depth + 1, cost) { return error }
                }
                if action.actionType == .setVariable || action.actionType == .ifElse && (p.conditionKind ?? "variable") == "variable" {
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
