import Foundation

/// BetterTouchTool numeric IDs and native names used by `BTTPresetImport`.
///
/// Source: the vendor's JSON references bundled with BetterTouchTool 6.908
/// (`trigger-definitions.mdx`, `action-definitions.mdx`; published as
/// docs.folivora.ai/docs/json/trigger-definitions and
/// /docs/actions/action-definitions). Only documented IDs are listed and every
/// mapping targets an existing AOM type. No vendor implementation is copied.
enum BTTImportMappings {

    // MARK: Trackpad (BTTGestureTP catalog)

    /// One BTT trackpad gesture and its AOM counterpart, if any.
    struct Gesture {
        let name: String
        let aom: TrackpadGesture?
        /// Set when the AOM gesture is close but not identical.
        let approximation: String?
        /// Why there is no AOM gesture.
        let gap: String?
    }
    private static func g(_ name: String, _ aom: TrackpadGesture) -> Gesture { Gesture(name: name, aom: aom, approximation: nil, gap: nil) }
    private static func near(_ name: String, _ aom: TrackpadGesture, _ why: String) -> Gesture { Gesture(name: name, aom: aom, approximation: why, gap: nil) }
    private static func none(_ name: String, _ why: String) -> Gesture { Gesture(name: name, aom: nil, approximation: nil, gap: why) }

    static let continuousGap = "Continuous gestures bind a live value to actions; AOM triggers are discrete."
    static let harderGap = "AOM does not tell which finger pressed harder."
    static let tipTapGap = "AOM recognizes TipTap with one resting finger (left/right) or two (middle) only."
    static let drawingGap = "AOM has no trackpad drawing trigger."
    private static let thumbPinch = "AOM matches a pinch by contact count; it does not check that one contact is the thumb."

