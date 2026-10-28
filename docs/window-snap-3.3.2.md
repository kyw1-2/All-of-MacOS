# Window snap 3.3.2: Swish parity

AOM's own implementation of Swish 1.13's trackpad gestures, recovered from its
settings strings and help texts (no vendor code). Code: `TitleBarWindowSnap.swift`
(recognizer and service), `SwishSnapGrid.swift` (grid, chaining, frames),
`SwishDockMenuBarGestures.swift` and `TrackpadUtilityGestures.swift` (Dock and
menu bar). Two fingers on the trackpad; the pointer decides where the gesture acts.

## Title bar (and toolbar) of another app's window

| Gesture | Does |
|---|---|
| Swipe ← / → | Left / right half; on a snapped window, chains (below) |
| Swipe ↑ | Maximize (almost maximize when on); longer: top half |
| Swipe ↓, free window | Minimize (setting: Center); longer: bottom half |
| Swipe ↓, maximized | Put back the pre-snap frame; longer: bottom half |
| Diagonal or L-shaped swipe | That quarter, from anywhere |
| Pinch in | Close the window (waits 0.35 s); twice, or after tap and hold: quit the app politely |
| Pinch out | Enter / leave full screen; with 2+ displays twice, ⌘ or after tap and hold: full screen on the other display |
| Double tap | Unsnap (pre-snap frame) or centre; ⌥: hide the app, ⇧: hide the others |
| Tap and hold 0.45 s, then ↑ / ↓ / ← → | Full screen / minimize / move to the next Space |
| ⌥ swipe ← → / ↓ | Move to the next Space / close (rest first, or twice: quit) |
| ⌘ swipe | Move to the display that way, keeping the cell |
| Rest still 2 s | Cancel, before or after the swipe engaged (the preview fades over the last second) |
| ⌃⌥ + arrows / WASD / IJKL / HJKL | The same as a swipe on the front window (off by default) |
| Drag a snapped window by its title bar | Back to its size from before the snap |

A tap never snaps. A quick flick that engaged commits: after engaging, a lift is a
tap only below `min(6.5 %, 0.6 × engage)` of the pad. Engage is 5 % ÷ sensitivity
(Quick, the default: 4 %).

## Dock (pointer on an app's icon)

| Gesture | Does |
|---|---|
| Tap and hold, then lift | Activate the app and raise its front window |
| Swipe ← / → | Activate it, then step through its windows (chains) |
| Swipe ↓ / ↑ | Minimize the front window / unminimize the one AOM minimized last (⇧: all) |
| Double tap | Hide the app (⇧: hide the others) |
| Pinch out / in | ⌘N in the app / ask it to quit (Dock pinch to quit) |
| Rest still 2 s | Cancel |

## Menu bar (top 12 pt of a display, no ordinary window under it)

| Gesture | Does |
|---|---|
| Swipe ← / → | Switch Space when the fingers lift (top-bar Space swipe) |
| Tap and hold, then ← / → | Previous / next app (chains) |
| Tap and hold, then lift or scroll | Window switcher (lifting takes the selection) |
| Double tap | Unsnap the windows AOM snapped on this display (⇧: every display) |
| Swipe ↓ / ↑ | Minimize / unminimize this display's windows (twice or ⇧: every display) |
| ⌘ swipe | Move this display's snapped windows to the display that way |
| Rest still 2 s | Cancel, also after a Space swipe before lifting |

With the menu bar hidden, in a full-screen app or on a display without a menu bar,
an ordinary window's title bar can lie in the top band: the swipe there is the
title-bar snap's, and no Space switches.

## Chaining

Every grid has halves, quarters and maximize. A place the current grid cannot
produce (a third after switching to 2 × 2) counts as free-floating.

