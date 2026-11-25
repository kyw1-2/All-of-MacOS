# AOM 7.18 — Calm Workbench (visible UI/UX overhaul + 7.17 re-review fixes)

Base: `dadc23a` (7.17.0, installed). Branch `feat/7.18`. Orchestrated by Claude Code, implemented by
five GPT-6.2 Sol workers, each on its own branch `feat/7.18-wN` with a disjoint file set.

## Inputs (all read before planning)

- `~/Downloads/AOM-7.17.0-독립재검수-UIUX-결함-후속명세-2026-11-25.md` — R01–R18, residual D01–D32.
- `~/Downloads/AOM-7.16.1-상용앱19종-디자인-바이너리검수-2026-11-25.md` — D01–D32, §3 principles, §5 per-page layout.
- `~/Downloads/AOM-7.16-통합검수-상용앱-개선명세-2026-11-25.md` — V/M/N items (N01–N20), C01–C15.
- `docs/design-7.17-workbench2.md`, `docs/design-7.14…7.16.md`; Oracle `/data/work/rea/aom-ux-20261117/report/*`,
  `/data/work/aom-design-binary-20261125/evidence/*` (19 commercial apps).
- Independent static review pasted by the user on 2026-11-25 (search split, duplicate ⋯, action bar `prefix(3)`,
  Workspace rail threshold, empty stub, Menu Bar nested card / auto sheet, AI not in Settings search, drawer double divider).
  Claude checked each claim against `9605607`; all are real.
- **Baseline screenshots** (new): `.github/workflows/ui-snapshots.yml` + `scripts/ui-snapshot-matrix.sh`, run 45593952112 —
  13 pages × light/dark × 980×600 and 1024×674 (the runner display is 1024×768, so 1320×860 is clamped) + Settings,
  launcher and menu bar panel. AOM draws the windows itself (`--aom-preview-snapshot`): no glass blur.

## What the baseline shows (Claude, from the screenshots)

1. **Toolbar overload.** Every page shows a disabled `⋯` (Actions), a 🔍 (in-window palette) and the stethoscope
   (Diagnostics) before its own items; Clipboard ends up with 10 toolbar items, Automation 9, Capture 7, Audio 6,
   including a *second* `⋯` menu. Window Tiling's 4 toolbar buttons repeat the 5 tiles under the display.
2. **Two searches.** The sidebar "Launcher ⌘K" opens the floating launcher; the toolbar 🔍 opens a second palette inside
   the window; list pages add a third (page filter).
3. **Menu Bar page** is loud: three solid accent-blue lanes, tiny icons, and a 5-line instruction paragraph in a card that
   is itself inside another card. First visit opens a modal sheet before the page is seen.
4. **Workspace**: at the default 1280×800 window the rail never shows (needs 1044 pt, has ~1004 pt). An empty
   "Running now" card takes a whole block. The Now/All Tools switch is a heavy prominent segmented bar.
5. **Settings**: the sidebar search field truncates to "Search Se…"; AI isn't searchable.
6. Previews have no data (empty Clipboard, Automation, Capture), so lists can't be judged — previews need sample data.

## Design rules for 7.18 (apply everywhere; extend existing tokens, no new design system)

- **Toolbar budget**: at most *title · page filter field (list pages only) · one page view/options control ·
  page primary action*. Global items are not repeated per page:
  - Diagnostics leaves the toolbar; it stays in View/Window menu with its shortcut (and the toolbar item appears only
    while the drawer is open, to close it).
  - Actions `⋯` appears only when the page has a selection context (no permanently disabled button).
  - The in-window palette 🔍 is removed from the toolbar: ⌘K / sidebar → the one launcher; ⌘F → the page filter.
  - A page's own options menu uses `slider.horizontal.3` / "View" — never a second `ellipsis.circle`.
- **Action bar**: when a selection has more than 3 actions, a 4th "More" menu holds the rest (destructive last).
- **Calm colour**: accent fills only for the selected row/primary button/drop target. Lanes, segmented tracks and
  wells are neutral (`AOMColor.sunken`/`track`); status keeps glyph + text.
