# Window snap 3.3.3: what changed since 3.3.2

Read with docs/window-snap-3.3.2.md: everything there still holds unless this page says
otherwise. Sources: the swish-titlebar and swish-dock stream notes
(`work/integration-333/`), commits b2a6307, 77ecbea, 76a0a3e, 988fedf (title bar) and
62c6127, 37dcedb, e87fa6e, 45b21a5, fe162aa, d066d36, 8108ab7 (Dock and menu bar), and the
chain wiring cebf5b8. Audit IDs are those of docs/release-3.3.3-audit-resolution.md.
Code: `TitleBarWindowSnap.swift`, `SwishSnapGrid.swift`, `SwishModifierRoles.swift`,
`SwishTabs.swift`, `WindowManager.swift` (hit-test), `TrackpadUtilityGestures.swift`,
`SwishDockMenuBarGestures.swift`, `SwishDockMenuBarSystem.swift`,
`MissionControl/MissionControlWindows.swift`.

## Multi-motion (F01)

- A swipe or pinch that rests 0.25 s (`AOMTitleBarSnapMotionPause`, 0.15…1 s; 0 = off, one
  gesture per touch as in 3.3.2) locks, with a haptic. The next movement past the engage distance
  (or a pinch ratio) from the pause point commits the locked gesture and starts the next one.
- Lifting commits as before. Resting on to 2 s cancels only the locked gesture. A third finger
  cancels the gesture on show, and so does a gap in the frames.
- A slow swipe never locks: the pause radius is 0.008 of the pad, the still radius 0.018.
- After minimize, quit, hide, full screen or a tab detach, the rest of the touch does nothing.
  After a Space move (one at a time, queued), a closed tab or the first half of a "twice"
  gesture, the touch goes on.
- Motions made while a commit lands queue (`SwishChainQueue`, up to 4, swipes or pinches) and
  apply in order to the same window.
- Not done: Swish's "double-swipe vertically" for the top and bottom halves; AOM keeps the longer
  swipe of 3.3.2.

## Tabs (F02)

| Gesture on a tab | Does |
|---|---|
| Pinch in | Close that tab: its close button, else Chromium's "close tab" action, else ⌘W posted to that app while that tab is selected in its focused window and the app is in front. Never the window. |
| Tap and hold, then lift | Native and Safari tabs in a group of 2 or more: select it, activate the app, press Window › Move Tab to New Window (any AppKit language, plus Safari's Japanese title), wait up to 1.5 s for the new window, then chain it. |

- The hit-test finds `AXTabButton`, or `AXRadioButton` inside an `AXTabGroup`.
- Close and detach: AppKit window tabs (Finder, Preview, TextEdit, Terminal, Mail …) and Safari.
  Close only: Chrome, Brave, Vivaldi, Arc, Dia, Orion, Xcode, VS Code, UPDF. Edge, Figma and
  Craft: "Tabs Not Supported Here" when their tab is detected. Firefox exposes no tabs, so a
  pinch in on its tab strip is 3.3.2's window pinch (close after 0.35 s).
- Detach runs at the lift; a gesture on the new window is the next touch within 3 s. Tap and
  hold, then swipe on a tab stays 3.3.2's held swipe.
- `AOMTitleBarSnapTabs` (on) turns both off.

## Where gestures start (F04)

- The window-server pre-filter band grew from 60 to 110 pt below a window's top
  (`tabBarBand`), so tab bars under toolbars reach the Accessibility hit-test. Content in that
  band is still refused unless the hit is a toolbar, a tab group, a window button or the top 30 pt.
- Super anywhere (`AOMTitleBarSnapSuperAnywhere`, off): while the Super role's keys are held, a
  gesture may start anywhere on another app's window.

## Modifier roles (F05)

| Role | Default | In gestures |
|---|---|---|
| Super | fn (🌐) | With Super anywhere on: start a gesture anywhere in a window |
| General | ⌥ | Swipe sideways: next Space; down: close; double tap: hide the app |
| Screen | ⌘ | Swipe: the display that way; pinch out: full screen there |
| Secondary | ⇧ | Swipe: the 3 × 2 grid (up: almost maximize); double tap: hide the others; held while dragging: keep a snapped window's size (X35) |
| Tertiary | ⌃ | Swipe: the 3 × 3 grid |

- Stored as `AOMTitleBarSnapModifierSuper` … `…Tertiary` (Int, a `ModifierKeys` raw value:
  ⌃ 1, ⌥ 2, ⇧ 4, ⌘ 8, fn 16; 0 turns a role off). The defaults keep 3.3.2's ⌥, ⌘ and ⇧
  meanings; ⇧ and ⌃ swipes are new.
- Roles may not share keys (`ModifierRoles.conflict(setting:to:)` refuses the choice); an
  unreadable stored set is reported (`loadIssue`); Restore Modifiers saves the defaults.
- Not done: Super required for all gestures (X06), Super on Dock icons.

## Keyboard (F05)

- ⌃⌥ plus the scheme's keys (arrows, WASD, IJKL, HJKL, and new ,AOE for Dvorak) swipe the front
  window, as in 3.3.2. Adding the Screen key (⌘) moves it to the display that way; adding the
  Secondary key (⇧) uses the 3 × 2 grid, where up almost-maximizes.
- The center key (`AOMTitleBarSnapHotkeyCenter`: Esc by default, ⌫, ↩ or off) with ⌃⌥ centres
  the front window or puts back its size from before the snap.
- Esc cancels a title-bar gesture on show, while AOM's keyboard event tap is installed (any
  keyboard trigger, a clipboard or capture shortcut, or the snap hotkeys).
