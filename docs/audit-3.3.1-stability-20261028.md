# 3.3.1 — stability audit remediation (2026-10-28)

The 2026-10-28 audit of 3.3.0 (`e83fb23`) concluded: the installed app matched the
release, but the stability audit did **not** pass. 3.3.1 fixes the twelve findings below
(numbered as in the audit report) and adds regression tests that reproduce each defect.
Evidence, probes and logs are in `work/audit-20261028/` on the build Mac (not tracked in
git).

**Status: not a full stability pass.** Every code-level finding is fixed and tested, but
the hardware checks (real trackpad gestures, AirPlay listening, a 65-minute recording, a
real "Save changes?" sheet) need a person and were not run. See
[Not run](#not-run-needs-a-person).

## Findings, causes and fixes

| ID | Finding | Root cause | Fix | Regression tests |
|---|---|---|---|---|
| F01 | Dock pinch force-quit apps | `quitApplication` called `terminate()` and, 1.5 s later, `forceTerminate()`, killing apps that were showing "Save changes?" | `TrackpadUtilityGestures.politeQuit` only asks; the HUD explains and points to Force Quit (a separate, confirmed action) | `AutomationGateTests.testDockQuit*`, source guard `testNoCodePathForceTerminatesAnApplication` |
| F02 | A closing MCP client could terminate AOM | No `SO_NOSIGPIPE`; a write after the bridge exited raised SIGPIPE (default action: exit; probe exit 141) | `SO_NOSIGPIPE` on server connections and the stdio bridge; EPIPE closes one connection; when the app closes the connection the bridge answers every request it forwarded and never got a reply to with a JSON-RPC error before it exits (after a failed write, every later request too) | `MCPConnectionTests.testClosingThePeerAtAnyMomentNeverRaisesSIGPIPE` (after auth, before a reply, mid-reply; 8 rounds), `testWritingAfterThePeerClosed…`, `…StdioBridgeSocket…`, `testTheBridgeKnowsWhichForwardedRequestsWereNeverAnswered` |
| F03 | MCP replies were cut short | `accept()` inherits `O_NONBLOCK`; `send` stopped at the first `EAGAIN` (4,096 of 1,000,015 bytes, no newline). EAGAIN on read closed the connection; invalid UTF-8 and method-less requests got no reply | Per-connection outbox drained by a write source, bounded at 64 MB and by a 30 s no-progress deadline that closes only that connection; EAGAIN/EINTR handled; JSON-RPC −32700/−32600 replies | `MCPConnectionTests` (1 MB over a 4 KB buffer; two 700 KB replies to a reader that stops 1.5 s and resumes, whole and in order; the stalled connection closed at its deadline while another keeps working; invalid requests answered) |
| F04 | Pausing AOM did not pause gestures | Space swipe, Dock pinch and title-bar snap read neither `AOMGlobalEnabled` nor `TriggerSuppression`; the trackpad stream stayed on while paused | `AutomationGate` (master switch + suppression rules) used by every monitor and both gesture layers, checked per frame, so a gesture paused half-way fires nothing; paused AOM releases the trackpad stream | `AutomationGateTests`: Space swipe, Dock pinch and registered trackpad gestures fire 0 times while off, paused, or paused mid-gesture; `TitleBarSnapTests.testTheSnapGateClosesWhenAOMIsOffOrPaused` |
| F05 | Title-bar snap hold and cancel | The service refreshed its 1.2 s timer only on a zone change, so a held preview disappeared and the later lift applied nothing; a third finger committed; the service's cancel did not reset the recognizer | Activity is measured in contact frames: a held stroke reports itself every 0.25 s and the lift applies it however long it was held; only a lift commits; a third finger, a 0.25 s frame gap (sleep/wake) or the service's own cancel ends the gesture in both service and recognizer until the fingers lift; one gesture per trackpad; reacts to the permission watchdog and to sleep | `TitleBarSnapTests` (3 s hold then lift commits; 2→3 fingers; reset when switched off; a service cancel; frames resuming after sleep; a second trackpad) |
| F06 | The editable pointer stopped at 50 minutes | 60,000-point cap at 20 Hz, samples dropped silently; 8 MB sidecar cap reported as a full disk; periodic sidecar encoded on the main thread | `AOMCursorSampler` halves density instead of stopping; 24 MB sidecar bound with a real error; periodic writes off main; Studio project bound 40 MB | `LongRecordingAndArchiveTests` (65 min, 4 h, hidden intervals, flicker) |
| F07 | Backups missed new settings; restore was not wired | 3.x snap, gesture and capture settings missing from the list; one `settings_backup.plist` rewritten by every save; `restoreUserDefaultsFromBackup()` had no caller; every `*.json` in a custom folder was listed, restored at launch and pruned | Each backup carries its own `.settings.plist` (format 2: values, the settings that were still unset, complete per-app families, the version that made it), so a restore puts back exactly the settings of that moment. Scope: gestures and their timing, title-bar snap, key remapping, pausing rules, shortcuts, capture, text capture, recording, clipboard, audio, appearance; every other AOM setting is listed with its reason (this Mac's folders, the backup options, the pause switch, AI tool and screen-reading access, runtime state, layout, statistics). Settings › Backups states the scope and previews what a restore changes. A restore reads everything first, keeps the current automations and settings as a `-before-restore` snapshot (nothing changes if that fails; the chosen backup is never pruned to make room) and writes no rolling backup of its own | `ProfileBackupRestoreTests` (empty profile round-trip; an older backup's own settings; restoring the oldest of a full set and the oldest of five snapshots; unset settings and per-app families restored faithfully; the pause switch untouched; unreadable settings; a snapshot that cannot be written; the preview; foreign files; failed import/export), `BackupScopeTests` (scans the sources: every settings key is backed up or excluded with a reason) |
| F08 | Clipboard storage errors looked like an empty history | `ClipboardStudioView` showed "Your Clipboard Is Empty" whenever nothing was listed, whatever `storageStatus` said; the fixes lived only in Clipboard Settings | `ClipboardEmptyContent`: a locked Keychain and an unreadable archive each get their own title and text, before "empty", with Try Again / Recover Storage on the same screen; a banner when new copies are listed but not saved; the ⇧⌘V shelf uses the same texts | `TruthfulToolStatusTests.testStorageFailuresAreNeverShownAsAnEmptyHistory` |
| F09 | System tools announced success after failing | Flush DNS ignored the exit status of `dscacheutil`/`killall`; Empty Trash dropped every per-item error (`try?`) | Every step's exit status and standard error are checked. AOM runs as the user, so `killall -HUP mDNSResponder` answers "No matching processes belonging to you were found" (exit 1, even for an administrator account); that, or a permission error, offers the administrator prompt instead of "flushed". Empty Trash returns deleted/failed counts with reasons and asks for Full Disk Access when it cannot read the Trash | `TruthfulToolStatusTests` (a failing stand-in command; the real unprivileged `killall -s` answer, which sends no signal; a locked file in a temporary "Trash"; an unreadable folder) |
| F10 | Desktop Icons' first toggle did nothing | `bool(forKey:) ?? true` never reaches the default: UserDefaults answers false for a missing `CreateDesktop`, so the first toggle wrote "show" | A missing key means Finder's default (icons shown); the write is checked; the same fix for Hidden Files | `TruthfulToolStatusTests.testTheFirstDesktopIconsToggleHidesTheIconsOnADefaultMac` (missing, true, false, "NO") |
| F11 | Update module and release wording | `UpdateChecker` claimed `.upToDate` without checking and parsed `aom-v3.3.0-…` as 3.0.0; docs called the (now public) repository private; public notes named other apps | Policy below; truthful `UpdateChecker` (`.notChecked`/`.disabled`, real tag and build parsing); README/workflow wording; release notes describe AOM's behaviour without naming other apps; Window Tiling switches moved above the preview; System Tools' one-tool Network section merged; small text-size and contrast fixes | `UpdateCheckerTests` (published tag formats and policy) |
| F12 | `testRealtimeAirPlayMixClockKeepsTheBridgeFed` failed repeatedly | The test process's realtime thread was demoted by the host (timeshare, priority 4, wake-ups ~120–200 ms late) and 3.3.0 caught up at most four blocks per wake-up | The mix thread measures its start-up and every wake-up and reads back how macOS really schedules it; catch-up is time-budgeted only while it really runs realtime. Thresholds unchanged | `AirPlayMixScheduleTests`, `testRealtimeAirPlayMixClockKeepsTheBridgeFed`, `testAirPlayMixClockSustains48kHzAfterWarmUp`; see below |

Also fixed while working on the list (not separate audit findings): actions that send keys,
clicks or scrolls report failure without the post-event permission, and window batches,
Dark Mode, input device, force quit and copy actions report what really happened
(`HonestOutcomeTests`); an unreadable Capture History manifest or recording journal is kept
under a new name instead of being overwritten, Capture History is rebuilt from its images
(kept pinned, since pins were in the lost manifest), and recording outcomes are logged to
`Diagnostics/recording-events.jsonl` (`LongRecordingAndArchiveTests`). Outcome messages
that carry a reason or an instruction (an app still open after a Dock pinch, a recording
stopped early, an import) are shown in full in a larger HUD for up to 8 s; until now about
25 characters were visible for 1.1 s. A restore that needs a relaunch says so in an alert.

### F12: start-up, sustained supply, test and production, separately

Measured on the build Mac (M1, macOS 27.2); probes and logs in `work/audit-20261028/` and
`work/audit-20261028/s3/`.

- **The mix thread measures itself.** `AirPlayMixThread.timeline` (`AirPlayMixTimeline`)
  stamps `start()`, the thread running and the first block, and keeps the last 256
  wake-ups (lateness, blocks rendered, burst time, how far behind the burst left the clock,
  how the scheduler ran the thread). `sustainedRate` measures the supply at burst ends after
  a warm-up, so it does not depend on when anyone looks. Audio diagnostics
  (`audio-health.json`) carry the same figures (`mixThreadStartMS`, `mixFirstBlockMS`,
  `mixRealtimeEffective`, `mixSchedulingPriority`, `mixLateWakes`, `mixBudgetLimitedWakes`,
  `mixSustainedFramesPerSecond`, `mixWorstLagAfterWakeMS`), and the app log says when macOS
  runs the clock outside the realtime band and when it is realtime again.
- **Start-up is not the problem.** In every condition below `start()` reached the running
  thread in ≤ 0.35 ms and the first block in ≤ 5.8 ms.
- **The cause: the host demoted the thread.** `thread_policy_set` accepted the
  time-constraint request, but the scheduler ran the thread timeshare at priority 4 (the
  process's maximum, `pth_maxpriority` 4), and 2 ms waits woke ~120 ms late
  (`s3/RealtimeStateProbe.out`). Neither a latency-critical NSProcessInfo activity nor
  leaving darwin-background changed that. Under the application policy (`taskpolicy -a`) the
  same thread runs round-robin at priority 97 and wakes within 0.05 ms; the installed app's
  mix thread shows as 97R in `ps -M`. The audit ran its tests from such a clamped process.
- **What production did wrong under it.** 3.3.0 rendered at most four overdue blocks
  (40 ms of audio) per wake-up, so with wake-ups ~200 ms late it delivered about 60 % (the
  audit's 13,920–15,840 frames). A fixed 4 ms catch-up budget (session 2) fixed release
  builds but not debug ones, whose blocks cost ~5 ms on the throttled efficiency cores
  (−30 % to −47 %, `f12-bench/supply-matrix.out`).
- **The catch-up budget policy now.** Every wake-up renders all overdue blocks, never ahead
  of real time and at most 100 (1 s of audio). The 4 ms budget beyond the first four applies
  only while the scheduler really runs the thread realtime, where it keeps each burst inside
  the 9 ms constraint (a release block costs ~0.06 ms, so 4 ms is 80 blocks). A demoted
  thread is timeshare and is preempted like any other, so it has no constraint to honour.
- **Result** (`s3/f12-matrix.out`; 3 s runs, steady state after a 250 ms warm-up,
  criterion 48,000 frames/s ±5 %, every wake-up caught up within 20 ms, no realign):

  | Build | Host policy | Idle | 6 busy loops |
  |---|---|---|---|
  | release | application (realtime 97) | 3/3, ±0.00 %, lag 0 | 3/3, ±0.00 %, lag 0 |
  | release | clamped agent (timeshare 4, wake-ups ~200 ms late) | 3/3, −0.03 % to +0.05 %, lag 0 | 3/3, −0.18 % to +0.21 %, lag 0 |
  | debug | application | 3/3, −0.08 % to +0.10 %, lag 0 | 3/3, ±0.00 %, lag 0 |
  | debug | clamped agent | 3/3, −0.01 % to +0.15 %, lag 0 | 3/3, −0.09 % to +0.19 %, lag 0 |

  In the clamped rows each wake-up rendered up to 39 blocks; none was budget-limited.
- **The tests.** `testRealtimeAirPlayMixClockKeepsTheBridgeFed` keeps its thresholds (more
  than 19,200 and fewer than 33,600 frames in 0.5 s, no realign) and now also requires the
  promotion to be accepted, the scheduler to run the thread realtime at every wake-up and no
  wake-up more than 20 ms late. Whether the host clamps the process is read on an ordinary
  thread, independently of the mix code; only then is the test **skipped** (with that
  reading), never passed: when the thread may only run every ~200 ms, a 0.5 s instant says
  nothing about the clock (it read 23,520–33,120 frames there). A refused promotion fails.
  `testAirPlayMixClockSustains48kHzAfterWarmUp` runs everywhere: first block within 250 ms,
  steady 48,000 ±5 % over at least 1 s, every wake-up caught up, never ahead, no realign,
  and, where the host does not clamp the process, no wake-up more than 20 ms late.
  Five runs each (`s3/f12b-*`): clamped agent 5/5 sustained PASS (47,889–47,997 frames/s),
  realtime test skipped; application policy 5/5 PASS both (47,984–48,011 frames/s; 24,480
  frames in 0.5 s, maximum lateness ≤ 0.07 ms). `AirPlayMixScheduleTests` reproduce the old
  starvation and the demoted debug case on a virtual clock and run anywhere.

Limits: a clamped host still wakes the thread only every ~200 ms, longer than the bridge's
150 ms target, so a real AirPlay consumer would run dry between wake-ups there; the
policy keeps the long-run rate, not the buffer. The app is not clamped (97R), and the log
now says if macOS ever demotes its clock. The probes use a constant source; they do not
model the HAL device clock, resampling, per-app capture queues or a real receiver, so they
do not replace listening on AirPlay (R04).

## Distribution and update policy (F11)

- Releases are DMGs on GitHub Releases of the public repository `kyw1-2/All-of-MacOS`,
  built and signed either by the `All of MacOS signed release` workflow from `main` or on
  the build Mac with `build-and-sign.sh`; the tag names the source commit.
- The signature is the self-signed **AOM Dev** identity. Builds are not Developer ID
  signed or notarized, so Gatekeeper may ask for approval on first launch.
- AOM does not check for, download or install updates by itself. The owner's
  `scripts/auto-update-mac.sh` installs a release only after verifying its digest, bundle
  ID, version, build and pinned signing certificate.
- The in-app `UpdateChecker` stays unwired; with the real network session it reports
  `.disabled` ("This build does not check for updates…"), never `.upToDate`.

## Not run (needs a person)

| Check | Why not run here | What to do |
|---|---|---|
| F01 with a real "Save changes?" sheet | Needs an app with unsaved work on screen and a person to press Cancel | Checklist item 6 |
| F05 / R02 gestures on real hardware | Needs fingers on the trackpad | Checklist items 1–5 and 7 |
| R02 several trackpads | Only the built-in trackpad is attached (`ioreg`: SPI, no Magic Trackpad) | Pair a Magic Trackpad; rest a finger on one while swiping two fingers on the other: the swipe completes once |
| R03 permission recovery | Revoking or granting Accessibility changes the user's TCC state | Turn AOM off in Accessibility, then on again with Window Tiling closed: the title-bar snap stops and resumes without a relaunch |
| F06 a real 65-minute recording | Would record the user's screen for 65 minutes | Record 65 minutes with Editable Cursor Track on; in Studio the pointer is visible at 55 min |
| F08 a locked Keychain | Locking the login Keychain affects the user's session | Lock the login Keychain, open Clipboard: "Clipboard History Is Locked" with Try Again; unlock, Try Again: the history is back |
| F09 Flush DNS and Empty Trash for real | Signals a system service; deletes the user's Trash | Checklist item 11 |
| F12 / R04 AirPlay listening | Needs a HomePod/AirPlay receiver and a listener | Play 30 minutes to a HomePod through AOM, switch short videos 20 times; no gaps or crackle; with audio diagnostics on, `Diagnostics/audio-health.json` shows `delayedMixResets` 0, `mixRealtimeEffective` true, `mixLateWakes` 0 and `mixSustainedFramesPerSecond` ≈ 48000 |
| MCP with a real AI client | Needs a client token and would read real clipboard history | Ask a connected client for a large search; the reply arrives; quit the client mid-reply: AOM keeps running |

## Hardware checklist (to run on the MacBook)

1. Title-bar snap on: swipe left/right/up/down on a title bar → half/maximize/centre; longer → third; L-shape → quarter.
2. While the preview shows, add a third finger → the preview disappears and the window does not move.
3. Swipe, hold the same preview for 3 s, then lift → the window snaps to it.
4. Swipe down on a snapped window → it returns to its previous frame.
5. Automation off (menu bar or the main window switch), also half-way through a swipe → title-bar snap, top-bar Space swipe and Dock pinch do nothing; on again → they work.
6. TextEdit with unsaved text, pinch its Dock icon → "Save changes?" appears and stays for more than 10 s; Cancel → TextEdit and the text are still there; the HUD says the app is still open.
7. Top-bar Space swipe → switches Spaces once per swipe.
8. AirPlay: route an app to a HomePod in the Audio page, listen 30 minutes, switch output back.
9. Record 2 minutes with Editable Cursor Track, open Edit Recording → the pointer follows; record again with the save volume nearly full → recording refuses to start with a clear message.
10. Settings › Backups → Restore… on the oldest backup → the preview lists the counts and the settings it would change → "Restore Automations and Settings" → an alert asks to quit and reopen; a `-before-restore` backup appears and the restored one is still listed; the Automation pause state is unchanged.
11. System Tools → Flush DNS → "Flush DNS Needs an Administrator" (never "flushed"; AOM cannot signal the resolver without a password); with the password → "DNS cache flushed". Desktop Icons on a default Mac → the icons hide on the first click.
12. A long HUD message (pinch the Dock icon of an app showing "Save changes?") → the whole text is readable for several seconds.

## Behaviour changes to know about

- Workflow steps that used to report success regardless now report failure when they did not work (Dark Mode without the System Events permission, a window batch with a refusing window, Hide Other Apps with a refusal, keys/clicks/media keys without the post-event permission). A multi-step automation without "Continue on Failure" now stops at such a step.
- A title-bar snap preview no longer disappears after 1.2 s of holding still; lift to apply it or add a third finger to cancel.
- An MCP client that reads nothing for 30 s while a reply waits is disconnected.
- Capture History recovered from an unreadable manifest shows every recovered capture as pinned.
- Recordings do not start with less than 2 GB free on the save volume.
- A backup restore never changes whether automation is paused, and never restores the backup options or AI tool and screen-reading access. Restoring a backup's settings also resets settings that were still at their defaults when it was made.
- HUD messages that carry a reason or an instruction are shown in full, for up to 8 s.
- When the app closes an MCP connection, the stdio bridge answers the requests still waiting with a JSON-RPC error before it exits.

## Verification run for this release

See the GitHub release notes for the exact test counts, the commit and the DMG digest.
