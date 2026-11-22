# AOM 7.6 — Codex 7.5 audit: defects, security, menu bar features, audio glitch marks

Source: Codex's hand-off `AOM-7.5-메뉴바-오디오-검수-Opus.txt` and its orphan ledger `AOM-7.5-정적분석-목록.txt` (2026-11-22, base
`73b63d3` = 7.5.0). Each item was checked against the code before it was changed.

## Defects and security (all reproduced in the code)

| ID | Fix | Test (AOM76Tests) |
|---|---|---|
| DT01 | Duplicates go set by set: each set is checked, then its copies move at once, every copy and the copy that stays read again just before its move (`FileTools.trashDuplicates`) | `testDT01…` |
| DT02 | The result counts moved, kept, failed and held apart; it is a success only with nothing failed or held | `testDT02…` |
| FC01 | A missing folder is copied only if its tree signature (identity, files, bytes, newest change) is unchanged; a file with no fingerprint is never copied | `testFC01…` (2) |
| FC02 | Folders are copied file by file into a hidden folder, Stop checked before each item, links as links, other volumes not entered; nothing is left on Stop | `testFC02…` |
| FC03 | Listed but unreadable details, and link targets that can't be read, are "Couldn't Compare" instead of missing or same | — |
| FC04 | The matching key and the shown path travel apart, so rows keep the folders' own spelling | `testFC04…` |
| Z01 | Totals and header offsets use overflow-reporting arithmetic; a sum past `Int64` stops before anything is written | `testZ01…` |
| Z02 | The central directory is read in one piece only up to 256 MB; extraction checks the picked total against the job budget and the free space (minus a margin); Quick Look has its own 512 MB budget | `testZ02…` |
| Z03 | The folder a file goes into is checked again (device, inode, type, inside the destination) right before the rename | — |
| Z04 | Quick Look requests carry a generation; each unpacks into its own folder; a late or closed one is removed; day-old preview folders are swept | — |
| SM01 | The storage map keeps a folder's largest items while it reads (cut back whenever the list doubles), totals cover everything, unreadable sizes are counted and shown | `testSM01…` |
| F07a | Linked, the text badge says "No matching page" when one side has no page to compare; unlinked it says it compares the two pages on screen | `testF07a…` |
| MB01 | Shelf rows are per scan (`app|#ordinal`); a pin remembers the identifier when it names one item, else the place — never the title. Duplicates are two rows. Pressing reads the app again and presses only a sure single match. Old pins move over when they name one item | `testMB01…` |
| MB02 | The deadline is checked before every item; a partial scan says how many apps didn't answer; pins stay | — |
| MB03 | The scan generation is bumped before the permission check; a late result checks permission again before it shows | — |
| MB04 | The Hider's delayed start collapse is a cancellable work item; the chevron's picture and VoiceOver label come from the real state | — |
| MB05 | Menu bar spacing writes both keys through CFPreferences, reads them back and restores both previous values (present or absent) if either didn't take; the menu bar restart is reported apart | `testMB05…` |
| BT01 | Safari tabs without ids are chosen only when address, title and window leave one; the script also needs one matching address | `testBT01…` |
| CA01 | Calendar access withdrawn: the countdown, an open alert and the events read are cleared, and a read in flight can't bring them back | — |
| MW01 | Memory Watch decides which alerts may post before reading the app list, and posts nothing after Stop | — |
| SEC01 | The MCP setup token is not on screen as selectable text; Copy with Token writes it marked concealed and transient and clears it after 90 s only if nothing else was copied | `testSEC01…` |
| SEC04 | `aom://trigger` links ask Run Once / Always Allow / Don't Run; Always Allow is stored by trigger UUID; "Forget Link Permissions" in the launcher resets | `testSEC04…` |

Not changed this round: SEC02 (MCP request re-check), SEC03 (XPC requirement on the connection), SEC05/EXT01 (share extension
hand-off), CI01 (pin actions by SHA) — design work for a later version; Codex observed no exploit for any of them.

## Features

- **W01 Menu Bar Weather** (Settings › General › Modules, off until turned on): one city chosen by name (Open-Meteo geocoding, only
  the typed name is sent), "☁ 6°" with Temperature / Feels Like / Icon Only and °C/°F; the menu has city, actual and feels-like,
  today's low/high and rain chance, the time of the reading and the Open-Meteo credit. 30-minute cache, one request at a time, a
  reply for a city changed since is dropped, 429 waits for Retry-After, waking refreshes only a stale reading. No permission is used.