| From | Swipe | Goes to |
|---|---|---|
| Free or centred | ← → / ↑ / ↓ | Half (longer: a third with thirds on) / maximize (longer: top half) / minimize, or centre with *Center* (longer: bottom half); with *Center*, a centred window swiped ↓ goes back |
| Maximized | ← → / ↑ / ↓ | Half / stays / pre-snap frame (longer: bottom half) |
| Almost maximized | ↑ / ← → / ↓ | Maximize / half / pre-snap frame (longer: bottom half) |
| Left or right half | ↑ ↓ / away from its edge / toward it | Top or bottom quarter / the other half / stays (2 × 2) or third → two thirds → half (3 × 2, 3 × 3) |
| Top or bottom half | ← → / ↓ from the top / ↑ from the bottom / outward | That quarter / bottom half / top half / maximize or pre-snap frame |
| Quarter | Toward the other row or column / toward an edge it touches | Moves there / grows to the half along that edge |
| Any | L or diagonal | That quarter |
| Third (3 × 2) | ↑ ↓ | Its upper or lower sixth; sixths move one cell and grow to two sixths toward an edge |
| Third (3 × 3) | ↑ ↓ | Its top or bottom ninth; a ninth grows to two-ninths, then four-ninths |

A swipe that engages while the previous commit is still landing is kept and
applied to the same window, from where it landed.

## Settings (Window Tiling › Trackpad Gestures; defaults)

| Key | Default |
|---|---|
| `AOMTitleBarSnapEnabled` | off |
| `AOMTitleBarSnapSensitivity` | 1.25 (Quick; 0.5…2) |
| `AOMTitleBarSnapGrid` | unset = 2 × 2, no thirds (`2x2`, `3x2`, `3x3`; unset follows the older `AOMTitleBarSnapThirds`) |
| `AOMTitleBarSnapDownAction` | `minimize` (`center` as in 3.3.1) |
| `AOMTitleBarSnapPinch` / `AOMTitleBarSnapHold` / `AOMTitleBarSnapModifiers` | on / on / on |
| `AOMTitleBarSnapDoubleTap` | `restoreOrCenter` (`center`, `off`) |
| `AOMTitleBarSnapHoldCancel` | 2 s (0 = off, 0…10; picker 0.5…3 s) |
| `AOMTitleBarSnapAlmost` / `AOMTitleBarSnapHotkeys` | off / `off` |
| `AOMTitleBarSnapDragUnsnap` / `AOMTitleBarSnapResnap` / `AOMTitleBarSnapResizeAdjacent` | on / on / on |
| `AOMTitleBarSnapMargin` / `AOMTitleBarSnapStageManagerOffset` | 0 pt (0…24) / 0 pt (0…200) |
| `AOMTitleBarSnapAnimation` / `AOMTitleBarSnapPreview` / `AOMTitleBarSnapHaptic` | `normal` / on / on |
| `AOMTitleBarSnapActivate` / `AOMTitleBarSnapKeepPointer` | on / off |
| `AOMTopBarSpaceSwipe` / `AOMDockPinchQuit` / `AOMDockGestures` / `AOMMenuBarGestures` | on / on / on / on |

## Safety rules

- AOM never acts on its own windows or itself, and never force-quits: quits go
  through the app's own Quit, so an app can ask to save.
- Every gesture obeys AutomationGate: the master switch, a timed or indefinite
  pause, the per-app pause (also for the app whose window is acted on while
  another app is in front), held modifiers, palm rejection, and the screen lock.
- A third finger, sleep, a second trackpad's frames or a gap in the stream cancel
  instead of acting; a 2 s rest cancels.
- A two-finger touch that lands on a title bar belongs to the snap: BTT-style
  triggers on two-finger swipes, pinches (while pinch gestures are on), taps and
  double taps (while double tap is on) and long touches (while tap and hold is
  on) do not fire for it.
- Accessibility work on main is bounded: the title-bar hit-test goes to the
  window's owner (PID from the window server), 0.25 s per request and 0.3 s per
  walk; window lists 0.5 s per request and 1 s in all. The process-wide timeout
  (the system-wide element's) is never set; a source test checks.

## Still needs a hardware check

- Flick feel at each sensitivity, the tap guard and the 0.018 still radius with a
  resting hand; pinch and double-tap thresholds.
- Hit-tests and commits against busy apps (browser tab strips, Electron), the
  polled commit of apps that animate, and a chained swipe after a slow commit.
- Space moves (⌥, tap and hold) with the Mission Control shortcuts; display moves
  with real layouts; the Dock at each position and with magnification.
- The menu-bar Space swipe on a hidden menu bar and in full-screen apps.
- That a user's two-finger triggers still fire everywhere off the title bars.