    static let trackpad: [Int: Gesture] = [
        // Release
        209: g("Release Last Finger After Previous Touch With 1 Finger", .releaseLastFingerAfter1),
        210: g("Release Last Finger After Previous Touch With 2 Fingers", .releaseLastFingerAfter2),
        211: g("Release Last Finger After Previous Touch With 3 Fingers", .releaseLastFingerAfter3),
        212: g("Release Last Finger After Previous Touch With 4 Fingers", .releaseLastFingerAfter4),
        213: g("Release Last Finger After Previous Touch With 5 Fingers", .releaseLastFingerAfter5),
        214: g("Release Last Finger Regardless of How Many Were Touching Before", .releaseLastFingerRegardless),
        // One finger
        113: g("TipTap Left (1 Finger Fix)", .tipTapLeft),
        114: g("TipTap Right (1 Finger Fix)", .tipTapRight),
        122: g("1 Finger Tap Top Left", .oneFingerTapTopLeft),
        123: g("1 Finger Tap Top Right", .oneFingerTapTopRight),
        124: g("1 Finger Tap Top Middle", .oneFingerTapTopMiddle),
        125: g("1 Finger Tap Bottom Left", .oneFingerTapBottomLeft),
        126: g("1 Finger Tap Bottom Right", .oneFingerTapBottomRight),
        127: g("1 Finger Tap Bottom Middle", .oneFingerTapBottomMiddle),
        134: g("1 Finger Tap Left Side Middle", .oneFingerTapLeftSideMiddle),
        135: g("1 Finger Tap Right Side Middle", .oneFingerTapRightSideMiddle),
        207: g("1 Finger Tap", .oneFingerTap),
        208: g("1 Finger Double Tap", .oneFingerDoubleTap),
        215: g("1 Finger Touch Start", .oneFingerTouchStart),
        221: g("1 Finger Long Touch", .oneFingerLongTouch),
        226: g("1 Finger Circle Clockwise", .circleClockwise),
        227: g("1 Finger Circle Counter-Clockwise", .circleCounterClockwise),
        228: g("1 Finger Swipe Up on Left Edge", .oneFingerSwipeUpOnLeftEdge),
        229: g("1 Finger Swipe Down on Left Edge", .oneFingerSwipeDownOnLeftEdge),
        230: g("1 Finger Swipe Up on Right Edge", .oneFingerSwipeUpOnRightEdge),
        231: g("1 Finger Swipe Down on Right Edge", .oneFingerSwipeDownOnRightEdge),
        232: g("1 Finger Swipe Left on Top Edge", .oneFingerSwipeLeftOnTopEdge),
        233: g("1 Finger Swipe Right on Top Edge", .oneFingerSwipeRightOnTopEdge),
        234: g("1 Finger Swipe Left on Bottom Edge", .oneFingerSwipeLeftOnBottomEdge),
        235: g("1 Finger Swipe Right on Bottom Edge", .oneFingerSwipeRightOnBottomEdge),
        247: none("1 Finger Slide Along Left Edge (Continuous)", continuousGap),
        248: none("1 Finger Slide Along Right Edge (Continuous)", continuousGap),
        249: none("1 Finger Slide Along Top Edge (Continuous)", continuousGap),
        250: none("1 Finger Slide Along Bottom Edge (Continuous)", continuousGap),
        // Two fingers
        132: none("TipTap Left (2 Fingers Fix)", tipTapGap),
        133: none("TipTap Right (2 Fingers Fix)", tipTapGap),
        138: g("TipTap Middle (2 Fingers Fix)", .tipTapMiddle),
        142: none("TipSwipe Left Finger Down (2 Fingers Fix)", tipTapGap),
        143: none("TipSwipe Left Finger Up (2 Fingers Fix)", tipTapGap),
        145: none("TipSwipe Left Finger Right (2 Fingers Fix)", tipTapGap),
        146: none("TipSwipe Left Finger Left (2 Fingers Fix)", tipTapGap),
        159: g("2 Finger Swipe Left", .twoFingerSwipeLeft),
        160: g("2 Finger Swipe Right", .twoFingerSwipeRight),
        161: g("2 Finger Swipe Up", .twoFingerSwipeUp),
        162: g("2 Finger Swipe Down", .twoFingerSwipeDown),
        165: g("2 Finger Swipe From Left Edge", .twoFingerSwipeFromLeftEdge),
        166: g("2 Finger Swipe From Right Edge", .twoFingerSwipeFromRightEdge),
        167: g("2 Finger Swipe From Top Edge", .twoFingerSwipeFromTopEdge),
        168: g("2 Finger Swipe From Bottom Edge", .twoFingerSwipeFromBottomEdge),
        173: g("2 Finger Tap", .twoFingerTap),
        174: g("2 Finger Click", .twoFingerClick),
        175: g("2 Finger Force Click", .forceClickTwoFinger),
        176: none("2 Finger Click, Left Finger Harder", harderGap),
        177: none("2 Finger Click, Right Finger Harder", harderGap),
        179: g("2 Finger Double-Tap", .twoFingerDoubleTap),
        180: none("2 Finger FORCE Click, Left Finger Harder", harderGap),
        181: none("2 Finger FORCE Click, Right Finger Harder", harderGap),
        197: near("Pinch With Thumb And 2 Fingers", .threeFingerPinchIn, thumbPinch),
        198: near("Spread With Thumb And 2 Fingers", .threeFingerPinchOut, thumbPinch),
        216: g("2 Finger Touch Start", .twoFingerTouchStart),
        222: g("2 Finger Long Touch", .twoFingerLongTouch),
        236: none("2 Finger Swipe Up on Left Edge", "AOM has one-finger edge swipes only."),
        237: none("2 Finger Swipe Down on Left Edge", "AOM has one-finger edge swipes only."),
        238: none("2 Finger Swipe Up on Right Edge", "AOM has one-finger edge swipes only."),
        239: none("2 Finger Swipe Down on Right Edge", "AOM has one-finger edge swipes only."),
        240: none("2 Finger Swipe Left on Top Edge", "AOM has one-finger edge swipes only."),
        241: none("2 Finger Swipe Right on Top Edge", "AOM has one-finger edge swipes only."),
        242: none("2 Finger Swipe Left on Bottom Edge", "AOM has one-finger edge swipes only."),
        243: none("2 Finger Swipe Right on Bottom Edge", "AOM has one-finger edge swipes only."),
        251: none("2 Finger Slide Along Left Edge (Continuous)", continuousGap),
        252: none("2 Finger Slide Along Right Edge (Continuous)", continuousGap),
        253: none("2 Finger Slide Along Top Edge (Continuous)", continuousGap),
        254: none("2 Finger Slide Along Bottom Edge (Continuous)", continuousGap),
        255: none("2 Finger Pinch (Continuous)", continuousGap),
        256: none("2 Finger Rotation (Continuous)", continuousGap),
        // Three fingers
        100: g("3 Finger Swipe Left", .threeFingerSwipeLeft),
        101: g("3 Finger Swipe Right", .threeFingerSwipeRight),
        102: g("3 Finger Swipe Up", .threeFingerSwipeUp),
        103: g("3 Finger Swipe Down", .threeFingerSwipeDown),
        104: g("3 Finger Tap", .threeFingerTap),
        112: g("3 Finger Click", .threeFingerClick),
        136: none("TipTap Left (3 Fingers Fix)", tipTapGap),
        137: none("TipTap Right (3 Fingers Fix)", tipTapGap),
        139: g("3 Finger Tap Bottom", .threeFingerTapBottom),
        140: g("3 Finger Tap Top", .threeFingerTapTop),
        152: none("3 Finger Dragging", "AOM has no three-finger drag trigger."),
        153: none("3 Finger Clickswipe Left", "AOM has no click-swipe trigger."),
        154: none("3 Finger Clickswipe Right", "AOM has no click-swipe trigger."),
        155: none("3 Finger Clickswipe Up", "AOM has no click-swipe trigger."),
        156: none("3 Finger Clickswipe Down", "AOM has no click-swipe trigger."),
        163: g("3 Finger Double-Tap", .threeFingerDoubleTap),
        170: g("3 Finger FORCE Click", .forceClickThreeFinger),
        188: none("3 Finger Click (Left Finger Harder)", harderGap),
        189: none("3 Finger Click (Middle Finger Harder)", harderGap),
        190: none("3 Finger Click (Right Finger Harder)", harderGap),
        191: none("3 Finger Force Click (Left Finger Harder)", harderGap),
        192: none("3 Finger Force Click (Middle Finger Harder)", harderGap),
        193: none("3 Finger Force Click (Right Finger Harder)", harderGap),
        194: near("Pinch With Thumb And 3 Fingers", .fourFingerPinchIn, thumbPinch),
        195: near("Spread With Thumb And 3 Fingers", .fourFingerPinchOut, thumbPinch),
        204: none("3 Finger Drawing", drawingGap),
        217: g("3 Finger Touch Start", .threeFingerTouchStart),
        223: g("3 Finger Long Touch", .threeFingerLongTouch),
        244: none("3 Finger Swipe (Continuous)", continuousGap),
        // Four fingers
        105: g("4 Finger Swipe Left", .fourFingerSwipeLeft),
        106: g("4 Finger Swipe Right", .fourFingerSwipeRight),
        107: g("4 Finger Swipe Down", .fourFingerSwipeDown),
        108: g("4 Finger Swipe Up", .fourFingerSwipeUp),
        110: g("4 Finger Tap", .fourFingerTap),
        121: g("4 Finger Click", .fourFingerClick),
        164: none("Custom Tap Sequence (4 Fingers)", "AOM has no custom tap sequences."),
        169: g("4 Finger Double Tap", .fourFingerDoubleTap),
        171: none("4 Finger FORCE Click", "AOM has force clicks for 1–3 fingers only."),
        200: near("Pinch With Thumb And 4 Fingers", .fiveFingerPinchIn, thumbPinch),
        201: near("Spread With Thumb And 4 Fingers", .fiveFingerPinchOut, thumbPinch),
        205: none("4 Finger Drawing", drawingGap),
        218: g("4 Finger Touch Start", .fourFingerTouchStart),
        224: g("4 Finger Long Touch", .fourFingerLongTouch),
        245: none("4 Finger Swipe (Continuous)", continuousGap),
        // Five fingers
        111: g("5 Finger Tap", .fiveFingerTap),
        128: g("5 Finger Swipe Left", .fiveFingerSwipeLeft),
        129: g("5 Finger Swipe Right", .fiveFingerSwipeRight),
        130: g("5 Finger Swipe Down", .fiveFingerSwipeDown),
        131: g("5 Finger Swipe Up", .fiveFingerSwipeUp),
        141: g("5 Finger Click", .fiveFingerClick),
        151: none("5 Finger Touch", "AOM has no plain five-finger touch trigger; use 5 Finger Touch Start."),
        172: none("5 Finger FORCE Click", "AOM has force clicks for 1–3 fingers only."),
        199: none("11 Finger Tap / Whole Hand", "AOM has no whole-hand tap."),
        206: none("5 Finger Drawing", drawingGap),
        219: g("5 Finger Touch Start", .fiveFingerTouchStart),
        225: g("5 Finger Long Touch", .fiveFingerLongTouch),
        246: none("5 Finger Swipe (Continuous)", continuousGap),
        // Other
        115: g("Pinch In", .twoFingerPinchIn),
        116: g("Pinch Out", .twoFingerPinchOut),
        117: g("Rotate Left", .twoFingerRotateLeft),
        118: g("Rotate Right", .twoFingerRotateRight),
        119: g("Scroll Up (modifier key needed)", .scrollUp),
        120: g("Scroll Down (modifier key needed)", .scrollDown),
        147: none("Triangle Swipe Top Left Corner", "AOM has no corner triangle swipes."),
        148: none("Triangle Swipe Top Right Corner", "AOM has no corner triangle swipes."),
        149: none("Triangle Swipe Bottom Left Corner", "AOM has no corner triangle swipes."),
        150: none("Triangle Swipe Bottom Right Corner", "AOM has no corner triangle swipes."),
        157: g("Corner Click Bottom Left", .cornerClickBottomLeft),
        158: g("Corner Click Bottom Right", .cornerClickBottomRight),
        182: g("Corner Click Top Left", .cornerClickTopLeft),
        183: g("Corner Click Top Right", .cornerClickTopRight),
        184: g("Corner FORCE Click Top Left", .cornerForceClickTopLeft),
        185: g("Corner FORCE Click Top Right", .cornerForceClickTopRight),
        186: g("Corner FORCE Click Bottom Left", .cornerForceClickBottomLeft),
        187: g("Corner FORCE Click Bottom Right", .cornerForceClickBottomRight),
        203: g("Single Finger FORCE Click", .forceClick),
        220: none("First Touch With 1 2 3 4 5 X Fingers, Then Release Y Of Them", "AOM has no partial-release trigger.")
    ]