- **One card level**: a card never contains a card (D07). Inner groups are hairline-separated rows or a well.
- **Explanations** longer than one line go behind an ⓘ (`AOMInfoButton`) or a disclosure; pages show one status line.
- **Empty states** are one compact line inside the relevant section, not a full card.
- **Onboarding** is a dismissible banner (`AOMNotice`) at the top of the page, never an automatic sheet.
- Keep: 13 pt body, 34/44 pt rows, `AOMWorkbenchArrangement`, LRU-5 page host, page lifecycle gating,
  all engines, all user defaults keys, HomePod/audio engine, no new timers/polling.

## Work split (one file owner per file; see each worker's brief)

| Worker | Area | Files owned (plus new files they create) | Items |
|---|---|---|---|
| W1 | Shell & shared kit | `MainShell.swift`, `AOMActionBar.swift`, `AOMToolbarSearchField.swift`, `AOMModuleKit.swift`, `AOMWorkbenchLayout.swift`, `AOMComponents.swift`, `AOMTheme.swift`, `AOMTokens.swift`, `DiagnosticDrawer.swift`, `ModernTabs.swift` | toolbar budget (global part), search unification, action bar overflow, drawer double divider, R01 R02 R06 R07 R12 R13 R16 R17, D06, D07 (shared surfaces), AOMStatusHeader via card surface, token doc fixes |
| W2 | Clipboard & Automation | `ClipboardStudioView.swift`, `Clipboard*.swift`, `Views/Clipboard/*`, `ModernGesturesWorkspace.swift`, `Views/Automation/*`, `Automation*.swift`, `ActionListPanel.swift`, `TriggerListPanel.swift` | R03 R04 R05 R14 R18, D13 drag reorder, D16 lazy decode/cancel, recipe card nesting, page toolbar diet, preview sample data for both pages |
| W3 | Workspace, Settings, Launcher, Menu Bar | `HomeDashboardView.swift`, `SettingsHub.swift`, `QuickCommandPalette*.swift`, `Views/Launcher/*`, `Views/MenuBar/*`, `AOMMenuBarPanel.swift` | R08 R09 R10, D10 D11 D32, Workspace rail/empty Running now/segmented, Settings search width + AI in search, Menu Bar calm lanes + flat card + banner onboarding + ⓘ help, menu bar panel a11y status |
| W4 | Audio, Capture, Window Tiling | `AudioWorkspaceView.swift`, `AppAudioMixer.swift`, `Views/Audio/*`, `Audio*.swift`, `CaptureStudioView.swift`, `Views/Capture/*`, `Capture*.swift`, `ModernWindowSnappingView.swift`, `AOMMonitorCanvas.swift`, `SnapEditors.swift` | R11 R15, D17 mixer table, D19 Grid/List + thumbnail skeleton, inspector fallback + saved width for Audio/Capture, Tiling toolbar de-dup, remove empty `AOMAnnotateWorkbenchView.swift` stub (update `DesignTokenHygieneTests` to the real file), capture preview sample data |
| W5 | Files, Folder Rules, Text Actions, Activity, System Tools, Focus | `Views/Files/*`, `Views/FolderRules/*`, `Views/TextActions/*`, `StatisticsView.swift`, `SystemTools*.swift`, `Views/Focus/*` | D25 D26 D28 D29 D30 residue, Files inspector fallback + saved width, Folder Rules inline `.defaultAction/.cancelAction` removal, D09 Folder Rules inspector rows, page toolbar diet, one-line empty states |

Shared-kit dependency rule: W1 only *adds* API or changes visuals of existing components; it doesn't rename or remove
public API the other workers' files call. Workers 2–5 don't edit W1's files; if they need a shared change they write it in
their final report and Claude applies it after merging.

## Verification (CI only — no local `swift build`/`swift test` on the MacBook)

- Each worker pushes `feat/7.18-wN` with `[snapshots]` in a commit message → `ui-snapshots.yml` builds and renders;
  compile errors show in its log. At the end: `gh workflow run tests.yml --ref feat/7.18-wN` must pass.
