# AOM 7.24: the menu bar spec, applied

- **Base:** `1d1dbe6` (7.23.0, installed). Branch `feat/7.24`. Claude Code, 2026-11-28.
- **Source:** `~/Downloads/AOM-7.23.0-디자인-메뉴바-개선-명세서-2026-11-28.md`, written by DeepSeek. It draws on:
  - Oracle reverse-engineering notes on 26+ apps (Bartender 7, Ice, SoundSource, Stats, Itsycal, SwiftBar, Raycast, CleanShot X, Paste, Rectangle and Moom)
  - the 7.23 code
  - the 7.23 CI snapshots

## 1. Claims checked against the code and the snapshots

| ID | Claim | Result |
|---|---|---|
| MBP-1 | The panel has switches but no live controls: no output or volume, no recent copies, no hidden icons | **True** |
| MBP-2 | Three default quick actions duplicate the Capture tile | **True.** `panelCommands()` fell back to the Workspace order, which starts with three captures. |
| MBP-3 | Tiles take clicks in different ways, and the inline menu makes the panel jump | **True.** It depended on `menu != nil`. Capture's badge did nothing. |
| MBP-4 | Text is truncated at 340 pt | **True.** The snapshot shows "Area · Windo…". |
| MBP-5 | "Open Launcher…" is a button dressed as a search field | **True** |
| MBP-6 | Panels and the launcher ignore Settings › Appearance | **True.** This was by design ("panels follow the system"). On a light Mac with AOM set to Dark, the panel was white. |
| §3.2-1 | White icons disappear on the Menu Bar page in Light mode | **True.** `barColor` was not kept with the cached pictures, so the lane fell back to the window's light grey. |
| §3.2-2 | The saturated blue `#2961AD` lane | **True** for the preview samples. Real reads use the bar's own colour, at full saturation. |
| §3.2-3 | The pane list collapses into a pop-up at 1320 pt | **Partly true.** The CI runner's screen is 1024 pt, so the "1320" window was 1024 wide. Real 1320 windows were side by side. The 860 pt threshold was still high. |
| §3.1 | AOM puts up to 7–9 status items in the bar | **True as a maximum**, counting the main icon, Hider, Weather, Focus, the meeting indicator, meeting alerts and Mic. Most appear only while in use. |
| §4.2 | Window Tiling shows an empty screen when there are no zones | **True.** It is the display miniature, not a "huge" rectangle. |
| §4.3 | Workspace tiles' trailing controls don't line up | **True** |
| §4.4 | Ten capture tiles push the captures below the fold | **True** |

## 2. Applied

| Item | What | Where |
|---|---|---|
| MBP-6, P0 | Settings › Appearance now sets the whole app's appearance (nil means System). The menu bar panel, launcher, Quick Entry, Drop Shelf and strip follow it. A launcher theme with its own scheme still overrides it. Previews take the same path. | `AOMAppAppearance` (AOMFeatureKit), `AppDelegate` |
| §3.2-1/2, P0 | The bar colour is stored with the pictures (`AOMMenuBarLaneColor`) and drawn calmed, at saturation × 0.55 and the same brightness. Until a bar has been read, cached pictures brighter than 0.6 luminance get a slate lane, otherwise the window colour. The preview samples use slate instead of blue. | `MenuBarLaneColor`, `MenuBarLayoutModel`, `MenuBarLayoutEditor` |
| §3.2-3, P0 | The pane list stays beside the pane from 708 pt (was 868). A zero-width first layout pass changes nothing. | `MenuBarPaneNavigation` |
| MBP-1/4/5 | The panel is 396 pt wide: a 180 pt half tile, a 368 pt full strip. From the top:<br>- **Search field** (Ice): focused when the panel opens. It searches AOM's commands, icons AOM hides and the clipboard; ↩ runs, ↑↓ move, esc clears, ⌘K opens the launcher.<br>- **Sessions or start chips:** Focus, and Keep Awake for 1 hour.<br>- **Sound strip** (SoundSource): output picker, mute, volume slider, App Audio switch and "Apps" (the Audio page).<br>- **2 × 2 tiles.**<br>- **Recent copies** (Paste): the last three; click pastes into the app in front, ⌥-click copies, secrets show a lock.<br>- **Battery row.**<br>- **Four quick actions.**<br>- **Footer:** "Open All of MacOS" first (⌘O), then Customize, Settings and ⋯. | `AOMMenuBarCraftPanel`, `AOMMenuBarPanel`, `AOMMenuBarPanelSupport` |
| MBP-2 | Default quick actions are Capture Area, Clipboard History, Drop Shelf and Show All Hidden Icons, four across with short labels (Keep Awake and Focus are the chips above them). The person’s own list still wins. Four tiles remain (Capture, Drag to Snap, Clipboard, Gesture HUD): App Audio moved into the sound strip, Keep Awake into the chips and live sessions. | `AOMStatusMenuStore.defaultPanelCommandIDs` |
| MBP-3 | Every tile works the same way: the 44 × 52 pt badge flips the switch or runs the first command (Capture Area); the name opens the tile's page in the body's place, at the body's height, with Back. | `AOMMenuBarCraftPanel.tileView`, `tilePage` |
| MBP-6 | The panel refreshes when it opens. The 5-second timer runs only while something counts down or records. | `AOMMenuBarPanel` |
| §3.1 | The weather can sit inside AOM's own icon instead of as a separate item (Menu Bar › Weather › Inside AOM's icon; off by default). | `MenuBarWeather.showsInAOMIcon`, `AppDelegate.updateStatusIcon` |
| §3.3, Itsycal | The Focus, Weather and meeting items keep the most digits they have shown, padded with figure spaces, so "9:59" → "10:00" doesn't push the icons beside them. | `AOMStatusItemWidth` |
| §4.2 | With no snap zones, three starter sets (Essentials, Corners & Halves, Complete) sit under the displays, each drawn as its zones. One click adds the set and turns on Drag to Snap. | `SnapZoneStarterCards` |
| §4.3 | Every Workspace tile keeps a 22 pt ⋯ slot that shows only on hover; the commands are also on right-click. | `AOMModuleTile` (AOMComponents) |
| §4.4 | Capture is one slim toolbar row: All-In-One, Area, Window, Full Screen, Scrolling and Record. Under More: Self-Timer, Text, QR, Measure, Open & Annotate, History Overlay, Desktop Icons, Append OCR and Settings. The captures follow right after. | `CaptureStudioView.captureToolbar` |