    /// BTT trackpad classes. A nonempty value says what AOM cannot reproduce.
    static let trackpadClasses: [String: String] = [
        "BTTTriggerTypeTouchpadAll": "",
        "BTTTriggerTypeTouchpadBuiltIn": "BTT limited this gesture to the built-in trackpad; AOM gestures work on every trackpad.",
        "BTTTriggerTypeTouchpadMagicTrackpad": "BTT limited this gesture to the Magic Trackpad 1; AOM gestures work on every trackpad.",
        "BTTTriggerTypeTouchpadMagicTrackpad2": "BTT limited this gesture to the Magic Trackpad 2; AOM gestures work on every trackpad."
    ]

    // MARK: Magic Mouse (BTTGestureMM catalog). AOM has no Magic Mouse input.

    static let magicMouseGap = "AOM has no Magic Mouse gesture input."
    static let magicMouse: [Int: String] = [
        1: "1 Finger Tap", 2: "1 Finger Tap Left", 3: "1 Finger Tap Right", 4: "2 Finger Tap",
        5: "2 Finger Swipe Left", 6: "2 Finger Swipe Right", 7: "2 Finger Swipe Up", 8: "2 Finger Swipe Down",
        9: "3 Finger Tap", 10: "3 Finger Swipe Left", 11: "3 Finger Swipe Right", 12: "3 Finger Swipe Down",
        13: "3 Finger Swipe Up", 14: "Pinch In", 15: "Pinch Out", 16: "TipTap Left (1 Finger Fix)",
        17: "TipTap Right (1 Finger Fix)", 18: "Scroll Up (modifier key needed)", 19: "Scroll Down (modifier key needed)",
        20: "2 Finger Click", 21: "3 Finger Click", 22: "This gesture is not available anymore", 23: "1 Finger Middle Click",
        24: "1 Finger Tap Middle", 25: "4 Finger Click", 26: "4 Finger Swipe Down", 27: "4 Finger Swipe Up",
        28: "4 Finger Swipe Left", 29: "4 Finger Swipe Right", 30: "TipTap Left (2 Fingers Fix)",
        31: "TipTap Right (2 Fingers Fix)", 32: "1 Finger Tap Above Apple", 33: "1 Finger Swipe Down",
        34: "1 Finger Swipe Up", 35: "1 Finger Swipe Left", 36: "1 Finger Swipe Right", 37: "TipTap Middle (2 Fingers Fix)",
        38: "2 Finger Touch Top", 39: "3 Finger Touch Top", 40: "1 Finger Touch Top",
        41: "TipSwipe Left Finger Down (2 Fingers Fix)", 42: "TipSwipe Left Finger Up (2 Fingers Fix)",
        44: "2 Finger Double-Tap", 45: "3 Finger Double-Tap",
        46: "Release Last Finger Regardless of How Many Were Touching Before",
        47: "Release Last Finger After Previous Touch With 1 Finger", 48: "Release Last Finger After Previous Touch With 2 Fingers",
        49: "Release Last Finger After Previous Touch With 3 Fingers", 50: "Release Last Finger After Previous Touch With 4 Fingers",
        51: "Release Last Finger After Previous Touch With 5 Fingers", 52: "1 Finger Touch Start", 53: "2 Finger Touch Start",
        54: "3 Finger Touch Start", 55: "4 Finger Touch Start", 56: "5 Finger Touch Start", 57: "1 Finger Long Touch",
        58: "2 Finger Long Touch", 59: "3 Finger Long Touch", 60: "4 Finger Long Touch", 61: "5 Finger Long Touch",
        62: "1 Finger Circle Clockwise", 63: "1 Finger Circle Counter-Clockwise"
    ]

