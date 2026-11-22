# AOM 7.5 — Codex 7.4 audit: defects D01–D06 and features F02, F03, F06, F07, F08

Source: Codex's hand-off for Claude Opus (`AOM-Opus-구현-프롬프트.txt`, 2026-11-22, base `42df460` = 7.4.0). It listed six defects reproduced
on synthetic data and twelve features ordered by everyday use. 7.5 fixes all six defects and adds five of the features the user picked
(F02, F03, F06, F07, F08). F01, F04, F05 and F09–F12 are still open.

## Defects

| # | Codex finding | Fix | Regression test (AOM75Tests) |
|---|---|---|---|
| D01 | A copy replaced after the duplicate scan went to the Trash; the review kept only paths | The scan keeps each copy's fingerprint (device:inode, size, mtime, read before and after hashing) and the set's SHA-256 (`FileTools.DuplicateSet`). Move to Trash re-checks every checked copy and the copies that stay (`planDuplicateTrash`); a changed set is held back whole with its reason and a Scan Again button; a set with every copy checked keeps its first copy | `testD01…` (4) |
| D02 | A failed Airplane Mode restore erased the record; the retry turned on a radio that had been off | The record (`AOMAirplaneMode.v1`, same JSON) keeps the radios that haven't come back; each radio is read back (≤ 3 s) before it counts; runs on a serial background queue; HUD, log and result use one `AirplaneOutcome` ("Wi-Fi Still Off") | `testD02…` (3) |
| D03 | One window's failed URL read shifted the next window's tabs (titles pushed before URLs) | The JXA reads a window's titles, URLs and ids, then pushes one record; a failed window is counted and reported beside the tabs that were read | `testD03…` (runs the generated JXA in JavaScriptCore) |
| D04 | Show Tab used the position from the scan, so a reordered window showed another tab | Show Tab reads the browser again and resolves the pick: by tab id (Chromium, Arc), or by an address that picks out one tab (Safari: URL, then title, window id, position). The script looks the id up when it runs. Closed and ambiguous tabs are reported | `testD04…` (3) |
| D05 | An alert already shown blocked the next meeting (only `next` was checked) | `dueAlert` picks the alert separately from the menu bar's `next`: not shown yet or snooze ended, earliest then by key; an open alert closes when its event ends or a fresh read no longer has it, and the next one shows | `testD05…` (2) |
| D06 | Alerts loaded "today" into My Schedule's shared cache: 00:02 was invisible at 23:50 and the week was replaced | Meeting Alerts reads its own range (now − 12 h … now + 2 h) through `PaletteSchedule.events(from:to:)`, uncut by the 500-row list limit, refreshed every 5 min and on `EKEventStoreChanged`. My Schedule keeps its week | `testD06…` |

## Features

- **F02 snippet choices and optional sections** (TextExpander): `{choice:Name|A|*B}` (`*` marks the default, else the first) and
  `{optional:Name}` … `{/optional}` (`|off` to start left out). One question per name across `{arg}`, choices and sections; a name
  used as two kinds is a template error. A section tag alone on its line takes the line with it, so a left-out signature leaves no
  empty line. Fields inside a left-out section are skipped. The launcher form shows choices and Include / Leave Out as rows, default
  first; typing narrows them. The same renderer serves the launcher and typed abbreviations; snippets saved before 7.3 stay literal.
- **F03 Extract from ZIP** (BetterZip): AOM's own central-directory reader (Stored, Deflate via Compression, ZIP64, Info-ZIP UTF-8
  names, UTF-8 / CP949 / CP437), so two `report.pdf` in different folders are two entries. Search, pick, keep or drop the archive's
  folders, extract into a chosen folder. Each file is inflated into a hidden temporary file, checked (CRC-32, size), and renamed with
  `RENAME_EXCL` to a free name. `..` paths, encrypted entries, links and other methods are listed with the reason and never written;
  a folder already in the destination that links elsewhere is not written through. AppleDouble (`__MACOSX/`, `._name` beside
  `name`) is hidden. Entry: Files › Tools › Extract from ZIP…, Drop Shelf (row menu and More menu), launcher command and `.zip` rows.
- **F06 storage map** (DaisyDisk): Free Up Space › Folder Sizes now measures the folder once and shows a keyboard list and a
  squarified map of the same items and sizes; click (or ↩ / →) goes in, the path bar, ← or ⌘↑ comes out, Show in Finder. Each
  folder keeps its 120 largest items; the rest are one "N smaller items" entry. Hard links count once (name order decides which path),
  links and other volumes aren't entered, a folder that couldn't be read is marked, not shown as 0 bytes. 10,000 files: 0.13–0.24 s.
