# Window snap 3.3.7: a swipe up always maximizes, no top or bottom half

Read with docs/window-snap-3.3.5.md, 3.3.4.md, 3.3.3.md and 3.3.2.md: everything there still holds
unless this page says otherwise. Code: `SwishSnapGrid.swift` (`SwishSnap.step`, `isVerticalHalf`,
`tooltipText`), `TitleBarWindowSnap.swift` (`SwishSnap.move(at:…)`, `TitleBarSnapRecognizer`,
the service's `begin`/`commit`). Tests: `AllOfMacOSTests/N337SwishUpMaximizeTests.swift`.

## Your two rules

1. **A plain two-finger swipe up on a title bar always maximizes.** From a free or centred window,
   a half, any quarter (bottom-right ↑ is maximize, no longer top-right), the top or bottom half, a
   third, a sixth, a ninth, and a maximized window (it stays maximized). At any length or speed, as
   the first motion of a touch or a later one (left, rest, up is maximize, not top-left), and as a
   new touch right after another swipe. ⌥ up is a plain swipe up.
2. **No title-bar gesture snaps to the top or bottom half.** The double swipe in one touch (up,
   rest, up / down, rest, down), the separate double swipe within 0.5 s, the "↑↑ Top Half" and
   "↓↓ Bottom Half" tooltips, top half ↓ → bottom half, a bottom quarter ↓ growing into the bottom
   half and a bottom sixth growing across the bottom row are all gone. Where a swipe down used to
   reach one of those halves, the window goes back to its size from before the snap.

The top and bottom half layouts themselves stay: presets, the Window Tiling layout buttons, menus,
the "Snap Window Top/Bottom Half" actions and snap zones still use them.

## The gesture table (two fingers on a title bar or toolbar)

Your settings: Down action **Center**, multi-motion pause 0.5 s, modifier gestures on,
sensitivity 1, 2 × 2 grid. "Back" = the size and place from before the snap, kept whole on a
display (Swish's "Unsnap: Avoid cropping").

| Window is | ← | → | ↑ | ↓ |
|---|---|---|---|---|
| Free | Left half | Right half | **Maximize** | Center (Minimize with that option) |
| Centred | Left half | Right half | **Maximize** | Back (Minimize with that option) |
| Maximized | Left half | Right half | **Stays maximized** | Back |
| Almost maximized (option on) | Left half | Right half | Maximize | Back |
| Left half | Stays (3 × 2/3 × 3: left third) | Right half | **Maximize** | Bottom-left quarter |
| Right half | Left half | Stays (3 × 2/3 × 3: right third) | **Maximize** | Bottom-right quarter |
| Top half (from a hotkey action or menu) | Top-left quarter | Top-right quarter | Maximize | **Back** (was bottom half) |
| Bottom half | Bottom-left quarter | Bottom-right quarter | **Maximize** (was top half) | Back |
| Top-left quarter | Left half | Top-right quarter | **Maximize** (was top half) | Bottom-left quarter |
| Top-right quarter | Top-left quarter | Right half | **Maximize** (was top half) | Bottom-right quarter |
| Bottom-left quarter | Left half | Bottom-right quarter | **Maximize** (was top-left) | **Back** (was bottom half) |
| Bottom-right quarter | Bottom-left quarter | Right half | **Maximize** (was top-right) | **Back** (was bottom half) |
| A third (3 × 2) | 3.3.1 table: third → two thirds → half | same | **Maximize** (was upper sixth) | Its lower sixth |
| A lower sixth | Moves a cell, or the third at the side edge | same | **Maximize** | Two sixths along the bottom; **back** where that would be the bottom half |
| A third (3 × 3) | as 3 × 2 | same | **Maximize** (was top ninth) | Its bottom ninth |
| A ninth | Moves a cell, grows at a side edge | same | **Maximize** | Down a row; along the bottom edge two-ninths, then the bottom row; from the bottom row back |

Diagonals and L-shapes go straight to that quarter from anywhere: ↖ top-left, ↗ top-right,
↙ bottom-left, ↘ bottom-right. A stroke counts as diagonal only between about 31° and 59° on the
glass (3.3.2's rule, unchanged). A swipe up that drifts sideways stays "up" until the sideways leg
passes about 31° on the glass (about 34° once it has engaged as up). Once a quarter is showing, the
stroke keeps it until the leg drops below about 22°, so the preview does not flicker.

Other gestures, unchanged and as Swish defines them:

| Gesture | Does |
|---|---|
| ⇧ ↑ | Almost maximize; ⇧ ↑ again maximizes (never the top half) |
| ⌥ ← / → | Move the window one Space |
| ⌥ ↓ | Close the window; twice, or tap and hold first, quits the app |
| ⌥ ↑ | Same as a plain ↑ (maximize) |
| ⌘ any direction | Move the window to the display that way, keeping its cell |
| Tap and hold, then ↑ / ↓ / ← → | Full screen on/off / minimize / next Space |
| Pinch in / out | Close (twice: quit) / full screen (two displays: twice or ⌘ for the other display) |
| Double tap (⌥ / ⇧) | Unsnap or centre (your setting) / hide the app (⌥) / hide the others (⇧) |
| Window in full screen | Plain swipes do nothing; tap and hold and the modifiers still work |

Multi-motion still works for everything else: rest until the trackpad taps, then keep swiping.
Left, rest, down is the left half, then the bottom-left quarter. Any motion followed by a rest and a
swipe up ends maximized.

Keyboard (only when Swish hotkeys are on; off by default): ⌃⌥ plus an arrow is the same swipe as
above, so ⌃⌥↑ now maximizes from every place too and ⌃⌥↓ never reaches a vertical half.
⌃⌥⌘↑ and ⌃⌥⌘↓ move the front window to the display above or below, keeping its cell; with no
display that way they do nothing. Their code is unchanged in 3.3.7.

## What matches Swish and what differs on purpose

Swish evidence: Swish 1.13.2 at /Applications/Swish.app (`strings`, not run) and DeepSeek's static
analysis of Swish 1.13.3 on Oracle (`strings-all.txt`, `decompiled/*.json`). Both builds have the
same help strings.

Matches Swish:
- Sideways: "Swipe horizontally to snap to the left or right half of the screen."
- Up once: "Swipe up once to fill the entire desktop area."; with Almost Maximize, "Swipe up once to
  fill almost the entire desktop area."
- Quarters from a half by a vertical swipe, down only: "Swipe horizontally and vertically to snap
  to a quarter. Both orders work." Left half ↓ is the bottom-left quarter, and ↙ works from anywhere.
- Down: "Swipe down once to minimize a window." is the Minimize option. You chose Center, an AOM
  option.
- Thirds: "Swipe horizontally to switch between thirds and two-thirds."; the lower half of a
  third by swiping down ("In addition, swipe vertically to access the upper and lower halves of
  those thirds", down half only).
- Modifiers, holds, pinches, double tap: "Alternatively, swipe down once while holding the general
  modifier.", "Pinch in once to close a window.", "Pinch in twice to quit an application.", "Pinch
  out or tap, hold and swipe up to enter or exit fullscreen mode.", "In fullscreen mode, tap and hold
  before swiping down.", "Tap, hold and swipe or use the general modifier to move a window between
  Mission Control spaces.", "Swipe up, down, left or right to move a window to the next screen in
  that direction.", "Double tap to unsnap and/or center a window.", "Unsnap: Avoid cropping".
- The multi-motion engine: "you can swipe and pinch in the same direction multiple times in a row
  without lifting your fingers" (WelcomeViews.nib). Each motion now commits.

Differs on purpose (your rules):
- "Double-swipe vertically to snap to the top or bottom half of the screen." Removed. Swish's
  action groups include `ActionSnapVertical` next to `ActionSnapHalves` and `ActionSnapQuarters`;
  AOM has no title-bar gesture for that group.
- "Try swiping up twice on the titlebar of this window." (WelcomeViews.nib) In AOM, up twice stays
  maximized.
- Vertical-first quarters and the upper halves of thirds: in Swish a swipe up on a half or third
  goes to its top quarter or upper sixth ("Both orders work", "upper and lower halves of those
  thirds"). In AOM it maximizes. Because of that, a plain swipe no longer reaches the upper sixths
  of 3 × 2, or the top and middle ninths of 3 × 3. Top quarters still come from ↖ ↗ diagonals or
  L-shapes.
- A quarter swiped up moving to the quarter above (bottom-right ↑ → top-right) is inferred Swish
  behaviour, not seen. DeepSeek's decompile reached only the event-tap trampoline (`FUN_10006b9f8`,
  `13_gesture_dispatcher.json`); the closure that maps gestures to actions was not found (its
  README §4.2 and §9 mark it UNVERIFIED).

AOM's own choices where Swish says nothing: a bottom quarter ↓ goes back (it used to grow into the
bottom half); the top half ↓ goes back; a lower sixth ↓ grows into two sixths unless that would be
the bottom half.

## Settings

No key was added, renamed or reset. `AOMTitleBarSnapDownAction` (center), `AOMTitleBarSnapMotionPause`
(0.5), `AOMTitleBarSnapModifiers` (1) and `AOMTitleBarSnapSensitivity` (1) are read as before. The
Window Tiling page's help no longer describes the bottom-half double swipe, says that a swipe up
always maximizes, and says that no swipe snaps to the top or bottom half.
