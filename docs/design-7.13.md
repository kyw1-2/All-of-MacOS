# AOM 7.13 — review of the 7.12.1 analyses (GPT spec, Gemini report)

Sources, 2026-11-24:
- GPT: `~/Downloads/AOM-7.12.1-통합개선명세서-2026-11-24.md` (F01–F22, UX-01–29, CLEAN-01–40, UX3-01–30, NEW-01–15).
- Gemini: Google Doc "AOM 7.12.1 소스 정밀 감사·최적화·상용앱 기능 확장 종합 분석 보고서 (Gemini)" (GEM-BUG-01–18, A–D cleanup grades, 16 features).

Every claim below was checked against the code at `f88517c` before acting. Gemini said itself it had no clone and worked from older Drive copies; most of its menu bar and Files claims describe code that 7.10–7.12 already changed.

## Done

| ID | Where | What |
|---|---|---|
| CLEAN-01–06 | MenuBarItemEditor, AudioRecovery, AOMAIRecordScope, AppState, AOMTokens, AOMTheme/SettingsHub | Dead declarations with zero references removed (`MenuBarItemRow`, `checkHomePodLoadOnly`, `attachesClipboard`, `triggerSearch`, `pageBackground`, the unused `elevated` parameter). |
| F01 | AudioRealtimeMemory, AirPlayOutputRenderer | `wiredCodeBytes` counts only `mlock`ed `__DATA_CONST`; the page-touched `__TEXT` is `touchedCodeBytes` in audio-health.json. |
| F02 | AudioRealtimeMemory, AirPlayDirectStream | `retainCode()` returns whether it took a reference; only then does the stream release. |
| F04 | Tools712 | The route keeps left/right; the older copy goes left once, when the screen opens. Swap Sides swaps. Rows say "left (−)/right (+)". |
| F05 | PaletteTextDiff | Common leading/trailing lines are taken off before the LCS; a middle over the 4M-cell cap uses Swift's Myers `difference(from:)` instead of "everything removed and added". The result is memoized for the open screen (rows rebuild on every key). |
| F06 | PaletteTextDiff | The trailing-newline marker line ends in "\n", which no split line can contain; CRLF reads as LF. |
| F07 | Tools712 | A failed calendar read (`events` → nil) is `readFailed`, shown as its own row; Copy re-reads and refuses on failure. |
| F08 | PaletteFreeSlots | `stillFree(now:)` drops a time that has started. |
| F09 | Tools712 | Working hours clamped to the day (start ≤ 23:30, end ≤ 24:00, ≥ 30 min apart). |
| F10 | FolderRulesPDFText, FolderRulesModule | PDF text cache: 64 pages, 4 MB, 10 min; cleared when Folder Rules stops. Comment corrected (memory, never disk or log). |
| F11 | FolderRulesFileInfo (`seen(by:)`), Matching, Runner, Executor | One read serves all rules, but a rule without Recognize Scans sees a recognized page as "no text". |
| F17 | FilesShelfPanel | Show/hide generation: a fade-out completing after a re-show no longer orders the shelf out; a re-show restores alpha. |
| F18 / GEM-14 | FilesShelfPanel | Delete Shelf and Remove report Trash failures (danger tone, named file) instead of a plain success. |
| GEM-03 | AOMMenuBarNative.m | Completion runs once; no answer in 5 s fails open; a late or second assertion is invalidated. |
| GEM-11 | FilesShelfPanel | ⌘Z takes the undo closure before running it (the old guard already prevented a double run; this matches the button). |
| GEM-13 | FilesShelfPanel | Promised files: one shared queue (4 at a time); after 120 s "Receiving…" is cleared with a message, later files are still added. |
| GEM-10 | MenuBarSettingsPanes | The panes' defaults observer is debounced (150 ms). |
| UX3-05 | WindowSwitcherOverlay | Selection follows the window id across item changes. |
| UX3-11 | FilesDialogHelper | Finder windows and recents publish independently. |
| UX3-14 | FilesDialogPanel | Re-attach during the fade-out restores alpha (was: on screen, invisible). |
| UX-06 | Tools712 | Diff header counts changed/added/removed. |
| UX-07 | Tools712, ShortcutsSettingsView | Settings › Shortcuts › Free times (working hours); a summary row at the end of the list (length, hours, last read, ↩ reads again). |
| Timers | MenuBarHider, MenuBarNativeHiding, PaletteRoutes, ClipboardStore, AOMMenuBarPanel, MenuBarSetupGuide | Tolerance on the 7 repeating timers that had none (the other 19 already had it). |

Tests: `AllOfMacOSTests/AOM713Tests.swift`.

## Disproved (no change)

- GEM-01: `handleClockClick` already bumps `generation` before releasing.
- GEM-04: `menuIsOpen` already converts each display's menu bar into window-list coordinates (7.10).
- GEM-07: `applyWideRule` also runs on `didActivateApplicationNotification`.
- GEM-08: the hit test runs on one serial queue and the hover path re-checks the pointer when the answer arrives.
- GEM-12: Compress already writes a hidden partial file and commits with `commitExclusive`.
- GEM-16: `copyTree` uses `try`, not `try?`; a failed read throws.
- "100 Hz timer in production" (AllOfMacOSApp:58): runs only under `--aom-check-xpc`.
- UX3-23 "1 s refresh while hidden": `AOMStatusPanelController.close()` drops the hosting view, which stops the timer.

## Not done, and why

- GEM-02 (lift timer after a failed activate): on failure everything is already visible; the timer re-tries the hide after the delay, which is the fail-open recovery. Kept.
- GEM-05 (scroll trigger over icons): Bartender's scroll trigger works anywhere on the bar; kept as designed.
- GEM-06 (`MenuBarAppMenus.maxX` AX on main): cached 5 s, 0.25 s per request; moving it off main changes reveal timing. Needs measurement first.
- GEM-15 (`exists` in shelf rows): a stat per visible row; matters only for network volumes. Open.
- GEM-17/18 (glitch marker on main, resume interval): need the audio engine's queue audit; not touched next to the HomePod change.
- F03 (page-touch effect): unverified either way; kept on (`AOMAudioWireCode`).
- F12 (Edit Conditions): replacing by name already keeps the UUID; a dedicated edit route is a UX change for later.
- CLEAN-07–18 (`#if AOM_INTERNAL_TOOLS`): the preview/bench/self-test paths are inert unless their flags are passed and the screenshot workflow and CI rely on them in the same binary. No runtime gain; not moved.
- CLEAN-19–40, God-file splits, AOMEventHub: refactors with regression risk and no measured benefit yet.
- NEW-01–15, Gemini's 16 features (Visual Focus / HazeOver, conflict palette, step debugger, device priority …): new features, not part of this cleanup release.
