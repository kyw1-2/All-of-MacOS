# Mission Control Plus 1.24 Reverse Engineering & Porting Inventory

- Target Bundle: `io.fadel.MissionControlPlus` (v1.24, Build 1.24)
- Extracted Date: 2026-10-25
- Location in Repo: `MissionControlPlusReference/`

---

## 1. Core Mechanics & Architecture (Ghidra + Symbols)

Mission Control Plus provides window management controls on top of macOS Mission Control & App Exposé:

### Key Classes (Swift):
1. `Mission_Control_Plus.ExposeController`:
   - Polling timer (`performTimerBasedUpdate`, interval 0.25s) tracking Mission Control state via Dock AX tree (`com.apple.dock`).
   - Traverses `kAXChildrenAttribute` of Dock's fullscreen AX window to locate each window thumbnail tile frame.
   - Maps each thumbnail tile to its originating process (`_AXUIElementGetPid`) and window title.
2. `Mission_Control_Plus.CloseButtonWindow`:
   - Borderless floating `NSPanel` overlay positioned at the top-left of each Mission Control window thumbnail.
   - Houses a circular ✕ close button. Clicking triggers the target window's close action via AX (`AXCloseButton` or synthetic Command+W).
3. `Mission_Control_Plus.HIDEventHandler`:
   - Global event tap listening for single keystrokes exclusively while Mission Control is open:
     - `W`: Close window under cursor.
     - `⇧W` (Shift+W): Close all windows belonging to that application.
     - `M`: Minimize window under cursor.
     - `H`: Hide application of the window under cursor.
4. `Mission_Control_Plus.MenuBarController`:
   - Status bar item with toggles for button visibility, shortcuts, and startup.

---

## 2. AOM Integration Plan

AOM already contains `MissionControlOverlayService.swift` which handles basic Dock AX polling and button panels.
To achieve full parity, we provide:
- `MissionControlHotKeyHandler`: Key event interception during MC (`W`/`⇧W`/`M`/`H`).
- `MissionControlTileModel`: Structured representation of tiles, PIDs, and AX handles.
- `MissionControlConfiguration`: User options for close buttons, shortcuts, and exclusion.
