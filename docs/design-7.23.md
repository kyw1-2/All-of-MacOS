# AOM 7.23: DeepSeek's design reference and the rest of 7.22

- **Base:** `783dfd5` (7.22.0, installed).
- **Branch:** `feat/7.23`.
- **Author:** Claude Code, 2026-11-28.

## Sources

There are two inputs to this version.

1. **DeepSeek's design reference.** The file is in Google Drive at
   `AOM-Reports/2026-11-27/AOM-7.18.0-디자인레퍼런스-명세서-미분석상용앱10종-20261125.md`.
   - It was written by DeepSeek Harness with REA 6.8.0 and Ghidra 12.1.4.
   - It studies 10 apps: Things, Fantastical, Hazel, AppCleaner, DaisyDisk, Transmit, Soulver, Moom, Mimestream and Monodraw.
   - It was written against 7.18.0, so each claim was checked against 7.22 code.
   - Drive also holds the 2026-11-26 folder, which contains the 7.21 report. That report was already applied in 7.22.
2. **The open items of 7.22.** These are listed in `docs/design-7.22.md` §3.

## 1. The report's claims, checked against the code

| § | Claim | Result |
|---|---|---|
| 2.1 | No quick-entry panel (`QuickEntry\|QuickCapture` has 0 hits) | **True.** Built. |
| 2.1 | Default key ⌃⌥Space | **Not taken.** macOS uses ⌃⌥Space to switch input sources, and Korean typing depends on that. The default is ⌃⌥N instead, with ⌥⇧Space and ⌃⌥J offered. |
| 2.2 | No sentence-to-event surface | **True.** Built. |
| 2.3 | Folder Rules has no cloud-only handling | **True** (0 hits). Built. |
| 2.4 | The uninstaller has no drop target | **False.** The tile already accepted a dropped app (`SystemToolDropModifier`); it just didn't say so. The hint and the Full Disk Access warning were added. |
| 2.5 | Nothing to drop on while the shelf is closed | **True**, though shake and Shift already opened the shelf during a drag. A full-screen plane would block drops into every other app, so it was built as an edge trigger instead. |
| 2.6 | Files has a single pane | **True.** Built at the reduced scope the report proposes. |
| 2.7 | No path from selected text to the calculator | **False.** Text Actions already shows `= result` for a selected sum, with copy and ⌥-replace (`TextActionBarItems` `.calculate`). Nothing to add. |
| 2.8 | No sentence saying that checking can't skip macOS's prompt | **True.** Added. |
| 2.9 | Network errors use one generic message | **Partly true.** AI already gave per-status messages; weather, link previews and other URL errors did not. A shared reason enum was added. |
| 2.10 | No symbol picker | **True** (the emoji screen only). Built. |
| 4 | Tokens `x7`, `dropZone`, `monoNumber` | Added. |

## 2. Applied

