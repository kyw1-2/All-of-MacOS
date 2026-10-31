# Window snap 3.3.8: an L in one touch takes the top corner

Read with docs/window-snap-3.3.7.md: everything there still holds unless this page says otherwise.
Code: `TitleBarWindowSnap.swift` (`SwishSnap.refine`, `SwishSnap.cornerTurns`,
`TitleBarSnapRecognizer`: `trackTurn`, `turn(dy:)`, `cornerTurn`, `continueMotion`; the service's
`adopt` and `showPreview`), `SwishSnapGrid.swift` (`SwishSnap.tooltipDirection`).
Tests: `AllOfMacOSTests/N338LShapeTopCornerTests.swift`, `N337SwishUpMaximizeTests.swift`.

## Your rule

In one touch, a sideways swipe that turns up takes that side's top quarter: left then up is the
top-left quarter, right then up the top-right. It does not matter whether the turn is continuous or
the fingers rest at the corner (the multi-motion pause). While the up leg moves, the tooltip says
"↑ Top Left" or "↑ Top Right" and never shows Maximize.

## Why 3.3.7 ended the L in Maximize

The recognizer was fed synthetic 60 Hz frames at your settings (sensitivity 1, pause 0.5 s). It
reproduced two causes and one near miss:

1. **The up leg drifted back over the start.** A short left leg (0.06–0.08 of the pad, just past
   the 0.05 engage distance), followed by an up leg leaning 15–20° back toward the start column,
   showed "← Left Half", then "Top Left", then "↑ Maximize", and committed Maximize. Once the
   horizontal distance from the start fell below half the engage distance (0.025), `refine`'s "back
   near the start, re-pick the axis" rule turned the stroke into a plain up. A plain up maximizes
   (3.3.7). The right side does the same in mirror image.
2. **The fingers slowed or rested at the corner.** A slow turn that stayed within 0.008 of one
   spot for 0.5 s (for example a 0.45 s slowdown between eased legs, or a deliberate rest) locked
   the left half. The up then began a new motion: the left half was committed, and a new up
   maximizes.
3. **Near miss (the half, not Maximize).** After a long sideways leg (0.3), an up leg shorter than
   45 % of it (0.12) never counted as the cross leg, so the stroke stayed the left half.

A sideways nudge shorter than the engage distance (0.03) followed by an up engages as a plain up
that leans about 10°. This is unchanged: it maximizes, like any up that drifts 8–25° (3.3.7).

## What changed

- The recognizer now tracks the L's vertical leg. It cuts the path into 0.01 steps. A step within
  35° of vertical on the glass adds to the leg, and a step within 35° of horizontal clears it.
  Once the leg passes the cross distance (0.06 at sensitivity 1), it is the corner, however long
  the sideways leg was. The arc of a straight swipe never moves mostly vertically, so the 45 %
  share still keeps such arcs a half.
- While that leg lasts, the corner keeps its side. An up leg drifting back over the start, or
  past it, stays the top-left quarter. Coming back down releases the corner first.
- If the sideways swipe rested and locked and the next motion is a plain up, the recognizer turns
  the corner instead of committing the half. There is one gesture and one commit.
- A quarter's tooltip shows its vertical leg's arrow: "↑ Top Left", "↓ Bottom Left".

## Updated rows

| In one touch | 3.3.7 | 3.3.8 |
|---|---|---|
| ← then ↑, continuous (any length, speed, 10–25° drift) | Top-left, or Maximize when the up drifted back, or the left half when the up was short | **Top-left quarter** |
| → then ↑, continuous | Same, mirrored | **Top-right quarter** |
| ←, rest, ↑ | Left half, then Maximize | **Top-left quarter** (one commit) |
| →, rest, ↑ | Right half, then Maximize | **Top-right quarter** |
| ←, rest, ←, rest, ↑ | Left half, left half, Maximize | Left half, then **top-left quarter** |
| An L, rest, ↑ | Top-left (when the L was recognised), then Maximize | Top-left, then Maximize |
| ←, rest, ↑, rest, ↑ | Left half, Maximize, Maximize | Top-left, then Maximize |
| ←, rest, ↓ | Left half, then bottom-left | Same (two commits) |
| ← then ↓, continuous | Bottom-left | Bottom-left (a short ↓ after a long ← now counts too) |
| ↓, rest, ↑ / ↑, rest, ↑ / ↓ ↑ after ← ↓ | Maximize | Maximize |
| A new touch with ↑ (also within 0.5 s of the last) | Maximize | Maximize |
| ⌥ ←, rest, ↑ | Space ←, then Maximize | Same (⌥ and ⌘ never turn a rested corner) |
| ⇧ ←, rest, ↑ / ⇧ L | Left half, almost maximize / top-left | **Top-left quarter** both (the corner wins over almost maximize) |
| Tap and hold, ←, rest, ↑ | Space ←, then full screen | Same |

In 3 × 2 and 3 × 3 grids, the L gives the 2 × 2 top quarter of that side, as the continuous L and
the diagonals always did. It never gives a half, the top sixth or a top ninth. No path reaches
the top or bottom half.

## Settings

No key was added, renamed or reset. The Window Tiling help now says a swipe up maximizes except as
the turn of an L.