    // MARK: Trigger classes AOM cannot represent

    static let unsupportedClasses: [String: (name: String, gap: String)] = [
        "BTTTriggerTypeMagicMouse": ("Magic Mouse", magicMouseGap),
        "BTTTriggerTypeDrawings": ("Drawing", "BTT stores the drawn shape in a format it does not document. Record the drawing again in AOM."),
        "BTTTriggerTypeTouchBar": ("Touch Bar item", "AOM cannot replace the Touch Bar of other apps."),
        "BTTTriggerTypeTouchBarTrackpad": ("Touch Bar surface gesture", "AOM has no Touch Bar gestures."),
        "BTTTriggerTypeStreamDeck": ("Stream Deck item", "AOM has no Stream Deck support."),
        "BTTTriggerTypeNotchBar": ("Notch Bar item", "AOM has no Notch Bar items."),
        "BTTTriggerTypeFloatingMenu": ("Floating Menu", "BTT floating menus do not convert to AOM floating menus."),
        "BTTTriggerTypeMIDI": ("MIDI trigger", "BTT keeps the learned note or controller outside the JSON, so it cannot be mapped."),
        "BTTTriggerTypeGenericDevice": ("Generic device", "BTT generic device configurations do not convert to AOM HID triggers."),
        "BTTTriggerTypeBTTRemote": ("BTT Remote", "AOM has no BTT Remote support."),
        "BTTTriggerTypeSiriRemote": ("Siri Remote", "AOM has no Siri Remote triggers."),
        "BTTTriggerTypeGamepad": ("Gamepad profile", "BTT gamepad profiles do not convert to AOM gamepad triggers.")
    ]

