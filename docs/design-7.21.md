# AOM 7.21 — defect sweep + reference-driven design pass

Base: `16241d5` (7.20.0, installed). Branch `feat/7.21`. Claude Code, 2026-11-26.

## 1. Defects (evidence → fix)

Evidence came from the installed 7.20.0 process (22 h uptime): unified log, `sample` (4 s, audio idle),
`Diagnostics/audio-health.json`, and the 162 compiler warnings of the 7.20 release build.

| # | Evidence | Cause | Fix |
|---|---|---|---|
| F1 | CI warnings "mutation of captured var 'buffer'/'errorText' in concurrently-executing code" (`PaletteAI.swift`) | The stderr `Data` was appended on its FileHandle queue and read in `terminationHandler` on another queue (data race); the termination handler dropped stdout not yet delivered (the last line, often the `result` event → "Claude Code didn't answer"). | `AgentPipeReader` (one lock; `finishOutput` keeps an unterminated last line; exit path drains with `drainWithoutWaiting()`), used by the one-shot run and the warm session. |
| F2 | Code read: `PaletteAgentSession.send` writes to the agent's stdin pipe | A write after the agent exited raises SIGPIPE, whose default action terminates AOM. | `F_SETNOSIGPIPE` on the write end (`AgentPipeReader.disableSIGPIPE`); the write now throws EPIPE, already handled. |
| F3 | `top`: AOM 4–6 % CPU idle; `sample`: `AppAudioEngine.startGather` → `AudioControlSnapshot.gather` (HAL IPC), 57 ms mean every 2 s; one silent Terminal tap held to AirPlay, 0 callbacks | The 2 s backstop sweep ran whenever any session existed, even a silent one. | `sweepInterval(hasSessions:playing:)`: 2 s only while a session's app plays (the watchdog judges playing sessions only); otherwise 6 s behind the CoreAudio listeners (process list, default device, devices, per-process IsRunningOutput). |
| F4 | 800 CoreSpotlight "Submitting donation" lines / 30 h from AppKit inside AOM, each pair failing (`CSIndexErrorDomain -1000`), in bursts during use; AOM never calls CoreSpotlight | `AllOfMacOSApp` held `AppState` as `@StateObject`, so every AppState change re-ran the App body and SwiftUI rebuilt the main menu; macOS 27 donates each new menu to Spotlight. | App keeps AppState in `@State` (not observed). `AOMAccentRoot` observes it for the highlight colour; `AOMSearchMenuItem` observes only `AOMPaletteShortcutModel` (republished when the resolved ⌘K changes). |
| F5 | ImageIO "createImageAtIndex … [0 bytes]" errors | Link-preview favicons with an empty 2xx body (and other empty image payloads) reached `CGImageSourceCreateWithData`. | `!data.isEmpty` guards in link metadata, image text, preview/thumbnail caches, clipboard edit, annotation decode. |
| F6 | 49 "Publishing changes from within view updates" faults in a 7.19 process; 77 at the 7.21.0 launch. Fault backtraces symbolicated with `atos`: `AOMSidebar.selection` setter → `AppState.selectedMainTab.setter` → `AOMNavigation.selected.didSet` → `AOMPageActivity.setActive` / `AOMNavigationHistory.record` | The sidebar `List(selection:)` writes its binding during a view update; the setter published four objects inside it. | 7.21.1: the setter applies the page on the next run-loop turn. The snapshot matrix also records SwiftUI runtime issues per page (`runtime-issues.txt`); the 7.21.0 matrix recorded none, since previews don't drive the List selection. |

Checked and left as is: `DispatchQueue.main.sync` sites (all guarded by `Thread.isMainThread` or run off main),
repeating timers (owned and invalidated), force unwraps in gesture geometry (guarded by counts), 7.20 mouse
Back/Forward assist and window-list prefilter (logic correct), gesture statistics migration (consistent with
`StatisticsView`), APFS "volume role" lines (281/day from storage reads, harmless).

