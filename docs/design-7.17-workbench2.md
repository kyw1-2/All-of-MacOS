# AOM Native Workbench 2 — D01–D32 implementation status

Input: `AOM-7.16.1-상용앱19종-디자인-바이너리검수-2026-11-25.md` (Google Drive, 28.1 KB). The Oracle evidence at `/data/work/aom-design-binary-20261125/evidence/` was not reachable from this session and isn't copied here. Base `e72ad94ae470` (7.16.1).

Second pass, after the independent review of `7104de5`: 1 met, 12 partial, 19 not done, plus 8 code problems. All 8 problems are addressed (see "Review follow-up").

The spec's observed behaviours are written independently with public SwiftUI/AppKit APIs and AOM's own components: selection kept across layout changes, saved widths checked, an inspector separate from diagnostics, and so on. No decompiled code, assets or private APIs from the 19 reference apps are used. There is no new design system, no second inspector component (every inspector is `AOMInspector` + `AOMInspectorSection` + `AOMInspectorRow`), no new timer or polling, and no engine rewrite.

Status values: DONE (code) means compiled and unit-tested on macOS CI, but not checked on screen. PARTIAL means part of the item is done; the rest is listed. NOT_DONE / NA. No item is marked DONE without "(code)", because the screenshot matrix is NOT_RUN.

## Shared rules — `AllOfMacOS/Views/AOMWorkbenchLayout.swift`

- `AOMPaneWidth` (`:20`): checks stored widths for NaN, ±∞, ≤0 and out-of-range values. The drawn width shrinks to fit, but only a drag writes the stored width. A drag starts from the displayed width.
- `AOMWorkbenchPolicy`, `AOMWorkbenchArrangement.resolve` (`:56`, `:91`): decide drill-in / list+detail / list+detail+inspector from the measured width and the drawn list width, with 20 pt of hysteresis. **Called by the pages** (review P0-1): `AOMListDetail` (`AOMModuleKit.swift:253`), Folder Rules, and Automation (`ModernGesturesWorkspace.swift`, `updateArrangement`).
- `AOMStableSelection` (`:124`): a search or filter never moves the selection to another row. Actions only run on a row that is on screen.
- `AOMHeaderDedup`, `AOMInspectorRow` / `AOMInspectorDisclosure` (`:181`), `AOMRevealFocus` / `AOMFocusFirstControl` (`:241`, `:260`), `AOMAutomationEditorStatus` (`:307`).
- Pages whose layout is a single scrolling column (Audio, Capture, Files) put their inspector beside the page with `AOMWorkbenchPolicy.sideBySide` and the same hysteresis.

## Review follow-up (8 problems in `7104de5`)

| # | Problem | Fix |
|---|---|---|
| P0-1 | The drill-in policy wasn't called by any screen | `AOMWorkbenchArrangement.resolve` decides `AOMListDetail`, Folder Rules' inspector and Automation's drill-in / split / step inspector. |
| P0-2 | Automation's table minimum (420 pt) wasn't used | `listRange` follows the view mode; the view mode, list and table widths re-run the resolver. Test `testAutomationTableMinimumSwitchesEarlier`. |
| P0-3 | Dragging the list divider didn't re-check the inspector | `resolve(…, list:)` takes the drawn list width; `AOMListDetail`, Folder Rules and Automation re-run it on list width changes. Test `testInspectorFollowsTheDrawnListWidth`. |
| P0-4 | Automation ⌫ bypassed `actionable()` | `aomPageDeleteCommand` resolves through `actionable(id)`. |
| P1-5 | Automation views were rebuilt on resize, losing scroll | `panes(totalWidth:)`: one hierarchy; the list keeps its place (hidden at zero width when the editor fills a narrow window), so its scroll and selection survive. |
| P1-6 | Folder Rules could run a preview that was still refreshing | `canRunPicked` requires a preview that isn't loading and isn't stale. Shows "Updating the preview…". Test `testFolderRulesRunSelectedGate`. |
| P1-7 | Settings reveal didn't focus the control | `AOMFocusFirstControl` makes the first AppKit control in the revealed row first responder. `AOMRevealFocus.pick` is tested. Screen check NOT_RUN. |
| P1-8 | `AOMInspectorRow` had no users | It's now used by the Clipboard, Automation step, Audio, Capture and Files inspectors, the Window Tiling display details and the Menu Bar item panel. |