    // MARK: Other triggers (names for the report)

    static let otherTriggerNames: [Int: String] = [
        643: "Reusable Named Trigger", 605: "Before Mac Goes To Sleep", 606: "After Mac Wakes From Sleep",
        738: "Did Lock Screen", 739: "Did Unlock Screen", 736: "Did Start Screen Saver", 737: "Did Stop Screen Saver",
        815: "Active Space Did Change", 798: "Battery Connected To AC", 799: "Battery Running On Battery",
        706: "Battery Below X%", 707: "Battery Above X%", 688: "Did Connect To WiFi With Name",
        689: "Did Disconnect From WiFi With Name", 783: "Clipboard Contents Changed", 789: "Variable Value Changed",
        833: "Audio Output Changed", 834: "Audio Input Changed", 687: "Input Source Changed",
        785: "USB Device Did Connect", 786: "USB Device Did Disconnect", 787: "Bluetooth Device Did Connect",
        788: "Bluetooth Device Did Disconnect", 792: "Screen Did Connect", 793: "Screen Did Disconnect",
        609: "Top Left Corner", 610: "Top Right Corner", 611: "Bottom Left Corner", 612: "Bottom Right Corner",
        768: "Mouse To Left Screen Edge", 770: "Mouse To Right Screen Edge", 660: "Mouse To Bottom Screen Edge",
        661: "Mouse To Top Screen Edge", 670: "App Did Launch", 671: "App Did Activate", 672: "App Did Deactivate",
        673: "App Did Terminate", 779: "App Did Change", 604: "Switch to Application", 807: "File Did Change",
        678: "Date/Time Based (Repeating)", 683: "Did Close Lid", 684: "Did Open Lid", 824: "Spotlight Did Show",
        825: "Spotlight Did Hide", 806: "Text Selection Did Change", 848: "Power Mode Did Change",
        784: "Focused Window Did Change", 804: "Focused Window Or Window Title Did Change", 608: "Switch to Window",
        654: "Conditional Activation Group Activated", 655: "Conditional Activation Group Deactivated",
        674: "Menu Bar Icon", 680: "Menu Bar Icon (AppleScript content)", 681: "Menu Bar Icon (Shell Script content)",
        607: "Received Distributed Notification With Name", 850: "OSC Message Received", 851: "Left-Click Dock App Icon",
        861: "Mouse Hovers Dock App Icon", 796: "Script Output Changed", 797: "Advanced Trigger Condition Changed",
        805: "Key Remap", 837: "Trigger Plugin", 849: "Launcher Simple JSON Item", 811: "macOS Did Display Notification",
        664: "Mouse Away From Top Left Corner", 665: "Mouse Away From Top Right Corner",
        666: "Mouse Away From Bottom Left Corner", 667: "Mouse Away From Bottom Right Corner",
        769: "Mouse Away From Left Screen Edge", 771: "Mouse Away From Right Screen Edge",
        662: "Mouse Away From Bottom Screen Edge", 663: "Mouse Away From Top Screen Edge"
    ]

    /// Other triggers that fire without configuration and have one AOM event.
    static let simpleSystemEvents: [Int: SystemTriggerKind] = [
        605: .systemWillSleep, 606: .systemDidWake, 738: .screenLocked, 739: .screenUnlocked,
        736: .screensaverStarted, 737: .screensaverStopped, 815: .activeSpaceChanged,
        798: .powerSourceChanged(ac: true), 799: .powerSourceChanged(ac: false),
        783: .clipboardChanged, 833: .audioOutputChanged
    ]

    // MARK: Actions

    enum ActionRule {
        /// Same behavior, no parameters needed.
        case exact(ActionType)
        /// Close; the string says what differs.
        case approximate(ActionType, String)
        /// Parameters are converted in `BTTPresetImport.customAction`.
        case custom
        /// No AOM action does the same thing.
        case unsupported(String)
        /// Placeholders that do nothing in BTT either.
        case noOp
        /// Structure that a flat AOM action list cannot express safely.
        case controlFlow
    }
    struct ActionInfo {
        let name: String
        let rule: ActionRule
    }
    private static func a(_ name: String, _ rule: ActionRule) -> ActionInfo { ActionInfo(name: name, rule: rule) }
    private static func x(_ name: String, _ type: ActionType) -> ActionInfo { ActionInfo(name: name, rule: .exact(type)) }
    private static func c(_ name: String) -> ActionInfo { ActionInfo(name: name, rule: .custom) }
    private static func u(_ name: String, _ why: String = noAction) -> ActionInfo { ActionInfo(name: name, rule: .unsupported(why)) }
    static let noAction = "No AOM action does the same thing."