## 2. References read (26)

Apple: (1) WWDC25 *Get to know the new design system*, (2) WWDC25 *Build an AppKit app with the new design*,
(3) HIG Layout, (4) HIG Segmented controls, (5) HIG Sidebars, (6) HIG Lists and tables, (7) HIG Color.
Product teams: (8) Linear *A calmer interface for a product in motion* (2026), (9) Linear *How we redesigned
the Linear UI II* (2024), (10) Raycast *A fresh look and feel*, (11) Raycast *Technical deep dive into the new
Raycast* (2026), (12) Raycast List API (accessories vs detail), (13) Raycast Action Panel API, (14) Figma *Our
approach to designing UI3*, (15) Figma *Behind our redesign UI3*, (16) Vercel Geist Colors, (17) Geist
Typography, (18) Vercel Web Interface Guidelines, (19) Geist Empty State.
Mac utility teardowns (via SummonOS *Premium native menu bar apps* and reviews): (20) iStat Menus 7, (21) Stats,
(22) Ice / CodexBar / Itsycal, (23) Bjango *Designing menu bar extras*, (24) Things 3 Quick Entry, (25) CleanShot X
Quick Access, (26) Mimestream and Bartender 5/6 (MacStories Selects, 2026 reviews).

## 3. What the references say that AOM did not do, and what changed

| Principle (sources) | AOM 7.20 | 7.21 |
|---|---|---|
| Selection in segmented controls is a neutral thumb; accent is for the one prominent action; one colour, one meaning (1, 2, 7, 8) | The window-wide `.tint`/`.accentColor` turned every selected segment into a solid accent slab (42 pickers), next to accent primary buttons and accent switches. | `aomSegmented()` = `.segmented` + `tint(nil)` + `accentColor(nil)`; all 42 pickers use it; a test forbids raw `.pickerStyle(.segmented)`. |
| View switching belongs in the toolbar or an inspector, not the main area (4) | Workspace "Now / All Tools" sat in the page header next to Pause. | Moved to the Workspace toolbar (Finder's view-switch place). |
| Supporting controls recede; reveal secondary controls on hover (8, 20: iStat Menus 7 settings show switches and drag handles on hover; 24) | Every automation step showed a switch, a ⋯ button and a drag grip at rest (six steps = 18 controls). | Grip, switch and ⋯ appear on hover / when the step is open or inspected; an off step keeps its switch visible; the card has the same menu on right-click. |
| Don't use visual treatments that haven't earned attention (8, 9, 16) | Sidebar "Off"/"Paused"/"AirPlay" were filled capsules like warnings. | Neutral/success states are plain trailing text; the tinted capsule now means "look here" (warnings, recording, counts to fix). |
| Secondary commands in a quiet "more" control (1, 13) | Workspace tool rows used an accent-blue `chevron.down.circle` beside their switch. | Secondary-colour `ellipsis.circle`, half-strength until hover; context menu unchanged. |
| Keep both ends of links and paths readable (6) | Clipboard titles truncated at the tail ("https://developer.apple.com/design/…"). | Links and files truncate in the middle. |
| No flicker: loading indicators wait 150–300 ms (11, 18) | A Clipboard search showed a spinner for even a one-frame wait. | `AOMDelayedProgress` (200 ms) in the Clipboard page and panel. |

Not adopted (deliberately): Linear's warmer neutral palette (needs a full token pass and light/dark/increase-contrast
review), floating Figma-style panels (Figma itself reverted them for heavy users), hover highlights on every row
(Raycast: desktop rows don't highlight on hover).

## 4. Verification

- `gh workflow run tests.yml --ref feat/7.21` (full suite) and the `[snapshots]` matrix (13 pages × light/dark × 2
  sizes, Settings, launcher, menu bar panel) on GitHub CI; new tests in `AllOfMacOSTests/AOM721Tests.swift`.
- After install: CPU idle check (`top`), CoreSpotlight donation count while switching pages, audio sweep cadence.