- Hotkeys do nothing while secure keyboard entry is on (`IsSecureEventInputEnabled()`), so a
  password field never loses its keys.
- Not done: Spaces hotkeys (⌥ is part of the chord), close/quit/minimize/full-screen hotkeys
  (Swish's Advanced tab shows only the arrows and Center), and Swish's hold-and-release key
  composition (X27).

## Native tiling and other options (F06)

- Native tiling (`AOMTitleBarSnapNativeTiling`, off): halves, quarters and Fill go through the
  app's Window › Move & Resize menu on macOS 15 or later; other places, and apps without the
  menu (up to about 0.6 s later), use AOM's engine. AOM reads `com.apple.WindowManager`
  (`EnableTiledWindowMargins`, `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`) to show the
  system's options and never writes it. Native tiling cannot keep the Stage Manager offset.
- External display timeout (`AOMTitleBarSnapResnapDelay`): 1.5 s by default, 0.5…10 s; 0 turns
  re-snapping off (X38).
- Gesture tooltip (`AOMTitleBarSnapTooltip`, on, and only with the preview on): a label by the
  pointer names where lifting puts the window. No Hide Cursor, arrow images or size choice (X44).
- Not done: Include Screen Edges (X30) and the portrait 3 × 2 axis swap (X28), which change frame
  paths shared with the Dock and menu bar; live Resize Adjacent while dragging (X36, still on
  mouse-up); going back to the original display after a reconnect (X37).

## Chain (F03, F02)

`TitleBarWindowSnap.shared.beginChain(window:pid:reason:) -> Bool` (main actor):

- While a window is chained, title-bar swipes, pinches and double taps act on it wherever the
  pointer is, for the rest of the touch on the pad and for 3 s after it lifts
  (`SwishWindowChain.grace`); each touch that uses the chain extends it to its own lift + 3 s.
- Called mid-touch, the recognizer restarts that touch from the fingers' position on the next
  frame (a further motion, never a tap, not held), and the snap owns the touch: the caller stops
  acting on it.
- The chain ends when a touch lands on another window's title bar (that window is taken), on
  timeout, when AOM or the window's app is paused, when the window goes, the snap is switched off,
  or a newer chain replaces it. It refuses AOM's own windows, paused apps, a disabled or paused
  snap, and windows without a readable frame (bounded to 0.25 s).
- Callers: a detached tab, and since cebf5b8 the Dock (`TrackpadUtilityGestures.chainWindow`,
  set at launch in `AppDelegate`): the window raised by tap and hold (on release, so the chain
  applies to the next touch), each window of a sideways Dock swipe, the window restored by a swipe
  up, and the last window restored by pinching out twice; the app-menu origin too. When the snap
  takes the window, the Dock lets go of the rest of the touch.

## Dock and menu bar

Safety (S01, S02, S04, S05, B03, B06):

- Dock pinch to quit checks the target app's pause, the global pause and the screen lock right
  before the quit request and never targets AOM. `TrackpadUtilityGestures.politeQuit`, which the
  title-bar quit uses too, refuses AOM and apps AOM is paused for, whoever calls it.
- A third or fourth finger spends the touch until every finger lifts: a 2→3→2 touch does nothing,
  and a pinch still waiting is taken back. A second trackpad takes over cleanly from one that went
  quiet with spent fingers. A lost final empty frame keeps that trackpad's fingers spent until its
  next lift (one touch is swallowed on purpose: a timestamp gap is not a lift).
- Menu-bar unminimize checks each window's app pause before each write. Delayed work (the wait
  for a second pinch, ⌘N after the activation, scroll to top, the app-switcher watchdog, each
  window move) re-checks the pause, the lock and the target when it runs.