    static let actions: [Int: ActionInfo] = [
        -1: a("No Action", .noOp), 366: a("Continue With Next Action", .noOp),
        490: a("Comment", .noOp), 323: a("Separator", .noOp),
        // Mouse
        3: x("Left Click", .leftClick),
        421: a("Left Click - Without Modifier Keys", .approximate(.leftClick, "AOM's left click does not release modifier keys you are holding.")),
        4: x("Right Click", .rightClick), 1: x("Middle Click", .middleClick), 54: x("Double Left Click", .doubleLeftClick),
        87: x("Ctrl + Left Click", .ctrlLeftClick), 88: x("Opt + Left Click", .optionLeftClick),
        2: x("CMD + Left Click", .commandLeftClick), 149: x("CMD + Double Left Click", .cmdDoubleClick),
        89: x("Shift + Click", .shiftLeftClick), 111: c("CMD + Shift + Left Click"),
        154: x("Save Current Mouse Position", .saveMousePosition), 155: x("Restore Saved Mouse Position", .restoreMousePosition),
        65: x("Start Drag", .startDrag), 66: x("Stop Drag", .stopDrag),
        547: a("All Modifier Keys UP", .approximate(.allModifiersUp, "AOM releases the modifier keys that AOM itself is holding.")),
        546: a("Pick Color On Screen And Write To Clipboard", .approximate(.pickScreenColor, "AOM copies the picked color as a hex value.")),
        119: u("Custom Click (Custom Mouse Buttons & Modifiers)"), 153: u("Move Mouse To Position", "BTT position formats do not convert to AOM's normalized position."),
        272: u("Scroll"), 68: u("Toggle Magic Mouse Touchpad Mode"), 126: u("Toggle Mouse Speed"),
        // Keyboard
        193: c("Type String"), 118: c("Paste String"), 264: c("Send Keyboard Shortcut"), 128: c("Send Shortcut to Specific App"),
        189: c("ESC Key"), 64: c("Forward Delete"),
        194: x("Toggle Caps Lock", .toggleCapsLock), 60: x("Page Up", .pressPageUp), 61: x("Page Down", .pressPageDown),
        62: x("Home", .pressHome), 63: x("End", .pressEnd), 532: x("Press Context Menu Key", .pressContextMenuKey),
        51: u("Page Forward"), 52: u("Page Backward"), 483: u("Remap Key", "AOM key remapping is a setting, not an action."),
        482: u("Reset All Key Remappings"), 293: u("Act as Hyper Key", "AOM's Hyper Key is a setting, not an action."),
        422: u("Reset Current Key Sequence"), 597: u("Set / Press / Release Selected Modifier Keys"),
        // Window management
        21: x("Maximize Window", .maximizeWindow), 19: x("Maximize Window Left", .snapWindowLeft),
        20: x("Maximize Window Right", .snapWindowRight), 90: x("Top Left Quarter", .snapWindowTopLeft),
        92: x("Top Right Quarter", .snapWindowTopRight), 91: x("Bottom Left Quarter", .snapWindowBottomLeft),
        93: x("Bottom Right Quarter", .snapWindowBottomRight), 108: x("Left Third", .snapWindowLeftThird),
        109: x("Middle Third", .snapWindowCenterThird), 110: x("Right Third", .snapWindowRightThird),
        174: x("Left Two Thirds", .snapWindowLeftTwoThirds), 175: x("Right Two Thirds", .snapWindowRightTwoThirds),
        96: x("Top Half", .snapWindowTopHalf), 95: x("Bottom Half", .snapWindowBottomHalf),
        97: x("Center Window", .centerWindow), 47: x("Move Window to Next Monitor", .moveWindowNextMonitor),
        48: x("Maximize Window on Next Monitor", .moveWindowNextMonitorAndMaximize),
        84: x("Restore Old Window Size", .restoreWindowSize), 102: x("Close Window Under Cursor", .closeWindowUnderCursor),
        106: x("Minimize Window Under Cursor", .minimizeWindowUnderCursor), 107: c("Zoom Window Under Cursor"),
        112: c("Fullscreen"),
        17: a("Move Window Left", .approximate(.moveWindowLeft, "AOM moves the window by a tenth of the display.")),
        18: a("Move Window Right", .approximate(.moveWindowRight, "AOM moves the window by a tenth of the display.")),
        69: x("Start Moving Window", .startMovingWindow), 70: x("Stop Moving Window", .stopMovingWindow),
        74: x("Toggle Moving Window", .toggleMovingWindow), 71: x("Start Resizing Window", .startResizingWindow),
        72: x("Stop Resizing Window", .stopResizingWindow), 73: x("Toggle Resizing Window", .toggleResizingWindow),
        273: x("Move All Windows to Mouse Display", .gatherWindowsToPointerDisplay),
        98: u("Center Window on Next Monitor"), 204: u("Bring Window Under Cursor to Front"),
        251: u("Move / Resize Window to Custom Position and Size", "BTT's move/resize format does not convert to AOM's."),
        446: u("Move Window to Specific Size and Position", "BTT's move/resize format does not convert to AOM's."),
        560: u("Close Window, If Last Window Quit App"), 267: u("Move & Maximize All Windows to Mouse Display"),
        // System
        13: x("Sleep Display", .sleepDisplay), 14: x("Sleep Computer", .sleepComputer),
        15: a("Logout", .approximate(.logOut, "AOM asks for confirmation before logging out.")),
        158: x("Lock Screen", .lockScreen), 202: x("Start Screen Saver", .startScreenSaver),
        156: a("Empty Trash", .approximate(.emptyTrash, "AOM asks for confirmation before emptying the Trash.")),
        200: a("Toggle Do Not Disturb", .approximate(.toggleDoNotDisturb, "AOM toggles Focus through a Shortcut named “Toggle Focus”, which you need to create.")),
        197: x("Toggle Dark Mode", .toggleDarkMode), 45: x("Show Desktop", .showDesktop),
        16: x("Show/Hide Hidden Files", .toggleHiddenFiles), 122: x("Notification Center", .openNotificationCenter),
        290: x("Control Center", .openControlCenter), 167: x("Show Character Viewer", .showEmojiPicker),
        58: c("Search Selected Text With Google"),
        159: u("Unlock Screen"), 201: u("Toggle Night Shift"), 257: u("Toggle True Tone"), 50: u("Hide All Windows"),
        53: u("Hide All But Active Window"), 488: u("Show All Windows"), 289: u("Close All Notifications"),
        173: u("Start Siri"), 30: u("Eject"), 9: u("Switch to Login Screen"),
        // Applications
        49: c("Launch Application"), 10: c("Open Finder"), 177: c("Show/Hide Specific Application"),
        592: c("Quit Specific Application"), 247: x("Quit App Under Cursor", .quitAppUnderCursor),
        294: x("Hide App Under Cursor", .hideAppUnderCursor), 367: x("Activate Previous App", .activatePreviousApp),
        46: u("Application Switcher"), 142: u("Application Switcher"), 364: u("Activate Specific Window"),
        // Media and audio
        23: x("Play/Pause", .playPause), 27: x("Next Track", .nextTrack), 26: x("Previous Track", .previousTrack),
        24: x("Volume Up", .volumeUp), 25: x("Volume Down", .volumeDown), 22: x("Mute", .muteVolume),
        198: c("Volume Up (Small Step)"), 199: c("Volume Down (Small Step)"), 373: c("Set Volume"),
        583: c("Set Audio Output Device"), 584: c("Set Audio Input Device"),
        585: x("Toggle Mute Microphone (Audio Input)", .toggleMuteMicrophone), 582: c("Play Sound File"),
        // Display
        28: x("Brightness Up", .brightnessUp), 29: x("Brightness Down", .brightnessDown),
        259: a("Brightness Up (Small Step)", .approximate(.brightnessUp, "AOM raises the brightness by its normal step.")),
        260: a("Brightness Down (Small Step)", .approximate(.brightnessDown, "AOM lowers the brightness by its normal step.")),
        370: c("Set Brightness"), 266: x("Toggle Mirroring", .toggleDisplayMirroring),
        120: u("External Monitor Brightness Up"), 121: u("External Monitor Brightness Down"),
        31: u("Keyboard Illumination Up"), 32: u("Keyboard Illumination Down"),
        // Spaces and Mission Control
        5: x("Mission Control", .missionControl), 6: x("Application Exposé", .appExpose), 115: x("Launchpad", .launchpad),
        113: x("Switch Space Left", .switchSpaceLeft), 114: x("Switch Space Right", .switchSpaceRight),
        527: a("Switch Space Left (No Animation)", .approximate(.switchSpaceLeft, "AOM switches with the system animation.")),
        528: a("Switch Space Right (No Animation)", .approximate(.switchSpaceRight, "AOM switches with the system animation.")),
        151: x("Move Window to Left Space", .moveWindowToPreviousSpace), 152: x("Move Window to Right Space", .moveWindowToNextSpace),
        196: u("Add New Space"), 165: u("Mission Control & Show Desktop Preview"),
        550: u("Navigate To Space Or Fullscreen App By ID or Index"),
        // Clipboard and text
        508: x("Save Clipboard Contents", .saveClipboard), 509: x("Restore Clipboard Contents", .restoreClipboard),
        480: c("Show Clipboard Manager"),
        203: a("Toggle Clipboard Manager", .approximate(.showClipboardHistory, "AOM opens its clipboard history; running it again does not close it.")),
        529: c("Set Clipboard Contents"), 256: c("Save Selected Text to Variable"),
        // Scripts (imported disabled for review)
        172: c("Run AppleScript (Blocking)"), 195: c("Run AppleScript (Background)"),
        252: c("Run JavaScript (Background)"), 253: c("Run JavaScript (Main Thread)"),
        246: c("Terminal Command (Blocking)"), 137: c("Terminal Command (Background)"),
        206: c("Shell Script Task"), 295: c("Run Apple Shortcut"),
        281: u("Run Core JavaScript", "AOM has no BTT Core JavaScript runtime."),
        600: u("Run JavaScript in Browser"), 138: u("Automator Workflow"),
        // BTT control and workflow
        248: c("Trigger Named Trigger"), 502: c("Disable Triggers for X Seconds"),
        129: c("Delay (Blocking)"), 345: c("Delay (Async / Non-Blocking)"),
        292: c("Set Variable"), 531: x("Stop All Action Sequences", .stopAllSequences),
        254: c("Show HUD"), 371: c("Show Notification"), 136: c("Post Distributed Notification"),
        354: a("Show Cheat Sheet", .approximate(.showCheatSheet, "AOM's cheat sheet lists AOM triggers with its own layout.")),
        124: c("Trigger Menu Bar Item"), 59: c("Open URL"),
        552: u("Disable Configured Trigger", "The BTT trigger UUID does not exist in AOM."),
        553: u("Enable Configured Trigger", "The BTT trigger UUID does not exist in AOM."),
        139: u("Switch to Preset"), 258: u("Toggle Preset"), 144: u("Disable Gesture Recognition"),
        335: u("Cycle Through Multiple Actions"), 346: u("Toggle On/Off"), 412: u("Increase Variable"),
        403: u("Ask For Input & Save To Variable"), 579: u("Debounce"),
        249: u("Show Floating Web View"), 327: u("Show Custom Context Menu"), 386: u("Show Floating Menu"),
        387: u("Hide Floating Menu"), 388: u("Toggle Floating Menu"),
        169: u("Take Screenshot", "BTT screenshot options do not convert to AOM capture actions."),
        170: u("Screenshot Window", "BTT screenshot options do not convert to AOM capture actions."),
        // Control flow: the whole trigger is skipped
        329: ActionInfo(name: "Start Repeat", rule: .controlFlow), 332: ActionInfo(name: "End / Stop Repeat", rule: .controlFlow),
        331: ActionInfo(name: "Break", rule: .controlFlow), 424: ActionInfo(name: "Cancel Repeat", rule: .controlFlow),
        330: ActionInfo(name: "IF Condition", rule: .controlFlow), 431: ActionInfo(name: "IF JavaScript True", rule: .controlFlow),
        705: ActionInfo(name: "IF AI Condition True", rule: .controlFlow), 405: ActionInfo(name: "IF Image Visible", rule: .controlFlow),
        428: ActionInfo(name: "IF Text Visible", rule: .controlFlow), 333: ActionInfo(name: "ELSE", rule: .controlFlow),
        334: ActionInfo(name: "END IF", rule: .controlFlow)
    ]

