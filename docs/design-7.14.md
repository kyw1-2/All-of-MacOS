# AOM 7.14 — Codex's 7.13.0 review, main window look, Mute Mic tile

## Codex review (2026-11-24, `AOM-7.13.0-패치-검수-보고서`)

| Codex item | Verified | Change |
|---|---|---|
| S1 Delete Shelf undo points at a newcomer | Yes: `deleteShelf` undo ignored `moveBack` failures | Undo runs `itemsToRestore` over the shelf's items (Trash path for a failed put-back, missing rows dropped and counted). Test `AOM714Tests`. |
| S2 1 MB diff on main (288 ms) | Yes | `PaletteDiffJob`: inline under 64 KB, otherwise detached task + "Comparing…" row; cleared in `leave(.clipboardDiff)` and on disappear. |
| S3 saved-search duration overflow | Yes: `Int(seconds / size)` on ∞ | `duration` rejects non-finite or > 100 y; `durationText` and the predicate clamp old values. |
| PDF cache: expired entries stay, re-insert after stop | Yes | Expired entries evicted on every read and by a one-shot sweep 10 min after the last insert; `cacheGeneration` blocks a read that started before `clearCache`. |
| Clipboard diff memo kept after close | Yes | Owned by `PaletteDiffJob`, cleared on leave. |
| Free Times reads titles/places/notes | Yes (`events` builds full `Event`) | `PaletteSchedule.busyTimes` reads start/end/all-day/availability/status only. |
| Concurrent shelf drops share one progress | Yes | `receiving` batches summed by `showReceiveProgress()`. |
| Dialog recents de-dup vs Finder order | Yes | `rawRecents` kept; recomputed when Finder arrives. |
| F14 duplicate success invalidates adopted handle | Yes | `.m` remembers the delivered assertion (weak) and skips invalidating it. |
| F09 settings end 23:59 vs reader 24:00 | Minor | Not changed. |
| F12, F20–22 | Follow-ups in Codex too | Not in this release. |

## Main window look

### First pass, then the mock-up

A first pass gave every page a 52 pt hero on a coloured band. The user then pointed at the Native Workbench mock-up and spec in Downloads (`AOM-7.13.0-MainWindow-UIUX-2026-11-24-디자인목업.html`, `…-개편명세서.md`, 36 tickets M01–M36, 26 reference apps + HIG), whose §4 rules out an arbitrary hero, shadows on content and a page title repeated under the toolbar, and sets detail headers at 16–18 pt. The header was brought into line before release.

| Change (shipped) | Where | Mock-up / reference |
|---|---|---|
| Page header: 36 pt solid squircle + 18 pt semibold status sentence + callout subtitle, no band, no shadow; an off tool's mark dims | `AOMHeroBand` (AOMComponents), `AOMPageHeader` when it carries the page identity | §4 typography, M01; System Settings 26, Stats |
| Workspace header says the state ("Ready to work" / "AOM is paused", "All systems running · N automations enabled") instead of repeating "Workspace" | `WorkspaceBanner` | Mock-up Workspace screen, M01 |
| Sidebar **Favorites** (right-click › Add to Favorites, Move Up/Down, max 6); a pinned page leaves its group so nothing is selected twice; ⌘1–9 and route ids unchanged | `AOMSidebar`, `AOMSidebarFavorites` | M02; Linear, Things |
| Sidebar marks: solid squircles 20 pt; status words as capsules | `AOMSidebar.navigationItem`, `AOMSidebarStatusBadge` | System Settings, Bartender 7, Ice; Mail |
| Workspace tool rows: 28 pt solid marks, 46 pt rows | `AOMModuleTile` | One Switch, Control Center |
| Section counts as capsules | `AOMSectionTitle` | Raycast, Mail |
| Empty pages: the tool's solid mark (no shadow) | `AOMEmptyState` | Shortcuts gallery |
| Automation input kinds: tinted marks | `AutomationInputCard` | BetterTouchTool |

Setting rows inside a page keep neutral `AOMRowIcon`s (6.0 "Calm": colour marks which tool, not every row).

### Mock-up tickets not in 7.14

M03 (bottom action bar → toolbar More / selection-only bar), M04 (main-window opaque surface role), the Inspector column of M11–M36 (Automation, Audio, Menu Bar, Clipboard, Window Tiling, Folder Rules), M06–M08 Home re-layout, M09–M10 Settings breadcrumbs. Each changes a page's structure and its selection model; they need their own release with per-page previews. M05 (keep the 5-page LRU) is unchanged by design.

## Ghidra / REA material on Oracle — coverage check

Before 7.14 only the written reports had been read, not every raw output. Inventory (2026-11-24): `/data/work/rea/aom-ux-20261117/json` (Alfred, AltTab, BTT, Bartender + BartenderService + nibs, Boop, Bunch, CleanShot X, Espanso, InputSourcePro, KYA, KeyCastr, LinearMouse, Maccy, Mos, Paste, Pearcleaner, Quicksilver, Raycast + palette, Rectangle, Shottr, SoundSource, Stats, SwiftBar, Yoink), `macutils-20261114` (Itsycal, Ice, Hammerspoon, AltTab), `popclip-202611`, `/data/re/20261102` (AlDente, Hidden Bar, iStat Menus, MonitorControl), `/data/re/20261106-aom-popclip-menubar` (Bartender 7, Ice, PopClip), `aom-audit-20261124/fresh-re` (Moom, Witch, Default Folder X, Unclutter, One Switch, Workspaces, TextSniper, HazeOver). Every app appears in at least one report (01–07, macutils 04, popclip, GPT 7.12.1 §13–26).

Report recommendations checked against the code (keyword evidence):

| In AOM | Not in AOM yet |
|---|---|
| A1 last run in automation rows, A4 monospaced digits (partly), A6 permission guidance, A11 assertion split, A16 slider+field, B1 app pin/hide, B3 boost, B4 orphan files, B6 pointer acceleration + restore, B8 AXEnhancedUserInterface, B13 BTT preset import, B16 frecency, B17 one overlay at a time, B18 Keep Awake conditions, B19 status item positions, B20 menu shelf; Bartender 7 lanes/Bar (7.9–7.10); Raycast launcher (6.5–7.11); Yoink shelves (7.12) | A2 Maccy ⇧ Clear all (destructive; needs a confirm design), A3 clipboard search/preview/sort settings, A7 Boop script folder, A12 key-repeat sync, A15 display-link scrolling, B2 SoundSource per-cause drop failures, B9 Shottr toolbar order (= GPT UX-22), B15 BTT action category badges, Visual Focus (HazeOver, UX3-30), Moom/Witch/DFX/Unclutter/One Switch/Workspaces/TextSniper items UX3-01–29 except 05/11/14 |

## Menu bar panel

The Mute Mic tile is removed (user request). The live-session row for a muted microphone stays, so a mute from a shortcut or meeting rule can still be ended from the panel.
