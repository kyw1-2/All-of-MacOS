# 3.2.0 Trackpad window snap (Swish-style), from REA

AOM 3.2.0 adds a two-finger title-bar window snap with a live preview, modelled
on Swish. Rest the pointer on a window's title bar, swipe with two fingers, and
a translucent preview shows where the window will land; lift to commit, with a
haptic tap. It is off by default (Window Tiling › Trackpad Snap).

## How the behaviour was recovered

- Downloaded Swish 1.13.3 from the developer's own distribution
  (`github.com/chrenn/swish-dl`, Christian Renninger). The DMG uses lzfse, which
  the Linux box could not open, so it was mounted read-only on the Mac
  (`hdiutil attach -nobrowse -readonly`, never launched), the universal binary
  copied out, and the arm64 slice pushed to the Oracle analysis host.
- Oracle ran Ghidra 12.2 headless (`analyzeHeadless … DecompileMatching.java`)
  plus `nm`, `otool -s __TEXT __swift5_typeref` and `strings`. Swift strips most
  function names, but reflection metadata and ObjC selectors kept the structure.
- Only behaviour and constants were studied. This is AOM's own implementation;
  no Swish code is copied. The decompile is kept at `work/rea-swish/` for
  provenance.

## What Swish does (recovered)

| Area | Finding |
|---|---|
| Window under pointer | `CGWindowListCopyWindowInfo` → PID → `AXUIElementGetWindow` / `runningApplicationWithProcessIdentifier:` — the pointer's window, title bar included. |
| Classes | `SnappingTabController`, `AccessibilityWindowController`, `AccessibilityWindow`, `Diagnostics.HapticFeedback`. |
| Gesture model | Two-finger swipe over the title bar → `ActionSnapHalves/Thirds/Quarters/Sixths/Ninths/Vertical`; "Double-swipe vertically to snap to the top or bottom half"; two-finger double-tap → unsnap/center; General/Secondary/Tertiary modifiers widen the scope (all screens, all apps). |
| Preview overlay | Per-layout views (`GestureView`, `CenterGestureView`, `snappingView`, `snappingThirdsView`, `snappingNinthsView`, …): a rounded-rect (`bezierPathWithRoundedRect:xRadius:yRadius:`, `setCornerRadius:`, `setMaskedCorners:`) translucent window (`colorWithAlphaComponent:`, `setAlphaValue:`) animated with `setFrame:display:animate:` and CA animation groups (`runAnimationGroup:`, `resizeAnimationTime`). |
| Stability | `gestureTimeout` + a cancellable `gestureDispatchItem`; `activateAfterSnapping`; "Resnapping after …" on screen changes. |
| Extras | Optional tiled-window margins (`EnableTiledWindowMargins`, `marginSelect`), haptic tap on snap (`NSHapticFeedbackManager`), native-snapping toggle, drag-to-unsnap. |

## AOM's implementation

`Services/TitleBarWindowSnap.swift`:

- **Pure recogniser (`SwishSnap`, `TitleBarSnapRecognizer`).** Runs on the
  existing multitouch callback thread (`TrackpadMonitor` feeds it the same
  frames it already decodes — one additive line, it never blocks or consumes the
  gesture pipeline). It does only float maths and reports state transitions.
  Direction comes from the dominant axis past an engage distance; a longer swipe
  in that direction is tier 2, so one gesture refines: left/right → half → third,
  up → maximize → top half, down → center → bottom half. Unit-tested.
- **Title-bar only.** It engages solely when the pointer sits in the top band of
  the window under it (`captureTarget(atMousePoint:)` + `frame(of:)`), so it does
  not compete with AOM's other two-finger gestures anywhere else.
- **Preview overlay (`SnapPreviewOverlay`).** A borderless, non-activating,
  click-through floating panel with a rounded accent rectangle that animates its
  frame as the swipe refines — the same mechanism Swish uses.
- **Commit & stability.** Lifting the fingers sets the window's frame
  (`WindowManager.setFrame`) with an optional haptic; a 1.2 s `DispatchWorkItem`
  timeout cancels a stale gesture; the feature is gated behind
  `AOMTitleBarSnapEnabled` (default off) and needs Accessibility.

## Limits

- Off by default; needs Accessibility permission to move windows.
- Thirds/sixths/ninths and the modifier-scoped variants from Swish are not all
  reproduced — AOM maps the common halves/thirds/maximize/center set.
- Not exercised with live hardware from the build session (the recogniser,
  geometry and title-bar hit test are unit-tested; the overlay and AX commit
  were reviewed in code).