- **M08 Menu Bar Strip** (launcher, the menu's More, an action you can bind): every menu bar item AOM can read, in one row under the
  menu bar of the pointer's display; items behind the notch, pushed off by the Hider, or without a position come first. ← → ↩ esc,
  keys taken at the panel. App icons and item names, no Screen Recording; nothing is moved.
- **M04 Always-hidden section**: right-click the Hider's chevron › Always-Hidden Section adds a fainter second divider; items left of
  it stay hidden when the chevron shows the rest, ⌥-click shows everything. The section is used only while the dividers are in order,
  and if it ever pushed the chevron off the display AOM turns it off and says so.
- **AUD-01 instrumentation** (direct AirPlay IOProc, atomics only): callback entry intervals in eight bins (× the cycle), late
  callbacks (> 1.5 cycles), slow cycles (work longer than the cycle), short and missing tap input, and for each output gap its cause —
  late callback, app's audio came short, or output clock jumped — as a `gapCause` event. In `audio-health.json` under each direct
  session.
- **M12 I Just Heard a Glitch** (status menu while App Audio runs, launcher, action): marks the moment; ten seconds later it saves the
  events from ten seconds before to ten after, the routes (app, direct or queued, AirPlay) with their counters and the system load to
  `Diagnostics/audio-marks/<time>.json`, and says what it found ("1 output gap (1 late callback) within ±10 s" or that AOM saw none).
  Playback is never touched; no audio, titles, network names or serials are kept.

The cause of the user's 11:53/12:00/12:15 crackles stays open: the new counters and marks are what the next occurrence needs.
Listening was not verified.

## Gemini review (Gemini 4 Neon, thinking High; a new AI Studio chat, ~50k tokens sent)

Applied after checking each point in the code (tests `AOM76Tests.testReview…` where testable):
- Folder copies are recursive by name: an unreadable folder fails the whole copy (it was skipped silently), no path-prefix arithmetic,
  folder dates kept. The tree signature folds every path, kind, size, date and link target, so renames and empty folders count, and
  it skips other volumes like the copy.
- The Menu Bar Strip closes when it loses focus (clicking elsewhere), orders apps like the shelf, checks Accessibility again before
  showing a scan, reads app icons once per scan, leaves out AOM's own Hider dividers, and opens the first nine with 1–9.
- Turning the always-hidden section on shows both dividers and holds them open so the new one can be ⌘-dragged; the collapsed second
  divider drops its icon; the off-screen check is a cancellable work item that re-checks the state and judges the chevron on its own
  display and against the notch; showing all cancels the start collapse; "Keep Open Until I Click" joins the chevron's menu.
- Weather: a cancelled request (city or unit changed) no longer clears the new request's slot; a city chosen during a 429 wait
  shows at once.
- Link consent: Return means Don't Run (Run Once and Always Allow have no key); a second link while one asks is ignored with a HUD;
  the checked trigger's actions run, not a name looked up again.
- The IO thread's interval bin is literal comparisons (a static array's first read takes a lock and allocates); slow-cycle counting
  needs a known cycle length.
- The shelf presses a lone match of a non-unique identifier never (its twin closed); an app read in part vouches for no identifier;
  rows carry the pid. The strip's failure HUD names the strip.
- ZIP: a destination folder identity that can't be read fails the check (nil equalled nil); Quick Look unpacking has its own Stop and
  never recreates a removed preview folder.
- Duplicates: only copies that passed the full check (hash included) vouch for a set during the move.
- Safari: the script narrows the same address by title, as the Swift check does.
- Glitch marks also save the routes and load ten seconds after, report a save that failed, keep the newest 50, and "Reveal Last
  Glitch Mark" opens the newest.

Ideas taken: next-6-hours line from the same weather request, three recent cities, 1–9 in the strip, Keep Open Until I Click,
after-snapshot and Reveal Last Glitch Mark.

Disproved: "slowCycles counts every cycle when the rate is 0" — the stream's init rejects rates outside 8–384 kHz, so a live stream
always has a cycle length (a guard was added anyway); "ticksPerFrame goes stale after a rate change" — a rate change sets
`reconfigured` and the engine builds a new stream; "markRoutes races" — sessions change on the main thread, where it runs.

## Removed (Codex orphan ledger, callers checked)

`PaletteAppControl.forceQuit(_:name:)` (the launcher uses `confirmForceQuit`), `AppState.addActivationGroup(_:)` (the
`name:` overload stays), and the manual `moveTrigger` / `canMoveTrigger` chain in `AppState` and `Preset` (`movePeers` stays for
`addTrigger`). The rest of the 453-row ledger is untouched.