| Item | What | Where |
|---|---|---|
| 7.22 open, security | Free-text search no longer matches inside a hidden secret, on the shelf, the Clipboard page or the launcher. Metadata and `is:secret` still match. | `ClipboardSearchQuery.matches(contentHidden:)`, `ClipboardPanelState`, `ClipboardStore.filtered`, palette |
| §2.1 | Quick Entry: a panel that doesn't take focus (520 × 132). It saves to a Note, a Reminder or an Event, with ⌘↩ to save and esc to close, and stays open after saving. Calendar write-only and Reminders access are asked on first save only. | `QuickEntryPanel.swift`, `QuickEntryStore.swift`, `GlobalHotKeyManager` (hot key id 2) |
| §2.1 | Shortcut failures in three parts (what, why, what to do), naming the launcher when AOM's own key holds it | `ShortcutClashMessage`, `QuickEntryShortcutSettings` |
| §2.2 | Sentence parser, Korean and English:<br>- days: today, tomorrow, 모레, weekdays, 다음 주, M월 D일, M/D<br>- times: 오전/오후, N시 (반/분), 12:30, 3pm, noon<br>- an unmarked 1–6 o'clock is PM<br>- a time already past moves to tomorrow<br>The launcher row, shown only when the sentence names a time, adds the event (↩) or a reminder (⌘↩). Anything else is searched instead, with no error. | `QuickEntryParser.swift`, `QuickCommandPalette.sentenceItems` |
| §2.3 | A file counts as cloud-only when `SF_DATALESS` is set or iCloud reports it not downloaded. It is then downloaded before rules apply (the default) or left alone. The page notice says how many and which files, with the choice beside it. The preview shows "Cloud-only". | `FolderRulesFileInfo`, `FolderRulesRunner`, `FolderRulesModel.cloudFiles`, `FolderRulesPage` |
| §2.4 | The uninstall tile says "**Drop** an app here". The review says when Full Disk Access is off. Full Disk Access status is read by opening (never reading) TCC.db. | `SystemToolsTiles`, `SystemToolsUninstall`, `PermissionAudit` |
| §2.5 | A file dragged against the left or right edge of a screen, where no other screen continues, opens the shelf there. Off by default. | `FilesEdgeDetector`, `FilesShakeMonitor`, Files › Drop Shelf |
| §2.6 | Two-Pane Browser:<br>- drag copies, ⌘ while dropping moves<br>- a taken name asks Replace (old file to the Trash), Keep Both or Skip<br>- a queue below runs one transfer at a time and gives the reason and Try Again on failure<br>- each side's folder is kept between launches<br>Opened from Files › Tools or ⌘K. | `FilesDualPane.swift`, `FilesDualPaneView.swift` |
| §2.8 | Footnote: "Checking here never skips macOS's own approval window." While access is missing, each row says what fails without it. | `PermissionsSettingsView`, `AOMPermission.failureConsequence` |
| §2.9 | `ConnectFailureReason` covers offline, timeout, clock skew, server not found, refused, auth, rate limit, server error and insecure. Each reason has a title, a meaning and an action, plus a System Settings link where one helps. Used by AI and weather. | `Services/Network/ConnectFailureReason.swift` |
| §2.10 | Symbols screen in ⌘K: 5 categories, searched by English, Unicode and Korean names. The last 18 are kept. | `PaletteSymbols.swift`, route `.symbols` |
| 7.22 open, Meeting | Mixed `meeting.m4a`.<br>SpeechAnalyzer and SpeechTranscriber on macOS 26 and later, with SFSpeechRecognizer as the fallback.<br>"Others 1 / Others 2" from the median pitch of each line, split only when the two groups are at least 35 Hz apart and each has at least 20 % of the lines.<br>Optional "Record without asking". | `MeetingExtras.swift`, `MeetingRecorder`, `MeetingAlerts`, Settings › Capture › Meeting notes |
| 7.22 open, Studio | The camera layer fades out (0.25 s each way) during pauses of 1.388 s or more.<br>Show Pauses marks them on a hatched strip.<br>Add Zoom Range creates the four keyframes of one zoom.<br>Precise ↔ Smooth slider: One Euro filter `minCutoff = 4^(1−2s)`, `beta = 8·2^(1−2s)`. | `AOMStudioTimeline`, `AOMStudioRenderer`, `RecordingExportEditor` |
| 7.22 open, System Tools | Traffic by app, from `nettop -P -L 2 -s 1` (the second sample minus the first), every 3 s while the sheet is open.<br>The storage map colours by folder, kind (8 kinds) or age (week, month, year, older), with a legend. | `AppTraffic`, `AppTrafficList`, `StorageColoring` |
| 7.22 open, Clipboard | The menu bar panel's Clipboard tile says how many items expire within the hour. | `AOMMenuBarPanel` |
| 7.22 open, Scenes | Text appears on screen can watch the whole screen, the front window, or a region picked with the capture selector. Each area has its own watcher. | `ScreenTextArea`, `SystemTriggerKind.screenTextAppearsIn`, `ScreenTextWatcher.bounds` |
| 7.22 open, Typing | Optional automatic fix: a word of 3–24 Latin letters is replaced on Space when all of these hold:<br>- it makes at least two whole Hangul syllables<br>- it isn't an English word (NSSpellChecker)<br>- the input source isn't Korean<br>The input source then switches to Korean. It never runs in secure input, in AOM, or in terminals and editors. | `TypingAutoFix`, Settings › General › Input sources |
| 7.22 open, UI | Rows are 30/38 pt (were 34/44). Only Workspace's header keeps the 28 pt mark. Page archetypes (board, studio, instrument, flow, form) set the width of `AOMPage` and of the Window Tiling page. | `AOMTokens`, `AOMPageHeader`, `AOMPageArchetype` |

## 3. Not done (open)

- **Page archetypes:** the archetype sets column width and header mark only. Each page's own layout was not redrawn per archetype; most pages lay out their own containers.
- **Storage map:** no duplicate-file overlay, which would need content hashing of the scanned tree.
- **Meeting notes:**
  - The voice split is a pitch heuristic, not real diarization; it only splits two clearly different voices.
  - Automatic recording doesn't stop by itself. AOM's own microphone tap keeps "microphone in use" true, so the end of a call can't be seen.
- **Screen-text trigger:** an existing trigger opened in the editor shows the whole-screen default. The editor never loaded system-event values back.
- **Clipboard:** the expiry count is in the menu bar panel, not on the menu bar icon.
- **SpeechAnalyzer:** the code builds against the macOS 27 SDK but has not been run on this Mac.

## 4. Verification

- **Unit tests:** `AllOfMacOSTests/AOM7230Tests.swift` covers:
  - the sentence parser (Seoul calendar, fixed now) and shortcut messages
  - symbols, hidden-secret search, cloud-only detection, the policy decode default, the screen edge and dual-pane planning
  - failure reasons and permission sentences
  - camera opacity, zoom ranges and smoothing
  - the voice split and the pitch of a sine
  - nettop parsing, map colouring, screen-text areas, auto-fix candidates and archetypes
- **CI:** the full suite and the release run on GitHub CI.
- **Not tested:** the runtime features need the real Mac and were not exercised: Quick Entry, the hot key, calendar writes, the two-pane drag, the edge shelf, nettop, the meeting mixdown and SpeechAnalyzer.
