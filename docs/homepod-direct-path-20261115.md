# HomePod crackle: one clock instead of three — 2026-11-15

Base: 3.9.1 (`74a81b6`). Output: HomePod (AirPlay, 48 kHz, 128-frame IO), macOS 27.3.
Every measurement here was made with muting process taps, so no test signal was audible
on the HomePod.

## How it was measured

A probe (scratch tool, not shipped) creates a muted tap on a chosen process, reads it through a
private aggregate and records what it hears. The probe reports zero runs between samples, sample
discontinuities relative to the local level, input sample-time gaps and HAL overloads, and can
record the raw samples. Sources:

- `afplay` and a separate Chrome test profile playing a 997 Hz tone, steady or amplitude-modulated
  (0.5 Hz, 0.02–0.30), with pauses;
- AOM itself (a muted tap on AOM's process records exactly what AOM sends to the HomePod).

## What was found

| Path | Result |
|---|---|
| Tap only, any buffer size (128 / 512 / 1024), local speakers and HomePod, afplay and Chrome | clean (no holes, no discontinuities other than stream start/stop) |
| Chrome native on the HomePod, 30 s | one 9 ms dropout at a stream boundary |
| **AOM 3.9.1 HomePod path, Chrome AM tone, 47 s** | two 3 ms phase splices exactly 15 s apart; AOM's diagnostics for the same seconds: 0 underruns, trims, capture gaps, cycle gaps, clock skips |
| AOM 3.9.1 HomePod path, steady tone, 60 s | a run of short zero-filled holes every 10 ms for several seconds, plus splices |
| Tap + HomePod in **one** aggregate (device clock, drift-compensated tap), 5 min, Chrome and a generator in parallel | clean; one HAL overload cost one 128-frame gap, the same as native playback |
| Tap-only capture of the same sources over the same 5 min | clean |

So the capture itself is not the problem, and neither is the HAL in isolation. What AOM added is
the chain between them: tap aggregate (1024-frame IO) → app queue + resampler + drift loop → a
Mach-time mix thread in 10 ms blocks → bridge queue + resampler + drift loop → an output-only
AUHAL at 128 frames. Three clock domains and two asynchronous resampling bridges produced
splices and holes that none of AOM's own counters could see, because each stage judged itself
healthy. The 3.4.17 safety fuse then turned HomePod effects off.

## What changed

- **Direct path** (`AirPlayDirectStream`): for an app routed to an AirPlay output, one private
  aggregate holds the app's muted tap and the AirPlay device; the device is the clock and the tap
  is drift-compensated to it. One IOProc reads the tap, runs the app's chain (EQ, Magic Boost,
  volume, balance, Overdrive), the −1 dBTP true-peak limiter (150 ms release) and writes the
  device. No queue, resampler, mix thread or shared sender. 5 ms fades at start, after an IO gap
  and on stop. No allocation and no waiting lock on the IO thread.
- Sessions on the direct path attach while the app plays or is muted and detach after 30 s idle.
- The safety fuse no longer applies to the direct path. If the fuse (not the user) had turned
  HomePod effects off, they are turned on again once, and the event log says so.
- The old bridge stays available for comparison: `defaults write com.kyw.allofmacos
  AOMAudioAirPlayDirect -bool false`, then relaunch.
- Audio control (process sweep, device and transport reads) moved off the main thread
  (`AudioControlSnapshot`): a gather on a private queue, a short apply on main.

## Limits

- Each app has its own limiter on the direct path; two apps on one HomePod are summed by the
  system after limiting.
- Output-wide Magic Boost, the leveler and a hosted Audio Unit master effect do not run on the
  direct path.
- An app that starts playing is heard unprocessed for a moment until its session is up.
- The HomePod's own 128-frame HAL deadlines still apply; a missed one is one short gap, as with
  native playback.
