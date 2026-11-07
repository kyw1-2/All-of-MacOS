# Responsiveness audit against 3.4.26

Base: `aom-dev-v3.4.26-b2026110708-7a41c8674045`, resolved commit
`7b1db7daeb98cc9c61e888fc713c1c4c7750d9b8`. The installed application reported
3.4.26, build 2026110708. The performance patch is prepared for release 3.4.27 (build 2026110709).

A five-second sample of the installed app on 2026-11-07 showed recurring main
thread stacks in `WindowPinningService.tick`, including WindowServer inventory
and session queries, and `AppAudioEngine.syncActiveProcesses`, including app
identity/icon lookup and CoreAudio process enumeration. The sample also showed
Mission Control polling; that subsystem is outside this patch. This is evidence
of repeated synchronous work, not a controlled before/after performance score.

Changes:

- Window pinning reads and filters the WindowServer inventory, lock state and
  capture permission in one background job. Requests cannot overlap or build a
  backlog. Main-actor panel state uses only value snapshots; AX element reads
  and source-window mutations retain their original main-actor ownership.
  Generation checks discard results after unpin, pause, activation, opacity or
  option changes, sleep and Space transitions. Pause and activation hide/stop
  the overlay immediately, independently of the background query.
- Unchanged pin panel frames, opacity, borders and ordering no longer generate
  repeated AppKit/WindowServer updates on every 150 ms tick.
- Audio playback status is refreshed independently of app identity. A single
  owner map supplies both playback detection and the sync's session membership
  decisions. UI row construction no longer repeats CoreAudio discovery.
  Names/icons have a 30-second fallback refresh, invalidated by app launch,
  termination, explicit app addition and a newly playing regular owner. Native
  playback still refreshes when processing is disabled. The renderer, DSP and
  tap creation/destruction algorithms are unchanged.
- Workspace's two-second system monitor is owned by the This Mac card, so its
  publications do not invalidate the entire dashboard and weekly chart. Hiding
  the card removes its monitor; inactive scenes stop sampling and resume on
  activation.
- A failed pin capture start clears its desired configuration, allowing an
  explicit retry of the same configuration. A new attempt clears the previous
  error; capture-stop errors remove the stale displayed frame. Resize failure
  still drains the old stream before a retry.

Regression coverage includes blocked background reads with a responsive main
actor, rejection of 100 overlapping requests, invalidated results, recovery of
subsequent polling, failed start/resize retries, and helper-process playback
ownership. Existing audio pipeline and capture lifecycle tests remain in use.

Validation command:

```sh
scripts/run-tests.sh --filter 'WindowPin|Audio|Workspace|SystemStatus|TextActions|Trackpad|Clipboard|WiringResponsiveness' --skip 'testImagesIndexedBeforeBoxesGetThemWhenPreviewed|testIndexingKeepsLineBoxesAndRegionsReadOnlyTheirText'
git diff --check
```

The snapshot poller test deliberately blocks its reader and verifies main-actor
execution can continue. It does not establish a real-world frame-rate or CPU
improvement. Physical pinning, sleep/Space transitions, and HomePod listening
still need validation with a packaged build. The initial audit did not replace the installed application; packaged-build verification and installation are tracked separately.

The scheduling approach follows Apple's [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness):
move synchronous non-UI work off the main actor while keeping UI changes on it.

The initial expanded test run stalled in Vision/TextRecognition while awaiting a
semaphore in `VNRecognizeTextRequest`; a three-second process sample confirmed
the wait, with the XCTest main thread waiting for asynchronous completion. That
run was terminated. The two real-OCR tests named in `--skip` above are excluded
from the subsequent run, rather than reported as passing. No OCR implementation
change is included in this patch. Swift 5 debug compilation retains existing
Swift 6 actor-isolation warnings elsewhere in the codebase.
