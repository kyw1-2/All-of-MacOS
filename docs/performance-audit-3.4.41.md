# AOM 3.4.41 runtime optimization

Baseline: `3c37e00b7b903b9dfbb71515d478067880ea1946` (installed 3.4.40).
Build: 2026111201. Branch: `perf/runtime-latency-20261112`.

## Evidence and changes

A five-second sample of the installed process found repeated full WindowServer
window enumeration and Swift dictionary bridging in `WindowPinSnapshot.read`,
plus LaunchServices queries during `AppAudioEngine.syncActiveProcesses` on the
main thread. Sampling weights include blocked time; they are not CPU shares.

- Window pinning now queries only tracked window IDs with
  `CGWindowListCreateDescriptionFromArray`. The callback-free CFArray contains
  raw IDs, not NSNumber pointers. Offscreen windows remain queryable; closed
  windows are omitted. Lock, capture-permission, PID and stale-result guards,
  and the 150 ms refresh cadence remain in place.
- Audio owner resolution memoizes both regular applications and negative
  ancestor lookups within each sweep. Fallback enumeration reuses existing
  NSWorkspace objects. The table is discarded between sweeps; existing owner
  cache expiry, workspace invalidation and ambiguous-owner rejection remain.
- Playback-listener reconciliation and owner resolution share one HAL process
  list. A failed read retains existing listeners rather than treating the
  failure as an empty list.
- The mixer's competing-app lookup follows application launch/termination
  events instead of scanning all applications after each audio sync.

## Measurements

Alternating old/new query batches on the same desktop, 391 total windows and
three selected windows: mean full query 5.761 ms; targeted query 0.190 ms
(30.4x faster for this operation). PID, bounds and onscreen values matched.
Empty and nonexistent ID queries returned empty results.

Twenty alternating cold owner sweeps, using the actual old/new source and
live CoreAudio process list: all 20 owner maps matched (31 owners).
Median 5.266 ms -> 3.681 ms (30.1% reduction for this operation).
Medians exclude the influence of initial LaunchServices warm-up outliers.
A first prototype that recreated NSWorkspace application objects was slower;
it was corrected to reuse those objects before retaining this change.

These are component measurements under normal concurrent desktop activity,
not a whole-app CPU or interaction-latency improvement claim. Installed-app
A/B testing, physical audio output, sleep/wake and interactive pin controls
remain separate validation after installation.

## Validation

`RuntimePerformanceTests` covers positive/negative memoization, new sweeps after
PID reuse/activation changes, existing-object reuse, empty window queries, and
single-flight/stale-result suppression for the asynchronous pin poller.
Final source validation: `bash scripts/run-tests.sh -j 2` passed all 62 tests
(0 failures), including five new runtime regression tests. SwiftPM compiled
the application and test targets successfully. Existing concurrency warnings
remain. An earlier compilation used an intermediate module while edits were
in progress; final validation rebuilt the finished sources successfully.

Release build: `ALLOFMACOS_SKIP_AUTO_RELEASE=1 ALLOFMACOS_BUILD_JOBS=2 bash build-and-sign.sh`.
This produces and signs a local app; publishing and installation are separate.

API reference: [Apple Quartz Window Services](https://developer.apple.com/documentation/coregraphics/quartz-window-services).