- ⇧ double tap on a Dock icon skips apps AOM is paused for; Dock and menu-bar HUD lines follow
  the On-screen HUD setting.

| Where | Gesture | Does (new in 3.3.3) |
|---|---|---|
| Dock icon | Pinch in twice / out twice | Minimize all of the app's windows / unminimize them (`AOMDockDoublePinch`, on) |
| Dock icon | Pinch in once / out once | Quit politely / ⌘N, as before, but after the 0.35 s wait for a second pinch (once 0.15 s more when the next touch lands in it), when the fingers lift at the earliest |
| Dock icon | Hold, swipes, pinch out twice | The window brought forward is chained to the title-bar snap |
| App's own menu (its name by the Apple menu) | The Dock gestures | Act on that app (`AOMAppMenuGestures`, off) |
| Empty part of the menu bar | Two-finger tap | Scroll the front window's main scroll area to the top (`AOMMenuBarScrollToTop`, off) |
| Empty part of the menu bar | Tap, hold, scroll | AOM's window switcher, or the macOS ⌘-Tab switcher held open until the lift (`AOMMenuBarSwitcher` `windows`/`apps`; not while "Disable AOM while holding ⌘" is on) |
| Empty part of the menu bar | Swipe up | Unminimize every window minimized on that display, not only AOM's (twice or ⇧: every display); AOM's newest first; skipped and failed windows stay remembered (S06) |

- Menu-bar gestures now work on the empty part of the menu bar only: `MenuBarProbe` tells the
  empty area, the app's menu, other menu titles and status items apart (Accessibility, since the
  menu bar is one window-server window). Menu titles and status items keep their own clicks.
- A Dock or Mission Control pinch runs when its fingers lift at the earliest, after the 0.35 s
  wait for a second pinch; a third finger, a 2 s rest or a quiet trackpad before then takes it
  back, and a lift more than 2 s after the pinch (`pinchLiftLimit`) runs nothing. With the double
  pinch off there is no wait, but the quit still waits for the lift.
- The ⌘-Tab switcher holds a synthetic ⌘ at the HID tap; a 0.6 s watchdog releases it, and a
  third finger cancels.
- Not done: minimized-window Dock tiles as an origin (X10); the menu-bar double tap still covers
  only windows in AOM's snap history (G31); ownership against user two-finger triggers (B07).

## Mission Control and App Exposé

