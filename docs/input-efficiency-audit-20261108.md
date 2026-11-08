# Input and responsiveness audit — 2026-11-08

Base: `e6331d4`, branch `fix/input-efficiency-20261108`.

## Scope and evidence

The source inventory covers 446 application Swift files and 213 existing test
files. Repository-wide searches covered HID/event taps, timers and repeating
animations, synchronous waits, delayed work and notification lifetimes. Manual
review concentrated on mouse input, preview animation, audio UI polling,
recording publications, touch visualization, preset settings and the existing
Mission Control/audio/window-pinning performance work. This is a source-wide
risk scan with targeted implementation review, not a claim that every feature
or physical device has been exercised.

A three-second sample of the installed process showed SwiftUI repeating
animation and audio app discovery on the main thread. The application bundle
reports 3.4.30 / 2026110712. Another build was already running in the original
checkout; this patch uses an isolated worktree and does not alter that build or
the installed app. The initial `ps` CPU reading (30.2%) is an uncontrolled
snapshot, not a benchmark or a measured improvement.

## Fixed findings

1. **Failed side-button HID open blocked future starts.** The failed manager
   remained non-nil. Failure now closes/unschedules it, so permission recovery
   or app activation can retry. A fake failing opener verifies two independent
   attempts without opening actual input devices.
2. **Input lifecycle recovery was incomplete.** Mouse button taps and side HID
   now suspend across sleep/permission loss, retry on wake/recovery/activation,
   and invalidate stale event taps. The thumb wheel preserves desired settings
   while suspended, reopens on recovery, resets delayed input, and avoids a
   restart when unchanged settings are applied.
3. **Rapid duplicate edges overwrote one another.** A single timestamp per edge
   could only remember the last native/HID observation. Bounded per-edge queues
   now match observations one-for-one and preserve individual swallow verdicts.
4. **Slow volume writes accumulated requests.** The 25 ms input batch did not
   wait for the previous asynchronous volume operation. The thumb wheel now
   has at most one operation in flight and one pending delta capped at the existing 12-percentage-point burst limit. Reset
   discards old pending input while waiting for an outstanding write to finish.
   Stop cannot undo a hardware operation already submitted.
5. **Unnecessary HID work.** Side-button HID starts only for buttons 3/4.
   Receiver classification is cached and invalidated on device additions and
   removals instead of enumerating devices again on each event.
6. **Mouse timer churn.** A pending long-press/deferred-click wake is retained
   while its deadline is unchanged, rather than cancelled and requeued for
   each drag event. Completed wakes clear their token before polling again.
7. **Leaking preview loops.** Tip-tap/position-click recursion and delayed
   preview starts now use cancellable SwiftUI tasks. Preview identity follows
   gesture, scene activity and Reduce Motion. Circle/triangle timelines pause
   when inactive and have a 30 Hz maximum cadence. Repeating animations are
   removed when animation is disabled.
8. **Audio UI queried hardware while inactive.** Two main-window controls poll only while their scene is active. The floating
   mixer follows its explicit NSPanel visibility because it is hosted outside
   a SwiftUI Scene. All three use cancellable polling tasks.
9. **Recording republished unchanged seconds every video frame.** The timer
   publishes only a changed integer second and ignores work after stop begins.
   Video frame generation cadence is unchanged.
10. **Touch visualization republished identical trails.** Resting fingers no
    longer publish identical trail dictionaries. Fade pruning publishes one
    dictionary update for all fingers, without an extra manual notification.
11. **Wheel configuration reset unnecessarily.** Unchanged reverse/smoothing
    configuration keeps its running tap and animation state.
12. **Thumb-wheel mode missing from backup.** `AOMUGREENThumbWheelVolume` is
    included in preset backups and their change-area labels. Thumb-wheel
    settings notifications apply restored settings to the running observer.
13. **Optional CGEvent check misclassified a missing event.** A nil CGEvent
    now contributes zero horizontal delta instead of satisfying `nil != 0`.

## Validation

The first targeted test build was blocked by an existing actor-isolation error
in `OverlayActivationTests.testMissionControlPollingCadence`: it called a
main-actor-isolated service method from a nonisolated test. The test now runs
on MainActor. No polling behavior was changed to make the test pass.

The first full run also exposed an existing false positive in the source-wide
preference scan: `ActionExecutor` reads macOS `AppleInterfaceStyle` for dark-mode
feedback. The scanner now excludes that exact read-only system key and asserts
that AOM does not own it. The production reset registry is unchanged, so this
fix cannot add system appearance preferences to the reset list.

Eleven added regressions cover failed HID open retry, unnecessary HID startup,
rapid duplicate matching, stale-edge expiration, bounded slow volume writes,
input cancellation/reset, and stationary/fading touch publications.

The final broad validation uses:

```sh
scripts/run-tests.sh -j 2 --skip 'N334AirPlayGainStagingTests|testImagesIndexedBeforeBoxesGetThemWhenPreviewed|testIndexingKeepsLineBoxesAndRegionsReadOnlyTheirText'
git diff --check
```

The two real Vision OCR tests are excluded because the preceding 3.4.26 audit
already documented a semaphore stall in those exact tests. Excluded tests are
not counted as passing. The initial full run was stopped during
`N334AirPlayGainStagingTests.testBoostedTransientsNoLongerMakeTheFastLimiterWork`.
A process sample confirmed active DSP calculation, not a deadlock; the suite
contains multiple long synthetic-signal comparisons in the debug build. No DSP
implementation changed, so that entire stress class is excluded from the final
broad run and remains unverified. Other audio tests remain included. The only
assertion failure observed before termination was the preference-scan false
positive described above. Final result: **PASS**, command exit status 0. The final debug build completed
in 54.25 seconds. XCTest selected 2,540 tests: **2,531 passed, 9 conditionally
skipped, 0 failures**, in 136.368 seconds. All eleven added regressions passed.

The nine conditional skips are six opt-in UI render tests, one missing recorded
DMG fixture, one missing Paste installation and one live-window fixture test.
The separately excluded nine DSP stress cases and two OCR cases are not part
of that selected count. Other real OCR checks completed successfully.
`git diff --check` also passed. No release build or physical-device validation
is claimed.

## Remaining physical validation

No installation, launch replacement, release or push is performed in this
change. Automated tests do not prove that the user's intermittent hardware
symptom has disappeared. A packaged build still needs UGREEN 2B89:0912 tests
for unplug/replug, sleep/wake, permission loss/recovery, rapid side clicks,
slow monitor volume adjustment and simultaneous trackpad use. Preview
visibility/Reduce Motion and recording should also be checked interactively.
Existing broad Swift 6 actor-isolation warnings are outside these Swift 5
changes. The existing audio identity cache, background window-pinning and
Mission Control snapshot paths remain in place; the sample alone does not
justify replacing those architectures.
