# 3.3.0 Swish port, round 2: the DeepSeek Harness analysis

3.2.0 added a Swish-style two-finger title-bar snap built from Swish 1.13.3's
strings and metadata (see `window-snap-3.2.0-swish.md`). On 2026-10-27 a
DeepSeek Harness (DSH) worker on the Oracle host ran a second, function-level
Ghidra pass over the same build. 3.3.0 applies what that pass recovered.

## Source

- Work packet: DSH session `session-fb4b8756…` in `/data/rea-targets-swish-20261027`,
  with `rea` 6.8.0 and Ghidra 12.1.4. The pass was static only; nothing was
  executed. The analysis covered behaviour and constants. No Swish code is copied.
- Hashes: DMG `8e968454…d52c`, arm64 slice `48c02f02…22d6`, x86_64 slice `999b1716…5705`.
- Artifacts, copied to `work/rea-swish/dsh-20261027/` for provenance:
  - `report/decompiled/*.json`
  - `report/callsites.txt`
  - `report/strings-filtered.txt`
  - `report/imports.txt`
  - `decompiled-combined.c`, readable pseudocode of the decompiled functions
  - `dsh-session-trace.txt`
- The DSH session ended before it wrote its own summary files (`behavior.md`,
  `summary.json`). Decompiles 01–15 were completed afterwards in the same
  directory. `10_eventtap_install_2` is empty, so it is UNVERIFIED.

## What the decompiled functions show

| Function | Behaviour |
|---|---|
| `FUN_1000329c8`: window geometry setter | Writes `AXSize`, then `AXPosition`, then `AXSize` again, and reads the size back. If the app kept its own size, Swish re-anchors the position to the snapped edge: a last column uses `maxX − width`, a middle or full-span cell uses `midX − width/2`, and anything else uses `minX`. Rows work the same way. It then reads `AXFrame` and animates its preview overlay to that real frame (`setFrame:display:animate:`), records the pre-snap frame per window for unsnapping, and can warp the cursor to `(midX, minY + 26)` with `CGWarpMouseCursorPosition`. If the app has `AXEnhancedUserInterface` (23 chars, `0x10010f0b0`) on, Swish turns it off during the write and restores it afterwards. |
| `FUN_1000034ec`: event-tap install | `CGEventTapCreate(session, head, listen-only unless consuming, mask 0x20401400 = keyDown │ flagsChanged │ scrollWheel │ gesture(29))`. |
| `FUN_10006b448` / `FUN_10006b950`: tap re-enable and teardown | On `tapDisabledByTimeout` or `tapDisabledByUserInput`, it logs "CGEventTap: interrupted by …" and calls `CGEventTapEnable(tap, true)`. Teardown disables the tap, removes the run-loop port and invalidates the mach port. |
| `FUN_100081e1c`: Spaces | `CGSCopyManagedDisplaySpaces` for moving windows between Spaces. |
| `FUN_10003eab4`: Accessibility gate | Checks `AXIsProcessTrusted()` and notifies its observers. |
| `FUN_100017a80`: launch body | `CGSSetConnectionProperty("SetsCursorInBackground", true)`, plus observers for `NSAppearance` and `NSScreen` changes ("Resnapping after …"). |

Swish's settings strings also explain the gesture model and its prerequisites:

- "Swipe horizontally and vertically to snap to a quarter. Both orders work."
- "Double tap to unsnap and/or center a window." Related names: `ActionSnapUnsnap`, `snappingDragUnsnap`.
- `activateAfterSnapping` and `snappingMoveCursor`.
- "Haptic Feedback needs to be enabled for your Magic Trackpad."
- "Mission Control shortcuts are set correctly / to a custom combination / disabled."

## Applied in AOM 3.3.0

1. **The commit works like Swish's.** The title-bar snap used to call a single
   position-and-size write. It now goes through `WindowManager.applySnap`, which:
   - suspends `AXEnhancedUserInterface` during the write;
   - writes size → position → size → position and waits for each stage to settle;
   - reads the frame back;
   - records the move for Undo Last Window Placement and Restore Window Size.
2. **Size-limited windows anchor to the snapped edge.** This is
   `WindowGeometry.anchoredFrame`, using the rule from `FUN_1000329c8`. For
   example, a fixed-width System Settings window snapped right now sits flush
   right instead of failing the move. The same rule now applies to every
   grid-cell tiling action: halves, quarters, thirds, two-thirds, sixths,
   maximize, next-display maximize and custom snap. A title-bar snap anchors
   inside its margin, so a requested gap is kept.
