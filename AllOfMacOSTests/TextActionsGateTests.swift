import ApplicationServices
import XCTest
@testable import AllOfMacOS

/// Text Actions privacy rules, fed with attribute snapshots and environment
/// values: password fields, secure input, excluded apps, Pause AOM, the ⌘C
/// fallback, file drags and window drags.
final class TextActionsGateTests: XCTestCase {
    private var settings: TextActionsSettings = {
        var settings = TextActionsSettings()
        settings.isOn = true
        return settings
    }()

    private func environment(_ edit: (inout TextActionsEnvironment) -> Void = { _ in }) -> TextActionsEnvironment {
        var environment = TextActionsEnvironment(isTrusted: true, automationOn: true, paused: false, secureInput: false,
                                                 screenLocked: false, bundleID: "com.apple.TextEdit")
        edit(&environment)
        return environment
    }

    private func attributes(role: String? = "AXTextArea", subrole: String? = nil, text: String? = "hello") -> TextSelectionAttributes {
        var attributes = TextSelectionAttributes()
        attributes.role = role
        attributes.subrole = subrole
        attributes.selectedText = text
        return attributes
    }

    // MARK: Double-click is not selection proof

    func testDoubleClickNeverDisplaysRetainedUnchangedSelection() {
        let box = CGRect(x: 120, y: 140, width: 75, height: 18)
        for gesture: TextSelectionMonitor.Gesture.Kind in [.doubleClick, .tripleClick] {
            XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: gesture,
                anchorAvailable: true, sameElement: true,
                initialRange: nil, finalRange: nil, initialText: "old selected word",
                finalText: "old selected word", finalBounds: box, pointer: CGPoint(x: 900, y: 900)))
            XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: gesture,
                anchorAvailable: false, sameElement: false,
                initialRange: nil, finalRange: nil, initialText: nil,
                finalText: "stale AXWebArea text", finalBounds: nil,
                pointer: CGPoint(x: 150, y: 145)))
            XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: gesture,
                anchorAvailable: true, sameElement: false,
                initialRange: nil, finalRange: nil, initialText: nil,
                finalText: "stale AXWebArea text",
                finalBounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
                pointer: CGPoint(x: 150, y: 145)))
            XCTAssertFalse(TextActionsGate.mayUseCopyFallback(automatic: true, gesture: gesture))
        }
    }

    func testDoubleClickShowsOnlyConfirmedFreshTextSelection() {
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: true, sameElement: true,
            initialRange: TextSelectionRange(location: 10, length: 0),
            finalRange: TextSelectionRange(location: 10, length: 5),
            initialText: "", finalText: "hello", finalBounds: nil,
            pointer: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: true, sameElement: true,
            initialRange: nil, finalRange: nil,
            initialText: "", finalText: "hello", finalBounds: nil,
            pointer: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: true, sameElement: false,
            initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "hello",
            finalBounds: CGRect(x: 100, y: 100, width: 40, height: 18),
            pointer: CGPoint(x: 120, y: 110)))
        XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: true, sameElement: true,
            initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "stale", finalBounds: nil,
            pointer: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .drag,
            anchorAvailable: false, sameElement: false,
            initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "normal drag", finalBounds: nil, pointer: nil))
    }

    func testProtectedAndMediaTargetsDenyCopyFallback() {
        let secure = kAXSecureTextFieldSubrole as String
        for (role, subrole): (String?, String?) in [
            ("AXTextField", secure), ("AXSecureTextField", nil),
            ("AXTable", nil), ("AXList", nil), ("AXVideo", nil) ] {
            XCTAssertTrue(TextActionsGate.isForbiddenSelectionTarget(role: role, subrole: subrole))
            XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: role ?? "", subrole: subrole, text: nil),
                settings: settings, automatic: false, environment: environment()))
        }
        XCTAssertTrue(TextActionsGate.isMediaSurface(role: "AXGroup", identifier: "movie_player",
            htmlTag: nil, domClasses: []))
        XCTAssertTrue(TextActionsGate.isMediaSurface(role: "AXGroup", identifier: nil,
            htmlTag: "video", domClasses: []))
        XCTAssertTrue(TextActionsGate.isMediaSurface(role: "AXGroup", identifier: nil,
            htmlTag: nil, domClasses: ["ytp-chrome-controls"]))
        XCTAssertFalse(TextActionsGate.isMediaSurface(role: "AXStaticText", identifier: nil,
            htmlTag: "span", domClasses: ["comment-text"]))
    }

    // MARK: Before anything is read

    func testAllowedWhenEverythingIsFine() {
        XCTAssertNil(TextActionsGate.check(environment(), settings: settings, automatic: true))
    }

    func testTheMasterSwitchStopsAutomaticTriggersButNotTheShortcut() {
        var off = settings
        off.isOn = false
        XCTAssertEqual(TextActionsGate.check(environment(), settings: off, automatic: true), .switchedOff)
        XCTAssertNil(TextActionsGate.check(environment(), settings: off, automatic: false))
    }

    func testPauseAOMStopsEverything() {
        XCTAssertEqual(TextActionsGate.check(environment { $0.automationOn = false }, settings: settings, automatic: false), .paused)
        XCTAssertEqual(TextActionsGate.check(environment { $0.paused = true }, settings: settings, automatic: true), .paused)
    }

    func testSecureInputAndTheLockScreen() {
        XCTAssertEqual(TextActionsGate.check(environment { $0.secureInput = true }, settings: settings, automatic: false), .secureInput)
        XCTAssertEqual(TextActionsGate.check(environment { $0.screenLocked = true }, settings: settings, automatic: false), .screenLocked)
    }

    func testExcludedAppsAreMatchedLikeTheClipboardDoes() {
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                   "com.apple.keychainaccess", "com.apple.Passwords", " COM.APPLE.PASSWORDS "] {
            XCTAssertEqual(TextActionsGate.check(environment { $0.bundleID = id }, settings: settings, automatic: false), .excludedApp, id)
        }
        var edited = settings
        edited.excludedApps = ["com.tinyspeck.slackmacgap"]
        XCTAssertEqual(TextActionsGate.check(environment { $0.bundleID = "com.tinyspeck.slackmacgap" }, settings: edited, automatic: true),
                       .excludedApp)
        XCTAssertNil(TextActionsGate.check(environment { $0.bundleID = "com.apple.Passwords" }, settings: edited, automatic: true),
                     "the person removed it from the list")
        XCTAssertNil(TextActionsGate.check(environment { $0.bundleID = nil }, settings: settings, automatic: true))
    }

    func testNeverInAOMItself() {
        for id in ["com.kyw.allofmacos", "com.kyw.allofmacos.preview"] {
            XCTAssertEqual(TextActionsGate.check(environment { $0.bundleID = id }, settings: settings, automatic: false), .ownApp)
        }
    }

    func testWithoutAccessibilityNothingIsRead() {
        XCTAssertEqual(TextActionsGate.check(environment { $0.isTrusted = false }, settings: settings, automatic: true), .noAccessibility)
    }

    func testPrivacyRulesComeBeforeAccessibility() {
        // A password manager is never even reported as "needs Accessibility".
        let blocked = TextActionsGate.check(environment { $0.isTrusted = false; $0.bundleID = "com.bitwarden.desktop" },
                                            settings: settings, automatic: true)
        XCTAssertEqual(blocked, .excludedApp)
    }

    // MARK: What Accessibility returned

    func testPasswordFieldsAreNeverRead() {
        let secure = kAXSecureTextFieldSubrole as String
        XCTAssertEqual(TextActionsGate.check(attributes(role: "AXTextField", subrole: secure, text: "hunter2")), .passwordField)
        XCTAssertEqual(TextActionsGate.check(attributes(role: secure, subrole: nil, text: "x")), .passwordField,
                       "some apps put it in the role")
        XCTAssertTrue(TextActionsGate.isPasswordField(role: nil, subrole: "AXSecureTextField"))
        XCTAssertFalse(TextActionsGate.isPasswordField(role: "AXTextField", subrole: "AXSearchField"))
    }

    func testBlankSelectionsShowNothing() {
        XCTAssertEqual(TextActionsGate.check(attributes(text: "")), .noSelection)
        XCTAssertEqual(TextActionsGate.check(attributes(text: " \n\t")), .noSelection)
        XCTAssertEqual(TextActionsGate.check(attributes(text: nil)), .noSelection)
        XCTAssertNil(TextActionsGate.check(attributes(text: "hello")))
    }

    // MARK: Reading with ⌘C

    func testCopyFallbackIsOffUntilTurnedOnButTheShortcutMayUseIt() {
        let nothing = attributes(role: "AXWebArea", text: nil)
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(nothing, settings: settings, automatic: true, environment: environment()))
        XCTAssertTrue(TextActionsGate.mayReadWithCopy(nothing, settings: settings, automatic: false, environment: environment()))
        var on = settings
        on.readsWithCopy = true
        XCTAssertTrue(TextActionsGate.mayReadWithCopy(nothing, settings: on, automatic: true, environment: environment()))
        XCTAssertTrue(TextActionsGate.mayReadWithCopy(nil, settings: on, automatic: true, environment: environment()),
                      "an app with no focused element at all")
    }

    func testChatGPTWebSelectionMayRecoverByCopyWithoutGloballyEnablingCopy() {
        let unreadable = attributes(role: "AXWebArea", text: nil)
        for id in ["com.openai.codex", "COM.OPENAI.CODEX", "com.openai.chat", "com.openai.chatgpt"] {
            XCTAssertTrue(TextActionsGate.mayReadWithCopy(unreadable, settings: settings, automatic: true,
                                                          environment: environment { $0.bundleID = id }), id)
        }
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(unreadable, settings: settings, automatic: true,
                                                       environment: environment { $0.bundleID = "com.google.Chrome" }),
                       "other apps still require explicit permission for automatic clipboard reads")
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(unreadable, settings: settings, automatic: true,
                                                       environment: environment { $0.bundleID = "com.openai.codex"; $0.secureInput = true }))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXTextField", subrole: kAXSecureTextFieldSubrole as String,
                                                                  text: nil), settings: settings, automatic: true,
                                                       environment: environment { $0.bundleID = "com.openai.codex" }))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXTable", text: nil), settings: settings,
                                                       automatic: true, environment: environment { $0.bundleID = "com.openai.codex" }))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(unreadable, settings: settings, automatic: true,
                                                       environment: environment { $0.bundleID = "com.openai.codex"; $0.paused = true }))
    }

    func testCopyFallbackNeverRunsWherePrivacyOrFilesSayNo() {
        var on = settings
        on.readsWithCopy = true
        let secure = attributes(role: "AXTextField", subrole: kAXSecureTextFieldSubrole as String, text: nil)
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(secure, settings: on, automatic: true, environment: environment()))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXWebArea", text: nil), settings: on, automatic: true,
                                                       environment: environment { $0.secureInput = true }))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXWebArea", text: nil), settings: on, automatic: true,
                                                       environment: environment { $0.bundleID = "com.1password.1password" }))
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXOutline", text: nil), settings: on, automatic: true,
                                                       environment: environment()), "a Finder file list")
        XCTAssertFalse(TextActionsGate.mayReadWithCopy(attributes(role: "AXTextArea", text: "already read"), settings: on,
                                                       automatic: true, environment: environment()), "Accessibility had the text")
    }

    func testOnlyTextCountsAsACopiedSelection() {
        XCTAssertEqual(TextActionsGate.copiedText(string: "hello", types: ["public.utf8-plain-text"]), "hello")
        XCTAssertNil(TextActionsGate.copiedText(string: "Report.pdf", types: ["public.file-url", "public.utf8-plain-text"]),
                     "Finder copies file names as text with the files")
        XCTAssertNil(TextActionsGate.copiedText(string: nil, types: ["public.png"]))
        XCTAssertNil(TextActionsGate.copiedText(string: "  ", types: ["public.utf8-plain-text"]))
    }

    // MARK: Drags that select nothing

    func testADragThatChangedNothingMovedAWindow() {
        let range = TextSelectionRange(location: 10, length: 5)
        XCTAssertTrue(TextActionsGate.isUnchangedSelection(anchor: range, final: range, sameElement: true))
        XCTAssertFalse(TextActionsGate.isUnchangedSelection(anchor: range, final: TextSelectionRange(location: 10, length: 9),
                                                            sameElement: true), "the drag extended the selection")
        XCTAssertFalse(TextActionsGate.isUnchangedSelection(anchor: range, final: range, sameElement: false), "another field")
        XCTAssertFalse(TextActionsGate.isUnchangedSelection(anchor: TextSelectionRange(location: 3, length: 0),
                                                            final: TextSelectionRange(location: 3, length: 0), sameElement: true))
        XCTAssertFalse(TextActionsGate.isUnchangedSelection(anchor: nil, final: range, sameElement: true))
    }

    @MainActor
    func testWhichMouseUpsEndASelection() {
        let all = TextSelectionMonitor.Options(drag: true, clicks: true, keyboard: false)
        func kind(clicks: Int = 1, distance: CGFloat = 0, flags: NSEvent.ModifierFlags = [], dragged: Bool = false,
                  options: TextSelectionMonitor.Options = all) -> TextSelectionMonitor.Gesture.Kind? {
            TextSelectionMonitor.gesture(clickCount: clicks, distance: distance, flags: flags, dragged: dragged, options: options)
        }
        XCTAssertEqual(kind(distance: 40), .drag)
        XCTAssertNil(kind(distance: 2), "a plain click selects nothing")
        XCTAssertEqual(kind(clicks: 2), .doubleClick)
        XCTAssertEqual(kind(clicks: 3), .tripleClick)
        XCTAssertEqual(kind(flags: .shift), .shiftClick, "⇧-click extends a selection")
        XCTAssertNil(kind(distance: 40, dragged: true), "a file or text drag and drop")
        XCTAssertNil(kind(distance: 40, flags: .command), "⌘-drag")
        XCTAssertNil(kind(clicks: 2, flags: .control), "⌃-click is a right click")
        XCTAssertNil(kind(clicks: 2, options: .init(drag: true, clicks: false)), "double-click trigger off")
        XCTAssertNil(kind(distance: 40, options: .init(drag: false, clicks: true)), "drag trigger off")
    }

    @MainActor
    func testWhichSelectionsAreComparedWithTheMouseDown() {
        // A window drag or a title-bar double click leaves the selection as it was.
        XCTAssertTrue(TextSelectionMonitor.comparesWithMouseDown(.drag))
        XCTAssertTrue(TextSelectionMonitor.comparesWithMouseDown(.doubleClick))
        XCTAssertTrue(TextSelectionMonitor.comparesWithMouseDown(.tripleClick))
        XCTAssertFalse(TextSelectionMonitor.comparesWithMouseDown(.shiftClick), "⇧-click always changes the selection")
        XCTAssertFalse(TextSelectionMonitor.comparesWithMouseDown(.keyboard))
        // The second and third clicks keep the first click's reading.
        XCTAssertTrue(TextSelectionMonitor.startsNewAnchor(clickCount: 1))
        XCTAssertFalse(TextSelectionMonitor.startsNewAnchor(clickCount: 2))
        XCTAssertFalse(TextSelectionMonitor.startsNewAnchor(clickCount: 3))
    }
}