    /// F-key actions (F1–F20) and the modifier key down/up actions.
    static let functionKeys: [Int: Int] = [
        33: 1, 34: 2, 35: 3, 36: 4, 37: 5, 38: 6, 39: 7, 40: 8, 41: 9, 42: 10, 43: 11, 44: 12,
        130: 13, 131: 14, 132: 15, 133: 16, 134: 17, 135: 18, 303: 19, 304: 20
    ]
    static let modifierKeyActions: [Int: (key: String, down: Bool)] = [
        178: ("shift", true), 179: ("shift", false), 180: ("fn", true), 181: ("fn", false),
        182: ("control", true), 183: ("control", false), 184: ("option", true), 185: ("option", false),
        186: ("command", true), 187: ("command", false), 437: ("rightShift", true), 438: ("rightShift", false),
        439: ("rightControl", true), 440: ("rightControl", false), 441: ("rightOption", true), 442: ("rightOption", false),
        443: ("rightCommand", true), 444: ("rightCommand", false)
    ]
    /// Switch to Desktop 1–9. Desktops 10–19 (226–235) and Move Window to
    /// Desktop N (216–225, 236–245) have no AOM action.
    static let desktopSwitch: [Int: Int] = [207: 1, 208: 2, 209: 3, 210: 4, 211: 5, 212: 6, 213: 7, 214: 8, 215: 9]

    static func actionName(_ id: Int) -> String {
        if let info = actions[id], !info.name.isEmpty { return info.name }
        if let n = functionKeys[id] { return "F\(n)" }
        if (305...308).contains(id) { return "F\(id - 284)" }
        if let m = modifierKeyActions[id] { return "\(m.key.prefix(1).uppercased() + m.key.dropFirst()) \(m.down ? "Down" : "Up")" }
        if let n = desktopSwitch[id] { return "Switch to Desktop \(n)" }
        if (226...235).contains(id) { return "Switch to Desktop \(id - 216)" }
        if let n = moveToDesktop(id) { return "Move Window to Desktop \(n)" }
        return "BTT action \(id)"
    }
    static func moveToDesktop(_ id: Int) -> Int? {
        switch id {
        case 216...220: return id - 215
        case 222...225: return id - 216
        case 236...245: return id - 226
        default: return nil
        }
    }
}
