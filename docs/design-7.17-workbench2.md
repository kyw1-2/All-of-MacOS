# AOM Native Workbench 2 — D01–D32 implementation status

Input: `AOM-7.16.1-상용앱19종-디자인-바이너리검수-2026-11-25.md` (Google Drive, 28.1 KB; Oracle evidence at `/data/work/aom-design-binary-20261125/evidence/`, not copied here). Base `e72ad94ae470` (7.16.1). The spec's observed behaviours (selection kept across layout changes, saved widths validated, an inspector separate from diagnostics, and so on) are written independently with public SwiftUI/AppKit APIs and AOM's own components. No decompiled code, assets or private APIs from the 19 reference apps are used. There is no new design system, no second inspector component, no new timer or polling, and no engine was rewritten.

Shared rules: `AllOfMacOS/Views/AOMWorkbenchLayout.swift`. These are plain functions, tested in `AllOfMacOSTests/AOMWorkbench2Tests.swift`:

- `AOMPaneWidth` (`:20`): checks stored widths for NaN, ±∞, ≤0 and out-of-range values, shrinks the drawn width to fit the window, and starts a drag from the width on screen.
- `AOMWorkbenchPolicy` / `AOMWorkbenchArrangement` (`:56`, `:91`): decide side by side vs. drill-in and whether an inspector fits, using the measured width and 20 pt of hysteresis.
- `AOMStableSelection` (`:118`): keeps the selection the same when the layout changes. A search never moves the selection to another row. Actions only run on a row that is still on screen.
- `AOMHeaderDedup` (`:142`): drops a header pill or subtitle that repeats the sentence or the toolbar.
- `AOMInspectorRow` / `AOMInspectorDisclosure` (`:175`, `:212`).

Status values: DONE, PARTIAL, NOT_DONE, NA. "(code)" means compiled and unit-tested on macOS CI, but not checked on screen.