- Claude merges W1…W5 into `feat/7.18`, runs tests + snapshots on the merge, compares against the baseline, bumps to 7.18.0,
  pushes to `main` (release.yml signs and publishes), installs the DMG.

## Status (2026-11-25, release 7.18.0)

**How it ran.** Five Sol workers started at 19:2x KST. W4 died from "prompt too long" (no commits); W4a/W4b replaced it.
At ~19:55 every ChatGPT account hit its usage limit (429 until 22:00), so all workers stopped. Claude recovered each
worktree (committed WIP as `wip(7.18-wN)`), merged W1, W5, W2, W4a and W4b, finished or reverted half-done edits, and did W3's area itself.

| Worker | Result |
|---|---|
| W1 shell/kit | `749b1bd`, `eb4502b` merged. Toolbar budget, action bar More menu, drawer divider, compact drill-in (`.aomListDetailSelection`), per-module inspector width, focus tokens, semantic header dedup, save-state model, nested-section flattening. Claude restored the coloured page-header marks (W1 had made them grey; identity colour is a 7.14 decision). |
| W2 Clipboard/Automation | `7e06c80` + recovered WIP. Live explicit targets (`AOMActionTarget`), receipt-based delete/undo, cancellable thumbnails, sample data; Automation drag reorder, flat branches, toolbar search/scope. Claude finished the half-trimmed `AutomationListHeader` and fixed a ViewBuilder local func. |
| W3 Workspace/Settings/Launcher/Menu Bar | Worker made no commits (wrong base, then stopped). Done by Claude: rail at default size (260 pt rail, 2 columns ≥ 680 pt), one-line Nothing running, Settings "Search" + AI catalog items, Menu Bar banner/ⓘ/flat selected item, launcher dimmed reasons, panel Running/Paused text. NOT_DONE: R08 per-result reveal, R09 snapshot caching, R10 units/"as of", N07, N08. |
| W4a Audio | WIP was a half-done refactor (optional `service`, hundreds of call sites unchanged) — **reverted**. Claude changed only the options icon and the duplicate button style. NOT_DONE: D17 mixer table, R11, Audio inspector width/fallback, Audio sample data. |
| W4b Capture/Tiling | Recovered: Tiling toolbar de-dup, R15 display re-resolve (Claude fixed two leftover call sites), empty annotate stub removed from code and hygiene test. Claude changed Capture's ⋯ menu to the options icon. NOT_DONE: D19 Grid/List + skeletons, Capture inspector fallback, Capture sample data. |
| W5 Files/Rules/Text/Activity/Tools/Focus | `3aa6c3b`, `c10546a`, `c8df3c1` merged (Claude fixed `.ok(items:)`). |

**CI.** Merge `0f121be`: snapshots run 45602334316 success (64 PNGs); `tests.yml` run 45602353316 — `swift test` step passed.
Screens checked by Claude after the merge: Workspace, Clipboard (sample data), Automation dark (sample data), Menu Bar dark,
Capture, Files 980×600, Window Tiling, Settings.

**NOT_RUN** (unchanged limits): real-window resize ×30, VoiceOver/Reduce Motion/Transparency, p50/p95 transitions, 15-minute idle,
1320+ widths (the CI display is 1024×768).

## 7.19.0 follow-up (2026-11-25, Claude)

Done: Audio column titles + sample apps (D17 header; rows already shared fixed widths), Capture List view + sample captures (D19 list; thumbnails are already in memory, so no skeleton), Menu Bar calm lanes + bar strip + read freshness (N08), Settings per-result Show + catalog cache (R08, R09), permission states (N07), rail "As of" (R10), Clipboard Copy on the shown item, Text Actions picker widths, Automation title room, Audio mixer icon.
Still open: Audio/Capture inspector width persistence and narrow sheet fallback (Audio already expands effects inline when narrow), R11 per-row routing beyond the existing status line, real-window QA (resize ×30, VoiceOver, p50/p95, idle).
CI: `cb4de8a` snapshots 45612472483 success, `swift test` passed in 45612494633.
