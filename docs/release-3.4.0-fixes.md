# 3.4.0: defects fixed in existing features (audit J)

Branch `j/340` from `70490b4`. Every row names the code as it was in `70490b4`, what goes wrong for a person,
the change, and the test that checks it. Nothing here was tried on a real trackpad, mouse, keyboard, HomePod or
with a real AppleScript target; the tests use the existing seams (injected clocks, stub readers, private
pasteboards, temporary folders, throwaway defaults suites) and never post events, send Apple events or touch an
audio device.

Test rule (the user's): only the new tests, the two existing tests whose expectations changed, and the one test
that failed were run. Results:

- `/Users/kim-yong-woo/aom-335-kit/j340-tests-1.log`: 39 tests, 38 passed, 1 failed. The failure was the new test's
  own comparison of two spellings of one temporary folder (`/private/var/…` and `/var/…`); the code returned the
  right backup. The assertion now compares file names.
- `/Users/kim-yong-woo/aom-335-kit/j340-tests-2.log`: that test and one new test, 2 passed.
- `/Users/kim-yong-woo/aom-335-kit/j340-build-3.log`: build after the last change (no tests matched), succeeded.

At about 23:30 the kit folder was in the Trash for a few minutes; the second run and the build went through a copy
of `test.sh`/`slot.sh` at `/tmp/j340-run-tests.sh` that takes the same two `/tmp/aom-build-slot-*` locks (its own
slot log: `j340-manual-slots.log`).

## Fixed

| # | Area | Defect (in 70490b4) | Fix | Test (Audit340…) |
|---|---|---|---|---|
| 1 | Typed strings | With **Pause AOM** on (or AOM paused for the front app) an abbreviation's last key was still swallowed, the abbreviation erased and the replacement typed. `processTypedString` (KeyboardMonitor.swift:508) asked `AutomationGate.isOn` only, and the replacement path (537) never reaches `TriggerGate`, where pauses are checked; an action-only abbreviation was erased and then refused there. | `typedStringExpansionAllowed()` asks `TriggerSuppression` before anything that reads the screen or AppKit. | InputTests `testTypedStringsStayQuietWhileAOMIsPaused`, `…InAnAppAOMIsPausedFor` |
| 2 | Key sequences | After macOS turned the keyboard tap off (a slow callback) a modifier released in the gap stayed "held" in the sequence detector, so double-tap or hold triggers on it stopped until the front app changed, and a hold could fire for a key already up. The disabled branch (290) called `releaseKeys()`, which left the detector alone. | `releaseKeys()` resets the detector; the branch calls `tapWasDisabled()`. | `testADisabledTapLeavesNoModifierHeld` |
| 3 | Key sequences | Releasing left ⌘ while right ⌘ was held read as a second press of left ⌘ (both sides share `maskCommand`, 342), which then stayed held: every ⌘ sequence failed. Same for ⇧ ⌥ ⌃. | `modifierIsDown(keyCode:flags:)` reads each side's device bit (IOLLEvent.h), with the generic flag as fallback. | `testReleasingOneSideOfAModifier…`, `testBothCommandKeysThroughTheMonitor…` |
| 4 | Shortcuts | A shortcut held slightly long whose action switched apps (⌥Space → Terminal) leaked its autorepeat into the new app: the 4 Hz secure-input poll calls `releaseKeys()` on every app change (SecureInputHotKeys.swift:113), and `handleInput` then let repeats through (457). | Keys let go that way keep their autorepeat swallowed until their key-up or a fresh press. | `testTheAutorepeatOfAShortcutLetGoEarlyStaysSwallowed` |
| 5 | Hyper key | A F18 key-up lost while the tap was disabled left Hyper held: every later key got ⌃⌥⇧⌘ until F18 was pressed again (InputRemapping.swift:274 only re-enabled the tap). | On re-enable the held state is read from the key (`CGEventSource.keyState`); still down counts as used, so no stray Escape. | `testTheHyperKeyIsNotLeftHeldAfterADisabledTap` |
| 6 | Normal Mouse | Same gap for the mouse tap (MouseButtonMonitor.swift:226): the recognizer kept the press and its wake timer, so a long press (or drag) fired for a button already released. | `tapWasDisabled()`: wake cancelled, recognizer reset, only buttons still down keep a swallowed release. | `testALongPressCannotFireForAButtonReleasedWhileTheTapWasOff` |
| 7 | Mission Control | The ✕ buttons kept appearing over Mission Control while AOM was paused (the poll guard, MissionControlOverlayService.swift:59, did not ask the pause; a click then did nothing). | `shouldProbe(…paused…)` in the poll and its result; the window server is asked last. | GestureTests `testTheMissionControlPollerHonours…` |
| 8 | Mission Control | With "Mission Control ✕ buttons" off, the W/⇧W/M/H keys never worked (they act only while the poller reports Mission Control open, KeyboardMonitor.swift:397, and the poller started only with the buttons on, AppDelegate.swift:704). Turning the buttons on later needed a relaunch. | The poller runs while either setting is on and follows Settings (`followSettings`, started from `MissionControlHotKeyHandler.start`); tiles only with the buttons on. | same test (pure rule); not tried in Mission Control |
| 9 | Trackpad (N333-08 reverse) | A user two-finger trigger that ran first in a touch could be followed by a Dock or menu-bar gesture in the same touch (TrackpadMonitor fired, 1479, and never told the utility layer; release-3.3.4-audit-resolution.md lists it as open). | After a trigger for a two-finger gesture the utility layer also answers, the monitor calls `TrackpadUtilityGestures.triggerEngineTookTouch()`: a waiting pinch is taken back, a switcher closes without switching, no Space switches, the claim ends, the fingers stay spent until they lift. Clicks, rotations, Touch Start/Release stay both layers', as before. | GestureTests (4) |
| 10 | Clipboard | The pasteboard poller woke 13 times a second with Clipboard History off or paused (ClipboardStore.swift:310; the only start/stop is AOM's master switch, AppState.swift:439), for nothing it would keep. | 75 ms while recording, 60 s otherwise (the retention trim still runs); rescheduled when history or the pause changes. | ClipboardTests `testThePollerSlowsDown…`, `testResumingAfterASlowPause…` |
| 11 | Clipboard (N333-03 follow-up) | Suggestions already on the shelf stayed when the destination app was excluded, an app an item came from was excluded, or Intelligent Clipboard was turned off (only pending answers were checked again, ClipboardIntelligence.swift:827). | The last published answer is kept and withdrawn (`update([])`) when the store's settings, the switch or `.aomSettingChanged` make the policy refuse it. | ClipboardTests (4) |
| 12 | Automations | A master preset AOM could not read (a newer AOM's file, damage) was copied aside only when the database had the automations too (PresetManager.swift:635). A fall back to a backup or an empty start kept nothing, the first edit overwrote the file, and launch said nothing. | The file is copied aside before any fallback; if no copy can be made, master writes are refused for the session (`PresetWriteBlocked`); launch shows "Automations Could Not Be Read" with where the copy is. | PersistenceTests `testAnUnreadablePresetIsKept…`, `…CannotBeCopiedIsNeverOverwritten`, `testLaunchSaysWhat…` |
| 13 | Backups | Only the newest backup was tried (612): one unreadable backup hid every older one. | Newest to oldest until one reads. | `testAnUnreadableNewestBackupDoesNotHideAnOlderOne` |
| 14 | Backups | Every launch saves the preset again (AppState.swift:99) and every save wrote a rolling backup (312), so five unchanged launches pushed every older version out (a read-only check during this audit reported five byte-identical rolling backups on this Mac; not re-verified). | A save whose preset and settings equal the newest rolling backup keeps that backup; safety snapshots are always written. | `testASaveThatChangedNothingKeepsTheOlderBackups`; ProfileBackupRestoreTests `testAForeignFile…` now saves different presets |
| 15 | Pause rules | Reset Preferences and Restore Backup changed the suppression rules underneath; the rules read at launch stayed in force and the next edit wrote them back (TriggerSuppression.swift:136). | Reloaded on `.aomSettingChanged`, without writing back. | `testAResetIsNotUndoneByTheSuppressionRules…` |
| 16 | Clipboard prefs | After a reset, link previews went on fetching until relaunch (ClipboardPreferences.swift:43 read once). | Reloaded on `.aomSettingChanged`. | `testClipboardPreferencesFollowAReset` |
| 17 | Variables | Restore Backup wrote the backup's workflow variables; the copy cached at launch (WorkflowSupport.swift:45) put the old ones back at the next script result or Set Variable. | Read through to the defaults. | `testRestoredVariablesAreNotOverwritten…` |
| 18 | Script results | A result the variables refused (a name over 55 characters, so `_exitCode` passed 64; non-ASCII; 128 variables) was dropped silently (ScriptActionResults.swift:8) and an If/Else read the previous value. | Logged with the reason; `record` returns whether all three were stored. | `testAScriptResultThatCannotBeStoredSaysSo` |
| 19 | Apple Events | Toggle Dark Mode and Dock hiding said "allow AOM to control System Events" for any failure (a timeout, an app that quit); Empty Trash, Log Out and the person's AppleScript/JavaScript logged only "Script completed (exit 1)". Nothing handled -600. | `AppleEventFailure` reads -1743, -1744, -600, -1712 and the app from osascript's output; a HUD (once a minute per advice) says what to do, e.g. "Allow All of MacOS to control “Finder” in System Settings › Privacy & Security › Automation". AOM's own commands send once more after -600 (the event never arrived, so a toggle has not toggled); the person's scripts are only explained, never re-run. | SystemTests (5) |
| 20 | AppleScript | `run trigger "Typo"` returned normally although nothing ran (the command handed the link on asynchronously, AOMScripting.swift:68). | Missing or ambiguous names fail in the script with a reason. | `testRunTriggerFailsInTheScript…` |
| 21 | Actions | Toggle Application given an app name that was not running never launched it: the name was looked up among the apps that open a folder (ActionExecutor.swift:680). | Standard application folders, then Launch Services. | `testAnAppGivenByNameIsFound…` |
| 22 | HomePod (steer-fd2aa586) | The HomePod keeps 128-frame IO whatever AOM asks; AOM set the IO size on its running IO every 10 minutes for the whole session (6 an hour, AirPlayOutputRenderer.swift:215; each set may restart its IO, a gap). D-340's patch #1. | Asked at most twice, then left alone; each request is a `bufferSize` event in audio-health.json. | SystemTests `testAHomePod…`; AirPlayRobustnessTests `testIOBufferIsRequestedAgain…` (expectation 9 → 2) |
| 23 | Clipboard (steer-f9dff59d) | The detached preview window renamed on a double-click (ClipboardPreferences.swift:200); Paste and, since B's 729f45e, the shelf's preview take one click. | One click; Return saves, Escape cancels, clicking elsewhere saves (unchanged). | none (SwiftUI gesture); built |
| 24 | Action picker | Five pin actions had two descriptions; the older ones came first (ActionCatalog.swift:27–30), so the newer wording (69–72, "Escape cancels") never showed. | Older copies removed. | `testThePinActionsShowTheirCurrentDescriptions` |
| 25 | Deprecations (macOS 14+) | `activate(options: .activateIgnoringOtherApps)` (ActionExecutor.swift:890, WindowPinningService.swift:200, 226): the option has no effect since macOS 14. `launchApplication(_:)` (561) sat in unreachable cases. | Option dropped (no change in behaviour), dead cases removed. `fullPath(forApplication:)` stays only as the last fallback for an app outside the standard folders (AppKit has no other lookup by name). | compile only |

## Not done, or still needs a person

- **HomePod:** listening on a HomePod with `AOMAudioDiagnostics` on (docs/airplay-crackle-3.3.2.md). Not changed: the
  bridge's fade-in after a forward sample-time jump (D-340 #3: tell a skipped cycle from a timeline re-anchor by the
  callback's host time; needs the log comparison first), Magic Boost on the AirPlay bus (D-340 #2: needs the
  user's A/B with Boost off). B's 6237a2d (dropout softener, wired buffers) is a separate change.
- **Mission Control keys:** W/⇧W/M/H still run their Accessibility requests inside the keyboard tap callback
  (bounded: 0.25 s hit test, 0.5 s window lookup, 1 s for ⇧W), so a hung app can stall typing for up to about 2 s.
  Proposal: decide from the poller's cached thumbnails and run the request off the tap. The poller itself asks
  WindowManager and the Dock 4 times a second while Mission Control is closed (Mission Control Plus works the same
  way); an event-driven start was not verified on macOS 27.
- **Suggestions:** Secure Keyboard Entry turning on while the shelf shows suggestions does not withdraw them (no
  notification exists and no polling was added); a secret is never suggested in the first place.
- **Version skew (left as is):** an unknown capture kind makes CaptureHistory rebuild a degraded manifest; an
  undecodable clipboard settings blob falls back to defaults; annotation style presets and the window-pin journal
  decode to empty. Each needs a newer build writing what an older one reads.
- **Kept on purpose:** the migrated gesture archive `AOMGestureEvents` (about 140 KB of the preferences file) is
  kept by design (GestureStatisticsTests asserts it); CaptureHistory never deletes orphan PNGs (a sweep would delete
  user captures permanently, which the brief does not allow).
- **Performance notes:** the Hyper key and wheel reverser taps run on the main run loop; PermissionWatchdog checks
  Accessibility every 2 s; WindowPinningService's tick reads every window on every Space 6.7 times a second while a
  window is pinned.
- Sanitizer runs for N333-02, and every hardware check listed in CHANGELOG 3.3.3–3.3.4, are still open.

## For other owners

Insertions and findings outside J's files are in `/Users/kim-yong-woo/aom-335-kit/j-340.md` (Apple Events in
SystemTools and MacMagic, the menu-command reset notice) and `/Users/kim-yong-woo/aom-335-kit/audit340-views.md`
(view-layer findings).