- Thumbnails come from WindowManager on macOS 27 and from the Dock on 14–26
  (`MissionControlWindows`), matched to a real window by app and title.
- Gestures on a thumbnail (`AOMMissionControlGestures`, off): pinch in closes the window (twice:
  quits its app, checked again at the lift), swipe down minimizes it.
- The ✕ buttons and W / ⇧W / M / H act only on the matched window; ⇧W closes the app's windows
  and no longer asks the process that draws Mission Control to quit. All of it follows AOM's
  switch, pause, screen lock and per-app pause. `AOMMissionControlHotkeys` is read live.
- Over an ordinary app window the live lookup makes a window-server check only, so two-finger
  scrolling stays cheap.
- Not done: moving a window to another Space, and Swish's `missionControlSpace` (a Space to
  another display). On macOS 27 Mission Control ignores synthetic drags (external report,
  PaperWM.spoon #173, not reproduced); on 14–26 testing would move the user's real windows.

## Settings added in 3.3.3 (defaults)

| Key | Default |
|---|---|
| `AOMTitleBarSnapMotionPause` | 0.25 s (0 = off, 0.15…1) |
| `AOMTitleBarSnapSuperAnywhere` | off |
| `AOMTitleBarSnapModifierSuper` / `General` / `Screen` / `Secondary` / `Tertiary` | 16 (fn) / 2 (⌥) / 8 (⌘) / 4 (⇧) / 1 (⌃); 0 = role off |
| `AOMTitleBarSnapTabs` | on |
| `AOMTitleBarSnapNativeTiling` | off |
| `AOMTitleBarSnapTooltip` | on |
| `AOMTitleBarSnapResnapDelay` | 1.5 s (0 = no re-snap, 0.5…10) |
| `AOMTitleBarSnapHotkeyCenter` | `escape` (`backspace`, `return`, `off`) |
| `AOMTitleBarSnapHotkeys` | new value `dvorak` (,AOE) |
| `AOMDockDoublePinch` | on |
| `AOMAppMenuGestures` | off |
| `AOMMenuBarScrollToTop` | off |
| `AOMMenuBarSwitcher` | `windows` (`apps`: the ⌘-Tab switcher) |
| `AOMMissionControlGestures` | off |

All are in profile backups (integ-core a46dae2). Reset Preferences does not reset them yet (B05).

## Still needs a hardware check

- Multi-motion: the 0.25 s lock and its haptic, no stray second swipe from a lift after a lock,
  slow swipes never locking, swipe → pinch after a pause.
- Tabs per app: Finder, Preview and TextEdit tabs, Safari (compact and separate tab bar), Chrome
  with vertical tabs, Arc, Xcode, VS Code; close buttons on tabs that are not hovered; the ⌘W
  fallback; detach with Korean and Japanese menus.
- Native tiling on macOS 15 and 26 (Finder, Safari, TextEdit) and the fallback in an app without
  Move & Resize.
- Super anywhere with fn/🌐; Tertiary ⌃ against Accessibility zoom's ⌃-scroll; the hotkeys with
  ⌘ and ⇧, ⌃⌥Esc, and in a password field.
- Dock: 2→3→2 and 2→4→2 touches, pinch-twice timing and acting at the lift, the quit of a
  throwaway app with unsaved changes, a paused app and AOM's own icon; a Dock gesture chained
  into a title-bar gesture, and the 3 s grace against ordinary scrolling.
- Menu bar on macOS 27: empty area, the app's menu, other titles and status items, on several
  displays, with a hidden menu bar and in full-screen apps; scroll to top in Safari, Chrome,
  Finder, Mail, Notes, Xcode and an Electron app; the held ⌘-Tab switcher never leaving ⌘ stuck;
  S06 with many minimized windows on two displays.
- Mission Control and App Exposé on macOS 27 and on 14–26: thumbnail hit-tests, the ✕ overlay on
  several displays, close, minimize, quit twice, W/⇧W/M/H.
- Tooltip placement across displays.
