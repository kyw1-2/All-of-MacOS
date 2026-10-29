# 3.3.3: what happened to each 3.3.2 audit finding

Sources, all dated 2026-10-29 and written against 3.3.2 (`0428e1b`):

- Main report: `AOM-3.3.2-검수보고서-2026-10-29.md` (S01–S06, A01–A03, G01).
- REA comparison: `AOM-3.3.2-Swish-REA-기능대조-2026-10-29.md` (its P1/P2/P3 headings).
- Deep report: `AOM-3.3.2-Swish-심층검수보고서-2026-10-29.md` (F01–F06, the §3 weaknesses
  B01–B07, PA-01–PA-04, the §10 headings BTT-입력, BTT-이식 and CS-옵션, and the CleanShot,
  BetterTouchTool and Paste tables). Its 33-identifier table (G01–G33) and §5 rows (X01–X53)
  are cited where a fix maps onto them.

Status words:

- **Fixed**: the code path the report names is changed and covered by new or updated unit tests in
  the stream named. It is not a hardware pass.
- **Partly**: part of the finding is done; the rest is listed with the reason.
- **Not done**: with the reason.
- **HW**: still needs a person on real hardware (trackpad, MIDI controller, HomePod, a real
  recording or a real MCP client). Most fixed items carry it.

Each stream ran only its new and changed tests (per the release's test rule), and all of them
passed; the full suite runs once at release. Commits are on `release/3.3.3-20261029` (stream
merges up to `763ef35`) and `wt/333-integ-core`. The streams' own notes are in
`work/integration-333/` of the main checkout; their "Remaining gaps" sections are the source of the
"left open" column.

ID collisions to keep apart: the main report's **G01** (gaps against other products) is not the
deep report's **G01** (`missionControlSpace`). The streams' working labels C03/C05/C06, P03/P04,
"S03/S04/S06" (audio) and "B03/B06" (btt-input) are plan labels, not audit IDs; this page uses
the audit IDs only.

## 1. Main report

| ID | Finding | Status | Where | Left open |
|---|---|---|---|---|
| S01 | Dock pinch to quit skipped the target app's pause and AOM's self-check | Fixed; HW | swish-dock e87fa6e | Checks the target's pause, the global pause and the lock right before the request; `politeQuit` refuses AOM and paused apps for every caller. HW: a throwaway app with unsaved changes keeps its save sheet; a paused app and AOM's own icon do nothing. |
| S02 | After 2→3→2 fingers, Dock and menu-bar pinches and swipes still fired | Fixed; HW | swish-dock e87fa6e | A third or fourth finger spends the touch until every finger lifts; `SwishDock333Tests.testAThirdFingerSpendsTheTouchUntilEveryFingerLifts` replays the probe's frames. A lost final empty frame swallows the next touch on that trackpad (deliberate). HW: 2→3→2 and 2→4→2 on a Dock icon. |
| S03 | Re-snap after display changes and adjacent resize ignored background apps' pause | Fixed; HW | swish-titlebar b2a6307 | Each window's app pause is checked before each write, and a batch stops when AOM is paused mid-way. HW: a display change with a paused background app. |
| S04 | Menu-bar unminimize ignored a pause set after minimizing | Fixed | swish-dock e87fa6e | Checked right before each Accessibility write; skipped windows stay remembered. |
| S05 | Delayed full screen (0.3 s) and Dock ⌘N (0.15 s) were not re-checked | Fixed | swish-titlebar b2a6307 (full screen); swish-dock e87fa6e, fe162aa (⌘N, menu-bar moves) | Pause, lock and target are checked again when the delayed step runs. |
| S06 | Menu-bar restore covered only AOM's latest batch and lost failures | Fixed; HW | swish-dock e87fa6e | Restores every window minimized on that display (twice or ⇧: every display), AOM's newest first; failures stay for the next swipe. Windows whose frame the app does not report come back only with "every display". HW: many minimized windows on two displays. |
| A01 | HomePod kept 128-frame IO; sample-time gaps seen | Partly; HW | audio 3ec2590 | After a gap the bridge fades in over 5 ms. coreaudiod's analytics put the gaps down to HAL safety violations (AOM's IO ≈ 20 µs of a 2667 µs cycle). Callback cost, overload notices and IO cycle usage are logged, and the drift loop's alias is fixed. Not removable from AOM's side: the device refuses larger IO, has safety offset 0 and IOCycleUsage is already 1.0. Not tried: a private aggregate device. HW: 20 min per state with diagnostics on, as in docs/airplay-crackle-3.3.2.md. |
| A02 | Output switch: both outputs pulled the same queue and DSP (~10 ms loss) | Fixed; HW | audio a9b6630 | One consumer at a time: fade-out, then the new output continues from the next frame with a fade-in (the outputs run different clocks, so no overlapping crossfade). Unchanged: Boost/Overdrive switch crossfades of signals that are not time-aligned, and an EQ change from fresh filter state. HW: switches during music. |
| A03 | Diagnostics had only per-session counters, no event times | Fixed; HW | audio 0426a43, 9e6732e | Last 200 events with wall-clock times, `eventsLost`, counters since the last reset (`AOMAudioDiagnosticsResetAt`). The poller runs only if diagnostics were on when an output started; no reset button yet; not yet run against the live device. |
| G01 | Many features missing against other products (docs/parity-3.1.0.md) | Partly | btt-input 526f82b, 1d805da; audio fbba1a1, 79e6171, c398bd3; clipboard 515d2b4, 376df64; capture-recording 4a39f89, 5939c2a; capture-annotation 5db89c2, 71f3f7c | Done: value bindings and pressure stages, Magic Boost presets, per-output EQ, an Audio Unit effect, link cards, region OCR, video backgrounds, click options, eraser, text styles. Open: Move window to Desktop N, floating-menu submenus and search, focus-follows-mouse, Stage Manager toggle; cloud, Magic Mouse and Stream Deck stay out of scope. See docs/parity-3.1.0.md. |

