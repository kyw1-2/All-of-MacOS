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

## 3.3.3 addendum

Follows the main 3.3.2 audit's A01–A03 (2026-10-29). Code: audio stream commits 3ec2590 (A01),
a9b6630 (A02), 0426a43 and 9e6732e (A03); tests in `AllOfMacOSTests/Audio333Tests.swift`
(synthetic signals, no realtime thread). Still not listened to on a HomePod.

### A01: the HomePod's 128-frame IO

Read-only evidence on 2026-10-30, with 3.3.2 installed and playing:

- HAL probe: the AirPlay device (id 114) runs 48 kHz (48000.00 measured) at 128 frames
  (range 15–4096), safety offset 0, latency 0, no variable buffer sizes, and
  `kAudioDevicePropertyIOCycleUsage` 1.0 (the default, which is also the maximum).
- audio-health.json after about 22 h of output: `deviceCycleGaps` 92 over 30,017 frames (about
  326 frames, 6.8 ms, each), no underruns or trims, the mix thread realtime at priority 97, no
  late mix wakes, drift −418 ppm.
- `log show`: for the cycles AOM logs as "skipping cycle due to overload", coreaudiod's analytics
  give `cause SafetyViolationOccurred`, `io_buffer_size 128`, `io_cycle_usage 1`,
  `HAL_client_IO_duration` 22,208 and 18,291 ns and no page faults. AOM's whole IO takes about
  20 µs of the 2,667 µs cycle, so the gaps are HAL safety violations at the device's fixed IO, not
  AOM's callback cost.

What 3.3.3 changes:

- Gap fade-in: after a sample-time gap the bridge fades back in from silence over 5 ms
  (smoothstep). Nothing is skipped; the stream continues where the gap leaves it. The edge into
  the hole cannot be shaped, because it happens before AOM can know. Counter `gapFadeIns`.
- Callback cost, measured in the callback with two clock reads: `renderCostMaxMicros`,
  `renderCostMeanMicros`, `renderCallbacks`, `renderCycleLoadPercent`. Work stays bounded: at
  most one cycle plus one fade (368 frames at 128-frame IO) on an event.
- `kAudioDeviceProcessorOverload` is listened to (`processorOverloads`, `overload` events), and
  `ioCycleUsage` is reported, not set: a lower value would only give AOM less of the cycle.
- Drift loop: at 2.67 ms cycles the 480-frame mix blocks against 128-frame pulls made a sawtooth
  that aliased into a beat near 0.5 Hz (correction wobble ±20–40 ppm). `levelBias` now counts the
  newest block as arriving over its 10 ms: the spread is 0.7–1.3 ppm without push jitter and about
  43 ppm (0.07 cent) with 1 ms of jitter.
- Not used: audio workgroups (marked unavailable to Swift on realtime threads; they would need a
  C shim), hog mode, and a private aggregate device to get a larger IO size (it would add a
  client to the HomePod and could not be tested without disturbing playback).

### A02: output moves

The 3.3.2 limit "during the 5 ms fade the old and new outputs both pull from the app's queue …
a move can skip about 10 ms" no longer applies. `AppAudioTransport` has one consumer at a time:
each output's closure carries a consumer number, and only the owner pulls. On a move the owner
renders exactly to the end of a 5 ms fade-out and hands over; the new output continues with the
next frame and fades in. Stale consumers render silence without taking the lock, and if the old
output stopped rendering the new one takes over after 50 ms. The two outputs run different clocks
(AirPlay about 2 s behind), so this is a fade-out then a fade-in of one contiguous stream, not an
overlapping crossfade. The DSP state passes over intact. Unchanged from 3.3.2: 5 ms trim, underrun
and clear fades, EQ changes crossfading from fresh filter state, and Boost or Overdrive switches
crossfading signals that are not time-aligned.

### A03: timestamped events

- audio-health.json gains `events` (oldest first; `time` in local ISO 8601 with milliseconds,
  `kind`, `source` as `output:<uid>`, `app:<bundle id>` or `system`, and `frames`,
  `reductionDB`, `lateMS`, `value` or `detail`), `eventsLost`, and
  `sinceReset {resetAt, seconds, counters}`.
- Kinds: `cycleGap`, `trim`, `underrun`, `clear`, `dropped`, `limiterEngaged`,
  `limiterReleased`, `overload`, `reconfiguration`, `bufferSize`, `formatNotice`,
  `outputStarted`, `outputStopped`, `outputFailed`, `defaultOutputChanged`, `deviceListChanged`,
  `tapAttached`, `tapDetached`, `tapRewrite`, `outputMoved`, `handover`, `mixLate`,
  `countersReset`, `effectChanged`.
- Realtime producers (the HAL thread, the mix thread, a transport's owner) write into lock-free,
  preallocated rings, six atomic stores per event. A poller on a utility queue drains them every
  250 ms into the last 200 events with wall-clock times, and folds counter deltas into totals
  that survive output and session re-creation.
- Reset: `defaults write com.kyw.allofmacos AOMAudioDiagnosticsResetAt -float $(date +%s)`, read
  at the next diagnostics write (propagation to a running app is best effort); a relaunch resets
  too. The key is a request, not a setting, so backups leave it out.

### Listening test, 3.3.3

Run the 3.3.2 test above with diagnostics on. In addition:

1. Write down the time of every crackle, then look in `events` within a second of it: a
   `cycleGap` points at the HAL, `trim` or `underrun` at buffering, `tapRewrite` at tap
   membership, `limiterEngaged` at the gain stage, `outputMoved` or `handover` at a switch.
   With 3.3.3 each `cycleGap` should sound like a short dip, not a click.
2. Between states A–D, request a reset (above) and compare `sinceReset` instead of relaunching.
3. Move music between the speakers, headphones and the HomePod: one short dip each time, no
   skip or stutter.

### Still open

- No listening test on a HomePod yet; the overload listener and the event log have not run
  against the live device (they need the 3.3.3 build installed).
- The event poller runs only when `AOMAudioDiagnostics` was on when an output started; there is no
  reset button or automation action (the API exists).
- App queues (tap to mix clock) have the same block sawtooth; their drift loop did not get
  `levelBias` (expected to be inaudible, not measured live).