- **F07 Compare PDFs** (PDF Expert): two PDFKit panes with file name and "Page n of N", Link Pages (⌘L: the other side goes to the
  same page number, or says it has no such page), Swap Sides (⇧⌘S) keeping each document's page, a password field on the locked side
  only. Read only. Entry: Files › Tools › PDF › Compare Two PDFs…, Drop Shelf with two PDFs, launcher command and `.pdf` rows.
- **F08 Compare Folders** (ForkLift Sync): both trees by relative path, matched without case unless both volumes are case-sensitive,
  in composed Unicode. Same-size files are compared byte by byte (equal size and date is not taken as equal). Rows: only left, only
  right, contents differ, same, couldn't compare (unreadable, folder vs file, names that differ only in case, another volume). Copy
  Missing copies only what the other side lacks, in the chosen direction: source fingerprint re-checked, destination checked free,
  copied to a hidden name and renamed with `RENAME_EXCL`; a failed copy leaves no partial file; copied rows become Same and aren't
  offered again. Links are compared by target and not copied. Entry: Files › Tools, Drop Shelf with two folders, launcher command and
  folder rows.

The launcher commands carry ids `files.tool.*`, so they leave the search while the Files module is off.

## Gemini review (Gemini 4 Neon, thinking High, AI Studio, 2026-11-22)

The whole diff went to the user's AI Studio prompt. Each point was checked against the code.

Applied (each with a test in `AOM75Tests.testReview…` where it can be tested):
- PDF panes: setting the document reported page 1 late and reset both sides after Swap Sides; moves the model asks for are now held
  until the next run-loop turn, a pane is rebuilt per document, and its password field clears when the document changes.
- ZIP: the old `FileHandle.write(_:)` raises an exception on a full disk (now `write(contentsOf:)`); a link already in the destination
  is refused even when it points inside it; the inside check runs before the rename; 64-bit sizes over `Int64.max` are a damaged
  archive instead of a trap; OS X (host 19) links are detected; the file is closed before it is renamed; progress is throttled.
- Browser Tabs: the closed/ambiguous messages no longer claim the list was read again; Safari's script finds the window by id and
  checks the address at the position before showing it.
- Compare Folders: a folder on another volume that exists on one side only is not counted or copied; `/` counts as holding every
  folder; copied rows show the copy on the other side; the folder buttons are disabled while comparing or copying; closing the window
  stops the work.
- Storage map: a sliver left by rounding no longer makes infinite frames; Stop is checked every 512 items in a large folder; closing
  the sheet stops the measurement; double-click and a context menu use `contextMenu(forSelectionType:primaryAction:)`.
- Airplane Mode: only radios that are on are switched, so a radio already off neither counts as turned off nor adds an error; Toggle
  is decided on the radio queue, so two quick presses don't both turn it on.
- Meeting Alerts: a calendar change during a read triggers another read when it ends.
- Snippets: CRLF line breaks count for section lines; a field in two sections is skipped only when both are left out; a template that
  uses sections and doesn't end with a line break comes out without one (no Return typed in a chat field); Include / Leave Out accept
  yes/no, on/off, 포함/제외 and never show an empty list.
- Drop Shelf: folders with a dot in the name ("Release 7.5") offer Compare the Two Folders (packages are what's left out).
- Tool windows keep their saved position; opening a ZIP that is open brings its window forward.

Ideas taken: offset linking in Compare PDFs (Link Pages keeps the distance the pages had when it was turned on), a "same text / text
differs" badge for the two pages shown, Quick Look of one ZIP entry before extracting (extracted alone into a temporary folder, removed
when the window closes), a Compare Folders row menu (Compare the Two PDFs, Show Both in Finder, Copy Path; double-click opens), and the
storage map's row menu.

Disproved:
- "Move to Trash ignores the checkboxes changed in the sheet" (marked critical): `CleanupReviewContent.trash()` copies the review with
  the sheet's selection before calling `onTrash`, so `review.selected` is the user's final choice.
- "`remaining` traps when the form is complete": `fields[fields.count...]` is an empty slice in Swift; the index never passes the count.
- "`duplicateCandidates(sets)` loses the creation date": the rows' notes use only the position in the set; the order was fixed when
  the sets were made.

Not taken: copying a missing folder copies it whole (its `.DS_Store` and links as links, as Finder does); ⌫ to go back a question in
the snippet form needs the launcher's key routing and is left for later.

## Preview

`--aom-preview-file-tool zip:<path> | pdfs:<a>|<b> | folders:<a>|<b> | storageMap:<path>` opens one tool in a UI preview
(with `--aom-preview-snapshot`).

## Not verified on the device

Real Trash moves after a scan, real radios, Show Tab in each browser, alerts across midnight with a real calendar, the snippet form
from a typed abbreviation with the Korean input method, and PDFKit's page drawing (the snapshot renderer doesn't draw PDFView pages).
