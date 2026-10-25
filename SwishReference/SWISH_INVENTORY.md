# Swish 1.13.2 Reverse Engineering & Porting Inventory

- Target Bundle: `co.highlyopinionated.swish` (Build 79, v1.13.2)
- Extracted Date: 2026-10-25
- Location in Repo: `SwishReference/`

---

## 1. Action Catalog (Total 23 Actions)

Swish's internal action names extracted from preferences and binary:

| Swish Action Name | Description | AOM Equivalent / Plan |
|---|---|---|
| `snapHalves` | Left / Right half screen split | WindowManager.execute(.snapLeftHalf / .snapRightHalf) |
| `snapThirds` | 1/3, 2/3 column layout | SwishSnapGrid (thirds) |
| `snapQuarters` | 4 corner quarters (Top-Left, Top-Right, Bottom-Left, Bottom-Right) | WindowManager corner snap |
| `snapSixths` | 2x3 or 3x2 six-zone grid | SwishSnapGrid (sixths) |
| `snapNinths` | 3x3 nine-zone grid | SwishSnapGrid (ninths) |
| `snapVertical` | Top / Bottom half vertical split | WindowManager.execute(.snapTopHalf / .snapBottomHalf) |
| `snapMax` | Maximize window within visible bounds | WindowManager.execute(.maximizeWindow) |
| `snapAlmost` | Almost maximize (leaves padding around edges) | SwishSnapGrid (almostMax) |
| `snapCenter` | Center window with preserved / standard ratio | WindowManager.execute(.centerWindow) |
| `windowMinimize` | Minimize target window | WindowManager.execute(.minimizeWindow) |
| `windowClose` | Close target window | WindowManager.execute(.closeWindow) |
| `windowQuit` | Quit target application | NSWorkspace.runningApplications.terminate() |
| `windowFullscreen` | Toggle native fullscreen | WindowManager.execute(.toggleFullscreenWindow) |
| `appMinimize` | Minimize all windows of target app | AXMinimize / AppKit hide |
| `appHide` | Hide application (Cmd+H equivalent) | NSRunningApplication.hide() |
| `appUnminimize` | Restore minimized windows | AppKit unhide |
| `appQuit` | Force / Graceful quit application | NSRunningApplication.terminate() |
| `appCycle` | Cycle between windows of front app | Window cycling |
| `tabClose` | Close active tab in window | AX tab close / Command+W |
| `tabDetach` | Detach tab into separate window | Drag tab out |
| `screensMove` | Move window to next / previous display | DisplayTopology / WindowManager.screens() |
| `menubarAppSwitcher` | Menu bar application switcher gesture | Menu bar extra |
| `missionControlSpace` | Move window across Spaces / Mission Control | SystemTriggerMonitor |

---

## 2. Core Settings & Modifier Keys

From `co.highlyopinionated.swish.plist`:
- `generalModifier`: `262144` (`NSEvent.ModifierFlags.control.rawValue`)
- `secondaryModifier`: `524288` (`NSEvent.ModifierFlags.option.rawValue`)
- `tertiaryModifier`: `655360` (`Control + Option`)
- `screensChainGesture`: `true` (Keep gesture alive across actions / unsnap & move)
- `snappingResizeAdjacent`: `true` (Resize tiled neighbors simultaneously)
- `snappingActivateWindow`: `false` (Operate on background window WITHOUT bringing it to front)
- `snappingMoveCursor`: `false`
- `tooltipLive`: `true` (Live bezel overlay preview)
- `blacklist`: `["com.apple.Spotlight", "com.apple.CharacterPaletteIM", "com.apple.PIPAgent", "com.apple.controlcenter", "com.apple.notificationcenterui"]`

---

## 3. Discovered Class Layout (Swish Module)

### Core & Accessibility:
- `Swish.SwishCore`
- `Swish.AXAccess`
- `Swish.UIElement`
- `Swish.Observer`
- `Swish.SystemWide`
- `Swish.Window`
- `Swish.Application`

### Gestures & Input:
- `Swish.Multitouch`
- `Swish.Gesture`
- `Swish.Hotkeys`
- `Swish.ModKeyControl`
- `Swish.CursorTrackingView`

### Visual Overlays & Feedback:
- `Swish.BezelWindow` / `Swish.BezelWindowController`
- `Swish.TooltipWindow` / `Swish.LiveTooltipWindow` / `Swish.TooltipController`
- `Swish.TilingPopoverController`

---

## 4. Integration Blueprint for AOM

1. **`SwishSnapGrid.swift`**: Complete geometric engine for 1/2, 1/3, 2/3, 1/4, 1/6, 1/9 and almost-max layouts.
2. **`SwishWindowHistory.swift`**: Preserves pre-snap frames (`initialFrame`) and manages chaining / unsnap.
3. **`SwishGestureSession.swift`**: Decoupled state machine separating swipe flick vs continuous move vs pinch.
4. **`SwishFeedbackPresenter.swift`**: Protocol and stub for visual Bezel & Snap previews in AOM's Liquid Glass style.