## 2. REA comparison (P1/P2/P3 headings)

| Heading | Status | Where | Left open |
|---|---|---|---|
| P1 탭 닫기·분리 제스처 없음 (no tab close or detach) | Fixed; HW | swish-titlebar b2a6307, 77ecbea | Close and detach in AppKit window tabs and Safari; close only in Chrome, Brave, Vivaldi, Arc, Dia, Orion, Xcode, VS Code, UPDF; nothing in Edge, Figma, Craft; Firefox exposes no tabs (its tab strip gets the window pinch). HW: per app, and detach with Korean and Japanese menus. |
| P1 Dock 두 번 핀치·창 제스처 연결 (Dock double pinch and chain) | Fixed; HW | swish-dock e87fa6e; chain wired in integ-core cebf5b8 | Minimized-window Dock tiles are not an origin (X10). HW: pinch-twice timing and a chained title-bar gesture. |
| P1 Mission Control / App Exposé 제스처 | Partly; HW | swish-dock 62c6127, e87fa6e | Thumbnail gestures (pinch in: close, twice: quit, swipe down: minimize; off by default) and matched ✕/W/⇧W/M/H. Not done: moving a window to another Space, and `missionControlSpace` (a Space to another display). On macOS 27 Mission Control ignores synthetic drags (external report, not reproduced); on 14–26 a test would move the user's real windows. |
| P1 세 손가락 뒤 오동작과 Dock 종료 보호 | Fixed; HW | swish-dock e87fa6e | Same as S01 and S02. |
| P2 Super/General/Screen/Secondary/Tertiary 수식키 | Partly | swish-titlebar 77ecbea | Roles, clash checks, Restore Modifiers, ⇧ for 3 × 2, ⌃ for 3 × 3 and Super anywhere are done. Not done: Super required for all gestures (X06), Super on Dock icons. Tap and hold, then sideways still moves a Space; the centre third is reached by chaining. |
| P2 메뉴바와 앱 전환 범위 | Fixed (as options); HW | swish-dock e87fa6e, 37dcedb | Dock gestures on the app's menu (off) and the ⌘-Tab switcher (the default stays AOM's window switcher). The menu-bar double tap still covers only windows in AOM's snap history (G31). |
| P2 키보드 조합·취소·세부 설정 | Partly | swish-titlebar 77ecbea, 76a0a3e | Done: ⌃⌥⌘/⇧, the center key, Dvorak, Esc cancel (while AOM's keyboard tap is installed), native tiling, display timeout, Secondary suspends drag-unsnap, tooltip. Not done: per-gesture switches (X19), Active Event Listener (X18), Include Screen Edges (X30), Spaces and close hotkeys, separate Screens chain and cursor options (X41), tooltip size and Hide Cursor (X44). |
| P3 Magic Mouse와 업데이트·진단 | Not done | — | Magic Mouse has no input path in AOM (out of the project's scope). AOM does not update itself by policy. Swish's repair commands (X48) were not added. |

## 3. Deep report

### 3.1 F01–F06

| ID | Finding | Status | Where | Left open |
|---|---|---|---|---|
| F01 | No multi-motion within one touch | Fixed; HW | swish-titlebar b2a6307, 988fedf | A 0.25 s rest locks a swipe or pinch, the next move starts another gesture; frame gaps and a third finger cancel. Swish's double vertical swipe stays AOM's longer swipe. HW: the lock and its haptic, slow swipes never locking, swipe → pinch. |
| F02 | No tab close or detach, no hand-over after detach | Fixed; HW | swish-titlebar b2a6307, 77ecbea | Detach runs at the lift and chains the new window; a gesture on it is the next touch within 3 s. Hold, then swipe on a tab stays 3.3.2's held swipe. |
| F03 | Dock double pinch and Dock → window chain | Fixed; HW | swish-dock e87fa6e; integ-core cebf5b8 | As REA P1 above. |
| F04 | Start areas limited | Partly; HW | swish-titlebar b2a6307 (tab bars, Super anywhere); swish-dock e87fa6e, 37dcedb (app menu, empty menu bar), 62c6127 (thumbnails) | Not done: Mission Control Space previews, minimized Dock tiles (X10); full-screen menu-bar origins (X11) still unknown. |
| F05 | Modifiers and keyboard range differ | Partly | swish-titlebar 77ecbea | Not done: Spaces hotkeys, Swish's hold-and-release key composition (X27), Super required for all gestures (X06). No close, quit, minimize or full-screen hotkeys: Swish's Advanced tab shows only arrows and Center. |
| F06 | Grid, native tiling and restore details | Partly | swish-titlebar 76a0a3e | Done: native tiling (X31, X32; read-only system options), display timeout (X38), Secondary drag-unsnap bypass (X35). Not done: portrait 3 × 2 axis swap (X28) and Include Screen Edges (X30), which change frame paths shared with the Dock stream and its tests; live Resize Adjacent (X36); the original display after a reconnect (X37). Native tiling cannot keep the Stage Manager offset (a macOS limit). |

### 3.2 §3 weaknesses

| ID | Finding | Status | Where | Left open |
|---|---|---|---|---|
| B01 | Dock pinch-in quit bypassed `mayAct` | Fixed; HW | swish-dock e87fa6e | = S01. |
| B02 | 2→3→2 pinch and swipe | Fixed; HW | swish-dock e87fa6e | = S02. |
| B03 | Dock "hide others" did not check the hidden apps' pause | Fixed | swish-dock e87fa6e | — |
| B04 | Re-snap, neighbour resize and drag-unsnap: pause checks and failure recovery | Partly | swish-titlebar b2a6307 | Pause checks before each write (S03). The history's failure recovery was not changed. |
| B05 | Reset Preferences ignored the Swish settings | Not done | — | `SettingsHub` still removes its 9 keys. No 3.3.3 feature stream owned that view; Restore Modifiers resets only the roles. |
| B06 | Utility HUD ignored the On-screen HUD switch | Fixed | swish-dock e87fa6e | — |
| B07 | No ownership between Dock/menu-bar gestures and user two-finger triggers | Not done | — | Lives in `TrackpadMonitor`, outside the Dock stream's files. |

### 3.3 Privacy findings and the §10 headings

| ID | Finding | Status | Where | Left open |
|---|---|---|---|---|
| PA-01 | Excluded apps still read for suggestions | Fixed; HW | clipboard 4ad2d24 | Paste-log events from before an app was excluded stay in the encrypted log (the ranker ignores them). The macOS 26/27 on-device model path is covered by the gate but no test executes it. HW: an excluded app with "Look at the destination window" on. |
| PA-02 | Secrets suggested into password fields | Fixed; HW | clipboard 4ad2d24 | HW: a Safari login field and Terminal's Secure Keyboard Entry. |
| PA-03 | MCP secret blocking skipped images, links and long text | Fixed; HW | clipboard 56055b5 | Base64 or encrypted blobs are not decoded; a credential split across spaces or lines is not matched. HW: a real MCP client. |
| PA-04 | Classification cache key ignored the middle of the content | Fixed | clipboard 9d2d977 | — |
| BTT-입력 | MIDI input ignored E0/C0/D0/A0 | Fixed; HW | btt-input 3879301 | HW: a real controller, running status, a fader bound to volume. |
| BTT-이식 | Importer took 2 trigger kinds and 8 action IDs | Partly | btt-import a1f3d65, beacb32; integ-core aaf9386 (open panel) | Much wider, still not full compatibility: see BTT-50, BTT-51 and BTT-52 below. No real user preset was read; the report was rendered only in a unit test. |
| CS-옵션 | Recording and editing contract gaps | Partly | capture-recording 4a39f89, 5939c2a, cc886f9, 0a46882; capture-annotation 5db89c2, 71f3f7c | Backgrounds, click options, CS-38 and image layers are done. Not done: window-following recording (CS-32), a full-frame camera (CS-42), motion blur options (CS-46). |

### 3.4 Table rows the stream notes cover

Paste (§13):

| ID | Status | Where | Note |
|---|---|---|---|
| PASTE-03 file contents | Not done | — | Files are still stored as references. |
| PASTE-06 Forever vs limits | Partly | clipboard 79316cf | 1 Year added; Forever is still bounded by 10,000 items and 1 GB (one encrypted archive). Settings help says so. |
| PASTE-11 match boxes in images | Fixed; HW | clipboard 376df64 | Boxes estimate a match by its character share of the line; images indexed before 3.3.3 get boxes when first previewed. |
| PASTE-12 device filter | Not done | — | Needs sync; out of scope. |
| PASTE-13 search from a pinboard | Fixed | clipboard 79316cf | All lists by default (optional); `board:Name` limits it. |
| PASTE-16 link cards | Fixed; HW | clipboard 515d2b4, 4920e00 | Opt-in. No DNS-rebinding guard; no disk cache by design. |
| PASTE-22 one item, one pinboard | Fixed (option) | clipboard 79316cf | Off by default; items already on several boards stay until pinned again. |
| PASTE-23 delete a pinboard with its items | Fixed; HW | clipboard 79316cf | Undoable. |
| PASTE-24 ⌥-drag between boards | Fixed | clipboard 79316cf | With one-pinboard mode on, ⌥-drag copies instead of moving. |
| PASTE-27 Quick Paste modifiers | Not done | — | Unchanged. |
| PASTE-32, -33, -35, -36 | Fixed | clipboard 4ad2d24, 56055b5, 9d2d977 | = PA-01, PA-02, PA-03, PA-04. |
| PASTE-37 image bytes over MCP | Not done | — | `read_item` still returns size and OCR only. |
| PASTE-38, -39, -40 iCloud, shared boards, iOS | Not done | — | Cloud and other platforms are out of scope. |
| PASTE-41 Paste import | Not done | — | — |

CleanShot X (§11):

| ID | Status | Where | Note |
|---|---|---|---|
| CS-21 free image placement | Fixed; HW | capture-annotation 5db89c2, 71f3f7c | Image layers; no flip or crop of a layer; very large layers paste back as flat image layers. |
| CS-22 text background and styles | Fixed; HW | capture-annotation 5db89c2, 71f3f7c | Eight AOM presets (not copies of CleanShot's seven); text is typed in the properties bar, not on the canvas. |
| CS-23 eraser | Fixed; HW | capture-annotation 5db89c2, 71f3f7c | Object and stroke modes; no pixel eraser for the screenshot itself. |
| CS-32 window-following recording | Not done | — | Not started. |
| CS-33 microphone on macOS 14 | Not done | — | Still macOS 15 (ScreenCaptureKit); a separate capture path could not be verified without recording a real microphone. |
| CS-35 mono and level meter | Not done | — | Same reason. |
| CS-37 Do Not Disturb | Partly | capture-recording cc886f9 | The end Shortcut runs after a crash; reading and restoring the previous Focus would need INFocusStatusCenter and a usage string. |
| CS-38 cursor vs click display | Fixed; HW | capture-recording 5939c2a | Once Show Cursor for recordings is set. |
| CS-39 click colour, size, shape, time | Fixed; HW | capture-recording 5939c2a | Sizes are in source pixels, so they look smaller on Retina takes (unchanged). |
| CS-42 camera full frame and ratios | Not done | — | Still a square, 10–60 % of the short side. |
| CS-45 video backgrounds | Fixed; HW | capture-recording 4a39f89, 0a46882 | No wallpaper library; the last background is not remembered; the camera and keystroke badges stay inside the video card. |
| CS-46 motion blur | Not done | — | Unchanged. |
| CS-49 GIF | Partly | capture-recording cc886f9 | Size and loop added; still ≤ 120 s and ≤ 30 fps, no palette or dither options. |

BetterTouchTool (§12):

| ID | Status | Where | Note |
|---|---|---|---|
| BTT-06 pressure differences and stages | Partly; HW | btt-input 1d805da | Stage 1/2 triggers with hysteresis; Left/Right Finger Harder is not an AOM input. |
| BTT-07 continuous value bindings | Fixed; HW | btt-input 526f82b | MIDI CC, bend, pressure, Force Touch pressure, modifier scroll → volume, app volume, brightness. Not: pinch, rotate and swipe travel; keyboard backlight; AirPlay and software-volume outputs are refused. |
| BTT-09 Magic Mouse | Not done | btt-import a1f3d65 | Its 62 BTT triggers are listed as skipped on import; AOM has no Magic Mouse input. |
| BTT-16 continuous drag values | Not done | — | Normal-mouse triggers stay discrete. |
| BTT-20, BTT-21 MIDI input | Fixed; HW | btt-input 3879301 | = BTT-입력. |
| BTT-23 gamepad analog axes | Not done | — | Still threshold crossings. |
| BTT-27 global Touch Bar | Not done | — | No Touch Bar sliders either. |
| BTT-29 floating-menu submenus and search | Not done | btt-input 901cb0b | Sliders were added; submenus and searchable lists need a menu model change. |
| BTT-34 text selection trigger | Not done | — | No AOM trigger type. |
| BTT-35 Power Mode trigger | Not done | — | No AOM trigger type. |
| BTT-47 Move Window to Desktop N | Not done | — | No public API; repeated Space moves are unreliable. |
| BTT-48 focus follows mouse, Stage Manager | Not done | — | Not started. |
| BTT-50 importer scope | Fixed | btt-import a1f3d65, beacb32 | Trackpad, keyboard, key-sequence, normal-mouse, named and Other triggers; about 180 action IDs. |
| BTT-51 app scope, conditions, unknown fields | Partly | btt-import a1f3d65 | App groups and enabled state are kept; conditions make a trigger approximate (added disabled); `BT.*` special groups, preset settings, plugins and compressed presets are refused or ignored, and reported. |
| BTT-52 every action ID | Partly | btt-import a1f3d65 | About 180 IDs map; the rest are named in the report (list in work/integration-333/btt-import.md). |

## 4. Integration (this branch)

- Backups (a46dae2): every 3.3.3 setting above is in the backup list or left out with a reason
  (`AOMAudioDiagnosticsResetAt`: a one-off request; the recording camera and microphone: this
  Mac's devices). `BackupScopeTests` now also sees keys built as `"…" + name`.
- Chain wiring (cebf5b8): `TrackpadUtilityGestures.chainWindow` calls
  `TitleBarWindowSnap.beginChain(window:pid:reason:)` from launch.
- Import Preset (aaf9386): the open panel offers `.bttpreset` files. Settings › Import BTT Preset
  is a view outside this branch.
- Settings rows for the new keys are placed by the views' own integration branch; the labels in
  What's New, the CHANGELOG and the release notes are the stream notes' labels.
