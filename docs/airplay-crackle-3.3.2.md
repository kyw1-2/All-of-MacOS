# HomePod / AirPlay crackle, 3.3.2

## Evidence (installed 3.3.1)

- `audio-health.json` after 7.7 h of HomePod output: no underrun in the AirPlay
  bridge or any of four app queues; the mix thread realtime at priority 97, never
  more than 0.75 ms late, no catch-up blocks; 31,114 discarded bridge frames, about
  two hard-cut trims. No "overload" or "skipping cycle" line in 24 h of log (the HAL
  may log them at a level that is not kept).
- Settings: Master Boost on; a custom master EQ with +7.4 dB in the lowest band and
  +5.1 / +7.7 / +5.5 dB in the upper ones, into a −0.2 dBFS sample-peak limiter with
  a 25 ms release.
- Earlier audits: the AirPlay device's default IO was 128 frames with no safety
  offset (coreaudiod "Overload possibly due to safety violation"); format notices
  were compared like with unlike and each restarted the unit; tap rewrites followed
  browser helpers coming and going; App Nap and timer coalescing delayed the mix clock.

Buffering is not what was heard (likely). SoundSource writes to the device with
the device's clock; AOM mixes on its own clock and bridges to the HomePod's, so
every gain stage, splice and restart on that path is AOM's.

## Root causes (most likely first)

1. Gain staging: Boost plus EQ into a sample-peak limiter. Inter-sample overs are
   clipped by the receiver's lossy decoder, and a 25 ms release follows bass cycles
   (heard as grit).
2. HAL overloads at 128-frame IO: each skipped cycle is a click.
3. Unshaped discontinuities: hard-cut trims, underrun and clear cuts, delay lines
   left full when a stream stopped, a full queue's splice.
4. IO restarts: format notices, IO re-requests, a device list read without the
   HomePod (which stopped the output and every HomePod tap).
5. Tap membership rewrites and a mix clock under App Nap.

## Fixes in 3.3.2

- Network bus: −1 dBTP true-peak limiter (4× oversampled detection), 150 ms
  release; Overdrive on AirPlay uses the same release, switched in place.
- Kaiser-windowed sinc resampling and a PI drift loop (±0.2 %) in both queues;
  fades on start, underrun, clear and full queue; crossfaded trims; the app chain
  runs its delay lines empty; AirPlay app queues start at their 80 ms target.
- 1024-frame IO, re-requested only while the device runs AOM smaller (30 s, then
  backing off to 10 min). Measured after installing 3.3.2: the HomePod used here
  accepts the request (status 0) and keeps 128 frames. That is true for AOM and
  for a separate test process, through the device property and through the audio
  unit, so on this device the larger buffer does not apply.
- In-place reconfigure; no restart for a format notice that keeps the rate; a new
  rate is confirmed 250 ms later.
- The output survives one device list without the HomePod (released when the
  device reports dead or is missing for 1.5 s); an output is not released while
  a source fades; `add` allocates before taking the mix lock.
- Nap guard (`.userInitiatedAllowingIdleSystemSleep` + `.latencyCritical`); tap
  membership debounce (two syncs); cycle-gap, IO-size, reconfiguration and
  ignored-notice counters in diagnostics.

## Remaining limits

- Not listened to on a HomePod. All checks are synthetic signals and pure logic.
- Output moves: during the 5 ms fade the old and new outputs both pull from the
  app's queue and share its DSP state, so a move can skip about 10 ms.
- Trim, underrun and clear fades are 5 ms; an EQ change crossfades over 10 ms from
  fresh filter state; switching Magic Boost or Overdrive crossfades signals that are
  not time-aligned. All are events, not steady state.
- 48 → 44.1 kHz bridging uses the slower stretched-kernel path on the HAL thread
  (cheap at 1024 frames). The tap's rate is taken from the tap format, not the
  aggregate's measured rate.
- Diagnostic counters reset when an output or session is recreated.

## Listening test

1. `defaults write com.kyw.allofmacos AOMAudioDiagnostics -bool true`, relaunch
   3.3.2; the file is `~/Library/Application Support/AllOfMacOS/Diagnostics/audio-health.json`.
2. Play the same loud, bass-heavy track to the HomePod for 20 minutes in each
   state, noting the time of every crackle: A Master Boost on, current EQ;
   B Boost off, current EQ; C Boost on, flat EQ; D Boost off, flat EQ.
3. Copy `audio-health.json` at the end of each state and compare:
   - `outputs.<uid>.deviceCycleGaps` and `deviceGapFrames` (HAL overloads),
     `deviceBufferFrames` (1024 where the device allows it; the HomePod tested
     here stays at 128), `reconfigurations`, `ignoredFormatNotices`;
   - `trims`, `underruns`, `discardedFrames`, `droppedFrames` (bridge and app queues);
   - `captures.<pid>.tapRewrites`, `underruns`, `driftCorrectionPPM`;
   - `mixLateWakes`, `maximumMixDelayMS`, `mixRealtimeEffective`.
4. Reading it: crackle in A only, with flat counters, is the DSP chain (Boost / EQ
   level); crackle that lines up with `deviceCycleGaps` is the HAL; with trims or
   underruns, buffering; with `tapRewrites`, tap membership; a 30 s rhythm would be
   the IO re-request (now only while the device runs AOM smaller).
