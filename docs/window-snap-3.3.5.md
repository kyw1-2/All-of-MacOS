# Window snap 3.3.5: Swish's double swipes, a swipe you can take back

Read with docs/window-snap-3.3.4.md, 3.3.3.md and 3.3.2.md: everything there still holds
unless this page says otherwise. Code: `SwishSnapGrid.swift` (`step`, `SwishSnap.doubleSwipe`,
`SwishDoubleSwipeUp.arming`, `SwishSnap.unsnapFrame`, `SwishChainQueue.withdraw`),
`TitleBarWindowSnap.swift` (`move(at:…doubleSwipe:)`, `TitleBarSnapRecognizer` `onMotionCommit` and
`onWithdraw`, `commit(continuingWith:)`, `withdraw`, `restorePlan`). Tests: `N335SwishParityTests`.

## What changed

| Gesture on a title bar | 3.3.4 | 3.3.5 |
|---|---|---|
| Swipe down, any length, on a free window | short: Minimize or Center (your setting); long or quick: bottom half | Minimize or Center at any length |
| Swipe down on a maximized window | short: back to its earlier size; long: bottom half | back to its earlier size at any length |
| Swipe up, rest until the tap, swipe up again (one touch) | maximized, then stayed maximized | **top half**; the window never maximizes first |
| Swipe down, rest until the tap, swipe down again (one touch) | Center: centred, then back to the earlier size. Minimize: minimized | **bottom half**; nothing is centred or minimized first |
| Swipe down, lift, swipe down again within 0.5 s | centred window put back | **bottom half** (after a centre or a restore) |
| Swipe out, then back to where the fingers started | the preview stayed and lifting snapped | the preview goes; lifting does nothing; swiping out again (any way) shows the new place |
| Unsnap (swipe down, double tap, menu-bar double tap) | the earlier frame as it was, even half off screen | the earlier frame, moved and if needed shrunk to stay whole on a display |

- Unchanged: a single swipe up maximizes at any length; up, lift, up again within 0.5 s takes
  the top half (3.3.4); ⇧ swipe up almost-maximizes; ⌥ swipe down closes (twice: quit); L-shapes
  and diagonals pick quarters; sideways keeps its longer swipe for thirds in the 3 × 2 and 3 × 3
  grids; your settings keys are read as before (nothing was reset or renamed).
- The rest is the multi-motion pause (`AOMTitleBarSnapMotionPause`, yours is 0.5 s): rest the
  fingers until the trackpad taps, then swipe again. With the pause at 0 the double swipe in one
  touch is off; lift and swipe again within 0.5 s instead.
- The tooltip shows two arrows for a double swipe ("↑↑ Top Half", "↓↓ Bottom Half").
- The rest tap plays only when something would happen (not on a stroke taken back, not on a
  full-screen window swiped without tap and hold).

## Why

Swish 1.13's own help says "Swipe down once to minimize a window", "Double-swipe vertically to
snap to the top or bottom half of the screen" and, for its multi-motion engine, "you can swipe and
pinch in the same direction multiple times in a row without lifting your fingers … Try swiping up
twice on the titlebar of this window". AOM read a long or fast swipe down as the bottom half (the
same flick problem 3.3.4 fixed for up), and a second swipe in the same touch committed the first
one, so up-up stayed maximized and down-down undid the centre.

## Needs a hands-on check

The recognizer, the mapping and the service's sequencing are unit-tested with synthetic frames;
nothing here ran on a real trackpad. See aom-335-kit/swish-335.md for the checklist.