## D01–D32

| ID | Status | Source | Evidence / what remains |
|---|---|---|---|
| D01 Inspector vs Diagnostics | DONE (code) | `MainShell.swift` `AOMDiagnosticsNames` | Toolbar "Diagnostics" (stethoscope); Window menu and accessibility use the same names. Test. |
| D02 Shared adaptive split | DONE (code) | `AOMModuleKit.swift:192`, Folder Rules, Automation, Window Tiling | Uses the resolver (above). Window Tiling's 900 pt switch has hysteresis. Screenshots NOT_RUN. |
| D03 Selection/draft/scroll kept | PARTIAL | `ModernGesturesWorkspace.swift:404`, `AOMListDetail` | Selection is never written by a resize. The list keeps its hierarchy position across drill-in ↔ split. Not run: a 30-resize check with typing in a real window. |
| D04 Saved width validation/restore | DONE (code) | `AOMPaneWidth`, `AOMResizeDivider` | Every list and inspector divider (Folder Rules, Clipboard, Automation list/table/step inspector, AOMListDetail). Tests. |
| D05 Actionable vs auto-highlighted | DONE (code) | Automation `actionable`, Clipboard, Capture, Audio, Folder Rules | When a search or filter hides the selection, it becomes nil in Automation, Clipboard, Capture and Audio. Bar, ⌫, Return, Space and ⌘C act only on rows still on screen. Folder Rules won't run picked items from a stale or refreshing preview. |
| D06 Duplicate title/status | PARTIAL | `AOMComponents.swift` `shownStatus` | Header pill and subtitle dedupe. Toolbar overflow behaviour NOT_RUN. |
| D07 Card nesting / opacity | NOT_DONE | — | Needs a per-callsite audit with light/dark/Reduce Transparency screenshots. |
| D08 Compact sidebar | DONE (code) | `MainShell.swift` `AOMSidebarDensity`, View › Compact Sidebar | 200–208 pt, off by default. Label and accessibility check on screen NOT_RUN. |
| D09 Inspector rows | DONE (code) | `AOMInspectorRow`, `AOMInspectorDisclosure` | Used by 7 surfaces (above). Folder Rules' existing inspector not migrated. |
| D10 Workspace Now | PARTIAL | `HomeDashboardView.swift` | Now order: needs attention → running → setup. All Tools is unchanged. |
| D11 Workspace rail | DONE (code) | `HomeDashboardView.swift:432` `WorkspaceRailChoice` | One of Today / This Mac / Recent at a time; the hidden ones aren't built. Per-metric units/source labels NOT_DONE. |
| D12 Automation 3-pane | DONE (code) | `ModernGesturesWorkspace.swift:404,444` | list \| When→Then \| step inspector where 300 + 440 + 260 pt fit. The chevron opens the step there (accent outline). Reuses `ActionConfigView`; ⌥⌘I toggles it. |
| D13 Step summary/reorder | NA (existing) | `ActionCardView` | Move up/down, duplicate, delete, copy and enable already exist per step, and IDs are kept. Drag reorder NOT_DONE. |
| D14 Editor status | DONE (code) | `editorStatus` `:851`, `AOMAutomationEditorStatus` | One line under the name: on and saved / off / no steps / can't start (input) / can't run (steps). Test. |
| D15 Clipboard typed preview + metadata | DONE (code) | `ClipboardStudioView.swift:555` | Metadata inspector (kind, source, time, contents, pinboards, bundle ID). Falls back to the detail pane in a narrow window. Preview reset per item (`.id`). |
| D16 Filter / pinboard state | PARTIAL | `ClipboardLibraryFilterMemory` | Pinboard and type restored after a rebuild, and inspector state kept. Lazy image decode/cancel: not changed (existing cache). |
| D17 Audio mixer columns | PARTIAL | `AudioWorkspaceView.swift` | Rows keep their shared column metrics. Secondary controls move to the inspector when it's shown. A real table layout isn't done. |
| D18 Per-app audio inspector | DONE (code) | `:111`, `ApplicationAudioEffects` `:1017` | Selected app's status, volume, boost, output and effects. One effects view shared inline and in the inspector. Engine, metering and HomePod unchanged. |
| D19 Capture commands vs library | PARTIAL | `CaptureStudioView.swift:211` | Commands on top, library below, inspector beside. Grid/List switch and thumbnail skeletons NOT_DONE. |
| D20 Capture properties inspector | DONE (code) | `:157` | Kind, pixels/points/scale, date, kept, file name/format/size/folder, commands. File size read off the main thread. |
| D21 Monitor canvas | DONE (code) | `AOMMonitorCanvas.swift` | Real displays to scale, `visibleFrame` drawn apart from the frame, enabled zones in the usable area, menu bar/Dock insets. Re-read only on display changes. Tests. |
| D22 Restore plan preview | DONE (code) | `WindowManager.swift:136,315`, `SnapEditors.swift` | `SavedWindowRestorePlan` (restore's own rules) shows what moves where and why each window is skipped. Restore uses the same plan. Test. |
| D23 Menu Bar lanes + item | DONE (code) | `MenuBarLayoutEditor.swift:237` | Click selects. Name, app, section, lock reason, Move to and Rename appear under the lanes. Accessibility action. |
| D24 Menu Bar states/flicker | NA (7.16) | — | 7.16 V06/V07. Drag flicker NOT_RUN. |
| D25 Files locations/info | DONE (code) | `Files/FilesInfoInspector.swift` | Selected recent file: kind, size, dates, clickable path (~), Open / Quick Look / Show in Finder / Copy Path. Test. |
| D26 ZIP/compare progress | NA (existing) | `ZipExtractView.swift` | Progress, Stop, partial-failure message and selection kept apart from the filter already exist. Not changed. |
| D27 Folder Rules verdicts / stale | DONE (code) | `FolderRulesPageModel.swift:37,459`, `FolderRulesPanes.swift` | Out of date / updating markers; Run Selected gated; match / no match / can't tell per condition and overall. Tests. |
| D28 Text Actions | PARTIAL | `TextActionsPage.swift` via `AOMListDetail` | Shared split behaviour. Reorder and preview split not changed. |
| D29 System Tools | DONE (code) | `SystemToolsView.swift:163,252` | Last result strip (tool, time, message, Run Again, undo note). Destructive tools already confirm. |
| D30 Activity metrics vs log | DONE (code) | `StatisticsView.swift:229,545` | Event log apart from the figures. Same period, narrowed by the chart's bar, runs only by default. Test. |
| D31 Settings search → setting | DONE (code) | `SettingsHub.swift` | Show in <Category>, scroll, mark, focus the control, blocked while a sheet is open. Focus on screen NOT_RUN. |
| D32 Palette selection/search | NA (existing) | `QuickCommandPalette.swift` | Existing return selection / pending selection. Disabled-reason display not reviewed. |

## Verification

- macOS CI (`tests.yml`, workflow_dispatch, `xcode-27`): results are recorded per commit in the pull request / session report.
- NOT_RUN: the 84-screenshot matrix, resize ×30 with draft and scroll, keyboard/VoiceOver/Reduce Motion/Transparency, warm/cold page transitions p50/p95, 15-minute idle CPU/RSS/wakeups. No Mac was attached to this session.
- No release, install, version bump or merge.
