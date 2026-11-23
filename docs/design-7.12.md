# AOM 7.12 — Codex specs of 2026-11-23, HomePod dropouts, log-found bugs

Sources: `~/Documents/Codex/2026-11-23/new-chat/outputs/AOM-7.11-개선-및-신규기능-명세서.md` and
`AOM-상용앱-30종-기능확장-명세서.md` (both on b714f45). UI references: Oracle
`/data/work/rea/aom-ux-20261117/report/03–06` (launcher rows, groups, route headers, split preview)
and the Yoink 3.7.6 bundle there (`x3/Yoink`, strings: Stacks, "One or more files were moved to the
Trash"). Oracle has no Dropover, HoudahSpot, Kaleidoscope or Fantastical analysis; their behaviour
comes from the specs' cited vendor pages.

## Spec → code

| Spec | Done | Where |
|---|---|---|
| FIX-1 ZIP cancel | hidden working file, `ZipArchive.commitExclusive`, cancel between copies | `FilesShelf.swift` `compress` |
| FIX-2 missing files | `requestedItems`; transfer reports; Compress asks "Zip the Other N" | `FilesShelfPanel.swift` |
| NEW-1 named shelves | `FilesShelfLibrary` in shelves.json, migration, header menu, launcher rows | `FilesShelf.swift`, `FilesShelfPanel.swift`, `QuickCommandPalette.swift` |
| UX-1 snippet Previous | `Request.history/drafts`, ⌘[ and a Previous row | `SnippetTemplate.swift`, `+Screens72.swift` |
| NEW-2 PDF rules (text, optional OCR) | `.pdfText`, `{after:}`, `{pdfdate}`, `recognizesScans`, Needs review | `FolderRulesPDFText.swift`, `FolderRulesRunner.swift` |
| 30-app #1 saved search | `PaletteFileQuery`, `PaletteSavedSearches`, `.saveSearch` | `PaletteSavedSearches.swift`, `+Tools712.swift` |
| 30-app #2 clipboard compare | `PaletteTextDiff` (LCS + grapheme span), `.clipboardCompare/.clipboardDiff` | `PaletteTextDiff.swift`, `+Tools712.swift` |
| 30-app #3 free times | `PaletteFreeSlots`, `Event.isFree`, `.availability` | `PaletteFreeSlots.swift`, `+Tools712.swift` |

Previews: `--aom-preview-shelf`, `--aom-preview-launcher --aom-preview-palette-route freeTimes | saveSearch | files:<query> | clipDiff`.

## HomePod dropouts (2026-11-23, 21:28–21:38, Chrome → HomePod, direct path)

- `audio-health.json`: 7 overloads; each a late callback 5–12 ms after the previous (128-frame,
  2.7 ms cycle), detail `memory warn · swap 7.2–7.6 GB · thermal nominal`, load 4.8–15. AOM render
  mean 29.8 µs, max 130 µs.
- `log show`: `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` in **AllOfMacOS only**
  at 21:31:30, 21:33:11, 21:35:53, 21:36:39, 21:37:19 — no coreaudiod line at those seconds.
  AirPlayXPCHelper: `Full TxBuffer Error Count: 0`; kernel LQM VO latency avg 15 ms / max 92 ms.
  (Note for the next diagnosis: in zsh `log` is a builtin — use `/usr/bin/log`.)
- Mac: 8 GB, swap 7.6 / 9 GB, UlanziDeck footprint 2.58 GB (2.27 GB dirty malloc, up 44 h),
  AOM 309 MB footprint with ~287 MB swapped; AOM paged in ~2 pages/s.
- Community/vendor: FineTune (ignore apps that misbehave with taps), CoreAudioTapKit (one aggregate,
  output as clock master, drift-compensated tap — AOM's direct path already is), Rogue Amoeba
  (AirPlay latency ~2 s, dropouts from network or overload), Apple/HN/blog notes on AWDL and
  2.4 GHz congestion. A larger IO buffer was measured ineffective on this HomePod since 3.3.2.
- Changes: wire `__TEXT` + `__DATA_CONST` while a direct stream lives (`AudioRealtimeMemory.retainCode`);
  `AudioGlitchAdvisor` (30-minute summary, top memory apps, Quit and Reopen, hourly burst notice).
- **Not verified**: whether wiring the code removes the late wake-ups. Check after a day with
  `audio-health.json` (`wiredCodeBytes`, overload count per hour under `memory warn`) and the
  `skipping cycle` count in AOM's log.

## Other bugs from AOM's own log (3 h)

Fixed: tccd read twice every 5 s by the sidebar badge (`.task` → `.aomVisibleTask`); listener removal
on dead process objects (11× "no object with given ID"); HomePod balance "100% R"
(`AudioOutputService.currentBalance` ignored statuses and reused `size`); empty-state buttons.

Not fixed (no attribution): one `NSMenu.m:1661` assertion on a background thread at a status-item
click (`NSMenuBarNavigateAction`, AppKit's macOS 27 status-item scene), six SwiftUI "Publishing
changes from within view updates", one `layoutSubtreeIfNeeded` recursion warning. None names AOM
code; they need a run with a debugger or `-com.apple.CoreData`-style runtime-issue breakpoints.

## Not done

- NEW-3 (step-by-step automation test) and NEW-4 (dim background windows during focus): the spec
  itself asks for prototypes on real windows first.
- The 30-app spec's other 27 candidates.
- NEW-1: a shelf colour; shelf rows in the Files page beyond the active one.
- NEW-2: page ranges beyond the first page; a History filter for "Needs review".
- Free Times: working hours are `AOMFreeTimesStart/End` defaults only (no Settings row yet).