3. **The preview lands where the window really went.** The overlay animates to
   the read-back frame and then fades. Under Reduce Motion it jumps and fades instead.
   A swipe that starts while the last preview is still fading keeps its own preview.
4. **Unsnap.** AOM keeps each window's pre-snap frame (`SwishSnapHistory`; a
   chain of snaps keeps the first frame). A plain swipe down on a window that
   still sits where AOM snapped it restores that frame. The preview for this
   has a dashed outline, so it reads as "put it back". A longer swipe down is
   still the bottom half. A snap that never moved the window records nothing
   to restore. A restore keeps Restore Window Size's own saved frame unless it
   lands on that same frame.
5. **Quarters in either order.** Swipe left or right, then up or down, or the
   other way round. The second leg must be deliberate: past 0.06 of the pad and
   at least 45 % of the first leg's distance, so the natural arc of a long swipe
   never counts. It is released with hysteresis.
6. **Haptics.** A light haptic plays as the preview moves to a new zone, and
   another on commit. Both use the existing rate-limited `GestureHaptics`.
7. **Bring the window forward** (`activateAfterSnapping`, default on). The
   window is raised and its app activated, so a background window does not
   land behind the others.
8. **Keep the pointer on the title bar** (`snappingMoveCursor`, default off). The
   pointer warps to the middle of the snapped window's title bar so the next
   swipe can follow straight on.
9. **A readiness checklist**, phrased the way Swish's settings explain it. It
   covers Accessibility, haptic feedback, and the Mission Control "Move
   left/right a space" shortcuts that the top-bar Space swipe posts. It reads:
   - `com.apple.AppleMultitouchTrackpad`: `ActuateDetents` and `ForceSuppressed`;
   - `com.apple.symbolichotkeys`: entries 79 and 81.

   Both are read only, never written. Each item has an Open… button for the
   matching System Settings pane.
10. **The card became Trackpad Gestures.** It holds the title-bar snap, the
    options above, the top-bar Space swipe and Dock pinch to quit, so the
    Swish-style gestures live in one place. The title-bar snap is also in
    Settings › General search, and it picks up changes live.
11. **The snap keeps the trackpad stream running.** Before, the stream ran only
    for trackpad triggers and the Space or Dock gestures. With no trackpad
    triggers and both of those off, the snap silently stopped. It now counts as
    a consumer of the stream (`TrackpadUtilityGestures.anyLayerEnabled`), and
    toggling any of the three re-registers the stream immediately
    (`AppState.refreshTrackpadLayersIfNeeded`).

## Already in AOM or not ported

- **Event-tap re-enable:** already in AOM. Every AOM tap callback handles
  `tapDisabledByTimeout` and `tapDisabledByUserInput` (KeyboardMonitor,
  MouseButtonMonitor, InputRemapping, ClipboardStackPasteMonitor and the
  TrackpadMonitor click taps).
- **`SetsCursorInBackground`:** not ported. It is a private CGS connection
  property, and AOM does not need to set cursors while in the background.
- **Resnap on screen change:** not ported in this round. Re-applying remembered
  cells when displays change can move windows the user placed since, so it
  needs live multi-display testing first.
- **Double-tap unsnap, sixths and ninths, and drag-to-unsnap:** not ported.
  Swipe-down unsnap covers the restore case on the existing gesture stream
  without a new tap recogniser. Sixths and ninths would need new layout cells
  in every picker.
- **Spaces moves (`CGSCopyManagedDisplaySpaces`):** not ported. AOM's Space
  actions use the system Mission Control shortcuts, which the readiness
  checklist now verifies.

## Verification

Covered by `TitleBarSnapTests` (22 tests):

- quarter mapping in both orders;
- leg hysteresis and the axis re-pick;
- history chains, its size bound, and a no-op snap recording nothing to restore;
- anchoring: flush right or left, centred cells, bottom rows, margins, and windows larger than the display;
- readiness parsing for haptics and Space shortcuts;
- the drawer threshold that keeps the Automation split;
- the recognizer's quarter chain;
- the original 3.2.0 cases.

The full suite passed: 1,144 tests, 0 failures, 3 skipped. An independent
behavioural review of the diff was approved, and its four findings were fixed
before release: the overlay fade race, the no-op unsnap, Restore Window Size
being cleared, and ⌘N/⌘F on Automation. So were the stream-consumer gap and the
smaller nits.

The overlay, the AX commit, the cursor warp and app activation were reviewed
in code. They were not exercised with live trackpad hardware in this session,
which ran from the command line without driving the trackpad.