| ID | Status | Source | Evidence / what remains |
|---|---|---|---|
| D01 Inspector vs Diagnostics | DONE (code) | `MainShell.swift:126`, `AOMDiagnosticsNames` `:658` | The toolbar menu is now "Diagnostics" with the `stethoscope` symbol. It was "Inspect" with `sidebar.right`. The toolbar, the Window menu and the accessibility label all use the same names. Test `testDiagnosticsIsNotCalledInspector`. Page inspectors (Folder Rules ⌥⌘I, `AOMListDetail`) are the only "Inspector". |
| D02 Shared adaptive split | DONE (code) | `AOMModuleKit.swift:192` `AOMListDetail`; `FolderRulesPage.swift:38`; `ModernGesturesWorkspace.swift:338`; `ClipboardStudioView.swift:331` | `AOMListDetail` now draws plain columns, as Folder Rules does, instead of the system `.inspector`. It measures its own width, keeps the detail at 420 pt or wider, and puts the inspector beside the detail only when all three fit. Otherwise it floats the inspector over the detail. Clipboard now uses it. Automation's side-by-side/drill-in switch has hysteresis. Tests: `testMinimumWindowKeepsTheDetailMinimum` (980 − 236 sidebar = 744 pt), `testInspectorHysteresis`. Screenshots NOT_RUN. |
| D03 Selection/draft/scroll kept on resize | PARTIAL | `ModernGesturesWorkspace.swift:369`, `ClipboardStudioView.swift:394` | Resizing never writes the selection. 20 pt of hysteresis stops panes being rebuilt on every point (`testResizeRoundTripsDontFlapInsideTheBand`: 30 round trips, exactly 60 switches). Automation's drill-in ↔ split switch still rebuilds the list view, so its scroll position isn't kept across that one switch. The 30-resize run with typing in a real window is NOT_RUN. |
| D04 Saved width validation/restore | DONE (code) | `AOMWorkbenchLayout.swift:20`, `AOMTheme.swift:269` | Stored widths are checked when read. The drawn width is clamped, but only a drag writes the stored width, so widening the window brings it back. A drag starts from the displayed width and stops at the window's room. Used by Folder Rules (list and inspector), Clipboard, Automation (list and table) and `AOMListDetail`. Tests: `testStoredWidthIsSanitized`, `testEffectiveWidthShrinks…`, `testDragStartsFromTheDisplayedWidth`. |
| D05 Actionable vs auto-highlighted | DONE (code) | `ModernGesturesWorkspace.swift:369,381`; `ClipboardStudioView.swift:394`; `FolderRulesPageModel.swift` `runPicked` | If a search hides the selected automation or clipboard item, nothing is selected. Before, the first remaining row was selected, so ⌘↩, Return and ⌫ could act on a row the user never picked. Automation bar buttons check that the row is still visible (`actionable`). Folder Rules' Run Selected is disabled on a stale preview. The 7.16.1 guards (`latest(id)`, `liveEntry`, `AOMActionPanelSelection`) are kept. Tests: `testSelectionNeverRetargetsUnderASearch`, `testActionTargetRequiresAVisibleRow`. |
| D06 Duplicate title/status, toolbar | PARTIAL | `AOMComponents.swift:158` | A page header drops a status pill its sentence already says ("Files is on" + "On"), and a subtitle that matches the toolbar's title or subtitle. Test `testHeaderDedup`. Toolbar overflow behaviour (primary action and Search still reachable when items collapse into »): ⌘K and ⌘N still work, but the overflow itself wasn't measured: NOT_RUN. |
| D07 Card nesting / opacity roles | NOT_DONE | — | Needs a per-callsite audit with light/dark/Reduce Transparency screenshots. |
| D08 Compact sidebar | NOT_DONE | — | The spec makes this conditional on a label/accessibility check first. |
| D09 Inspector section/row alignment | PARTIAL | `AOMWorkbenchLayout.swift:175,212` | `AOMInspectorRow` (fixed label column, values on one line) and a folded `AOMInspectorDisclosure` ("Advanced") added. Existing inspectors not migrated yet. |
| D10 Workspace Now | NOT_DONE | — | |
| D11 Workspace rail | NOT_DONE | — | |
| D12 Automation 3-pane | NOT_DONE | — | The step Inspector isn't built. The list/editor now share the width policy (D02/D04). |
| D13 Step summary/reorder | NOT_DONE | — | |
| D14 Dirty/invalid/saved status | NOT_DONE | — | |
| D15 Clipboard typed preview + fixed metadata | PARTIAL | `ClipboardStudioView.swift` `detailPane` | Already in 7.16.1: kind, source, time, contents (size), pinboards; `.id(entry.id)` drops the old preview when the selection changes. New: an empty detail under a search says to pick an item in the results. |
| D16 Pinboard/filter state, lazy image decode | NOT_DONE | — | |
| D17 Audio mixer columns | NOT_DONE | — | The rows already share `AudioRowMetrics`. Table layout not started. |
| D18 Per-app audio Inspector | NOT_DONE | — | |
| D19 Capture command strip vs library | NOT_DONE | — | |
| D20 Capture export Inspector | NOT_DONE | — | |
| D21 Monitor canvas primary | NOT_DONE | — | |
| D22 Restore plan preview | NOT_DONE | — | |
| D23 Menu Bar lanes + item Inspector | NOT_DONE | — | |
| D24 Menu Bar states/flicker | NA (7.16) | `MenuBarControlPage.swift` | Partial states and hysteresis were done in 7.16 (V06/V07). Drag flicker check NOT_RUN. |
| D25 Files locations/info | NOT_DONE | — | |
| D26 ZIP/compare progress | NOT_DONE | — | |
| D27 Folder Rules verdicts / stale preview | PARTIAL | `FolderRulesPageModel.swift:31,435`; `FolderRulesPanes.swift:46`; `FolderRulesPage.swift:38` | The preview records which version of the rule it was made for. An edit that changes the result (folder, match, conditions, actions, subfolders, scan recognition) shows "Out of date" with Refresh and disables Run Selected. The inspector uses the shared width/hysteresis policy. Test `testPreviewFreshness`. Per-condition reasons NOT_DONE. |
| D28 Text Actions split | PARTIAL | `TextActionsPage.swift` via `AOMListDetail` | Gets D02/D04 through `AOMListDetail`. Reorder/preview split not started. |
| D29 System Tools | NOT_DONE | — | |
| D30 Activity metrics vs log | NOT_DONE | — | |
| D31 Settings search → setting | DONE (code) | `SettingsHub.swift:77,951` | Each result group has a "Show in <Category>" link, and each result row has the same item in its context menu. It clears the search, opens the category, scrolls the row to the middle and marks it for 1.6 s. It does nothing while a sheet is open. Dashboard panes (Shortcuts, Permissions, AI) open at the top. Test `testRevealTarget`. Focus on the control itself NOT_DONE. |
| D32 Palette selection/search kept | NA (existing) | `QuickCommandPalette.swift` | Existing behaviour: `returnSelection` and `pendingSelection` restore the selection and query when going back. Disabled-reason display not reviewed. |

## Verification

- macOS CI (`tests.yml`, workflow_dispatch on this branch, `xcode-27` runner): `swift test -j 2`, `./build-and-sign.sh`, codesign verify and DMG. Run 45535629093 (`4fcc38a`), run 45536022197 (`667d1e8`) and run 45541290607 (`4193c58`) all succeeded. Run 45536022197 executed 614 tests: 17 skipped, 0 failures, all 13 `AOMWorkbench2*` tests passed.
- NOT_RUN: the 84-screenshot matrix (13 routes + Settings × 980×600 / 1320×820 / 1600×1000 × light/dark), resize ×30 with draft and scroll, keyboard/VoiceOver/Reduce Motion/Transparency, warm/cold page transitions p50/p95, 15-minute idle CPU/RSS/wakeups. No Mac was attached to this session.
- No release, install or version bump. 7.16.1 is unchanged.
