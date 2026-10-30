# Window snap 3.3.4: swipe up maximizes

Read with docs/window-snap-3.3.3.md and docs/window-snap-3.3.2.md: everything there still holds
unless this page says otherwise. Code: `SwishSnapGrid.swift` (`step`, `SwishDoubleSwipeUp`,
`place(of:…overflowing:)`), `TitleBarWindowSnap.swift` (`move(at:…secondSwipeUp:)`, `adopt`,
`plan(for:)`, `finishCommit`, `place(forStroke:start:startForUp:)`). Tests:
`N334SwipeUpMaximizeTests`.

## What users saw

Swiping up on a title bar to maximize often showed, and committed, the top half first. Two causes:

1. The longer-swipe tier. A swipe past 0.16 of the pad's height, measured from touch-down, took the
   top half, and the maximize-only band was 0.04–0.16 of the pad. A quick flick (its first evaluated
   frame already past 0.16), a long swipe, the slide of lifting fingers, or a multi-motion pause
   on the top-half preview all ended in the top half.
2. The size-limited reading. A large free window flush with the top-left or top-right corner of the
   visible area (for example 1000 × 700 at the top-left) only overflows that quarter, but was read
   as that quarter, the reading kept for apps whose minimum size is larger than a cell; from a top
   quarter a swipe up grows the window to the top half. A wide window flush with a side edge was
   read as that half, so a swipe up made a top quarter.

## Now

- A two-finger swipe up on a title bar maximizes at any length or speed, including the lift slide
  and a multi-motion pause. With ⇧ (Secondary) it almost-maximizes; up again from almost-maximized
  maximizes. The preview, tooltip, haptic and commit say Maximize for the whole swipe.
- A swipe up chains only from a place AOM remembers (its snap history) or a cell the window fills
  within 16 pt. A window that only overflows a cell is free-floating for a swipe up. Down,
  sideways and diagonal swipes keep the overflow reading (a size-limited top quarter swiped down
  still moves to the bottom).
- The top half is Swish's double swipe up: lift, then swipe up again on the same window's title bar,
  engaging within 0.5 s (`SwishSnap.doubleSwipeWindow`) of the maximize landing. That second swipe
  shows and commits Top Half. A further motion of the same touch, a swipe on another window, a
  later swipe, a swipe that engaged while the maximize was still landing, or a maximize that did
  not land or whose follow-ups were refused (N333-06) keeps Maximize.
- Unchanged: bottom half or a top quarter + ↑ → top half; top half + ↑ → maximize; a side half
  that the window fills + ↑ → its top quarter; ↓ with its longer swipe (bottom half); the ⌃⌥
  hotkeys.

## Needs a hardware check

- The double swipe's 0.5 s on a real trackpad; after a maximize the title bar is at the top of the
  screen, so the second swipe must start on it (with Keep pointer on title bar off, the pointer may
  be elsewhere).
- Apps that land slowly (staged writes, Native Tiling's 0.35 s read-back): a second swipe that
  engages before the landing is queued and stays Maximize.
