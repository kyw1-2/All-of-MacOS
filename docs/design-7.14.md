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

Shared components changed, so all twelve pages move together:

| Change | Where | Reference apps |
|---|---|---|
| Hero band: 52 pt solid squircle with a hue shadow, title 22 pt bold, subtitle, status pill, trailing controls, on a hue wash; neutral when the tool is off; opaque with an edge under Reduce Transparency / Increase Contrast | `AOMHeroBand` (AOMComponents), used by `AOMPageHeader` when it carries the page identity, and by `WorkspaceBanner` | System Settings 26 pane headers, Stats module header, Pearcleaner app header, Bartender 7 panes, CleanShot X settings |
| Sidebar marks: solid squircles 20 pt | `AOMSidebar.navigationItem` | System Settings, Bartender 7, Ice, Stats |
| Sidebar status as capsules | `AOMSidebarStatusBadge` | Mail counts, Bartender 7 badges |
| Workspace tool rows: 28 pt solid marks, rows 46 pt | `AOMModuleTile`, `AOMSize.moduleRowHeight` | One Switch, Control Center |
| Section counts as capsules | `AOMSectionTitle` | Raycast settings, Mail |
| Empty pages: the hero mark lifted | `AOMEmptyState` | Shortcuts gallery, CleanShot X empty history |
| Automation input kinds: tinted marks | `AutomationInputCard` | BetterTouchTool input tabs |

6.0 "Calm" had moved marks to plain glyphs because saturated squircles on every *row* read as decoration. 7.14 uses solid marks only where each stands for a destination (sidebar, page hero, Workspace tool rows); setting rows inside a page keep neutral `AOMRowIcon`s.

Checked with `--aom-preview-snapshot` in light and dark (Workspace, Automation, Capture, Audio, Files).

## Menu bar panel

The Mute Mic tile is removed (user request). The live-session row for a muted microphone stays, so a mute from a shortcut or meeting rule can still be ended from the panel.