## 3. Not done (open)

- **Combined status pill:** only the weather can join AOM's icon. Focus, recording and Mic keep their own items, because they are live controls with their own menus.
- **Bartender sub-bars:** sub-bars, image-change triggers and profile rollback are not built.
- **Launcher:** an empty launcher doesn't show scope chips or ⌘1…5 hints (§4.5).
- **Other pages:** no gauge or sparkline redesign for Audio, System Tools or Activity (§4.5).
- **Panel search:** no "open in launcher with this query"; the launcher opens empty.
- **Not tried on this Mac:** typing into the panel, volume, output switching and paste from the panel. These need a real run; the snapshots only show layout.

## 4. Verification

- **Unit tests:** `AllOfMacOSTests/AOM724Tests.swift` covers appearance mapping, lane colour calming and fallback, search scoring, default quick actions present in the catalog, status-item padding, copy ages, panel width and the starter sets. `AOM716Tests` was updated for the 700 pt threshold.
- **CI:** the suite, the UI snapshots (menubarpanel and launcher in dark, tab13, tab03 and tab04) and the release.

## 5. 7.24.1: the Codex audit and agy's §6 review

- **Sources:** both in `~/Downloads`.
  - `AOM-7.24-고아코드-비대화-미연결기능-전수조사-및-통합실행명세-2026-11-28.md` (Codex)
  - §6 of the updated `AOM-7.23.0-디자인-메뉴바-개선-명세서-2026-11-28.md` (agy)
- **User request (overrides the spec):** keep the tile choices sliding in under the tiles. The page push from 7.24.0 is reverted. Capture's badge opens its choices again, and gets no "primary" action.

| Claim | Checked | Done |
|---|---|---|
| App Audio and Keep Awake tiles still in the panel | True in `44b2e3a`, but already fixed in `36c3618` (7.24.0 shipped with four tiles) | — |
| Capture `primary` not wired | True | Deliberately not wired, per the user's request |
| Panel can exceed 560 pt | True, about 610 pt with the battery row and three copies | `maxHeight(visible:)`; recent copies show one, with "N more" |
| Paste from the panel races its own key focus | True: fixed 120 ms, the panel is key | Destination captured at `show`; `ClipboardPasteDelivery.deliver` (relinquish → activate → changeCount check → ⌘V) |
| 8 orphaned views | 7 confirmed by grep (the "AOMAutomationRow" view is still used for `lastRunText` and kept) | Removed: `AOMToolbarSearch`, `AOMCardEmptyRow`, `AOMInspectorDisclosure`, `AutomationScopeChoice`, `AOMModeButton` (+ its private `AOMModeMark`), `CaptureStudioView.toolButton`, `toolRowMinimum` |
| `toggleDoNotDisturb` hidden in the browser but offered in the launcher | True | Launcher row removed |
| `AOMAudioEngineEnabled` written, never read | True | Write removed; key kept in the backup list for old backups |
| Screen-text trigger editor doesn't restore values | Not reproducible: the trigger panel only creates triggers; there is no path that reopens a saved system-event trigger | — |
| `ShortcutMenuPress` walks the menu bar each time (up to 0.35 s) | True | `MenuItemCache`: per app and shortcut, 10 s, re-checked enabled and front app |
| Regexes compiled on hot paths | True (QuickEntryParser, TriggerSystemSignals, WorkflowSupport, FolderRulesMatching, FocusShortcuts) | `AOMRegexCache` (256 entries, failures remembered) |
| Clipboard polls every 0.15 s | True | 0.5 s, plus reads at 40/120/300 ms after ⌘C or ⌘X (via the keyboard tap) |
| Folder Rules faults at launch | Found after the 7.24.0 install: 20 faults symbolicated to `FolderRulesEngine.refreshStatus` ← `FolderRulesPage.init` ← `MainWindow.body` | Status published on the next run-loop turn, only for values that changed |

**Not done:**
- `HardwareController` / `AOMSharedImageStaging`: moving them out of the app target touches the helper and extension build scripts.
- Dead `PresetManager` keys: removing them would drop keys from old backups.
- `.claude/worktrees`: agent worktrees outside git; not deleted without asking.
- God-file splits and the UI-kit merge: no behaviour change; a separate refactor.
- Event-tap threading (7.19 P0-1): staged, risky.
- Clipboard blob split: a storage format change.
