# HomePod crackle — 3.4.8, 2026-11-01

## Measured state of 3.4.7 (installed, rev `b821187`)

`~/Library/Application Support/AllOfMacOS/Diagnostics/audio-health.json`, snapshot at
18:12 KST, window 1,162.4 s (reset 17:54:52), AirPlay output
`8f6f5f5d-…-Audio`:

| counter | value |
|---|---|
| `captures.1343.softenedDropouts` (Chrome) | **7,065** |
| `captures.1343.captureGaps` / `captureGapFrames` | 0 / 0 |
| `captures.1343.captureClockResets` | 0 |
| output `underruns` / `trims` / `droppedFrames` | 0 / 0 / 0 |
| output `deviceCycleGaps` / `clockSkips` | 3 / 3 (980 frames) |
| output `renderCostMeanMicros` | 18.2 µs (0.7 % of a 128-frame cycle) |
| `mixLateWakes` / `mixWorstLagAfterWakeMS` | 0 / 0 |
| `wiredKilobytes` / `wireFailures` | 5,626 / 0 |

7,065 shapings in 1,162 s is ≈ **6.1 Hz**. Every shaping event applies a 2 ms
fade-out to the audio before the zero run and a 2 ms fade-in to the audio after
it, i.e. 4 ms of amplitude modulation per event, at six events per second, on
content that the capture timeline simultaneously certified as complete (zero
missing packets). That is the audible flutter; 3.4.7 had measured the same
mechanism at 12.7 Hz (8,086 events in 633 s) and halved it with the step guard
instead of removing it.

The remaining device-side faults in this window are three 128-frame-class HAL
gaps (980 frames total, already shaped in place) and 51 leveler episodes with
1.0–3.7 dB of slow gain movement — neither is a 6 Hz modulation.

## Change

- `AudioDropoutSoftener` gains `shapesUnverifiedHoles`, default
  `AudioDropoutSoftener.shapesUnverifiedHolesByDefault = false`. The zero-run
  heuristic (any `minimumRun`-frame run of exact zeros after a sample above
  `discontinuityThreshold`) is now opt-in and is not used by the app.
- Production shaping happens only where a measurement proves a hole:
  `AppAudioTransport` on `.gap` from `AudioCaptureTimeline` (sample-timestamp
  contiguity) calls `fadeOutPendingAudio()`, writes the exact missing interval,
  then `fadeInNextAudio()`. `softened` increments there, so the diagnostic
  counter now tracks confirmed holes rather than content.
- Unchanged on purpose: fixed lookahead (`2 ms + 32 frames`, 128 frames at
  48 kHz AirPlay, 0 on local output), the producer-owned delay, the HAL
  gap/clock-skip path, `mlock` wiring and the −1 dBTP network limiter with its
  150 ms release.

## Validation

- Synthetic: `testProductionSoftenerNeverShapesUnverifiedZeroRuns` (a 0.5 → 0 →
  0.5 step, a quiet passage, a 3,000-frame rest, and packet sizes 1/17/128/1024)
  and `testProductionSoftenerStillShapesTimestampConfirmedGaps`; the older
  heuristic tests now construct the softener with `shapesUnverifiedHoles: true`
  and keep pinning the historical behaviour; the transport test pins
  `softenedDropouts == 0` for an unverified hole and
  `AudioCaptureTimelineTests` still pins one confirmed 128-frame gap → one
  shaping.
- Real-time behaviour, the HAL's own 128-frame cycle and the receiver's network
  path are not reproduced by these tests. After installation the check is: play
  the same content to the HomePod and confirm `softenedDropouts` stays at the
  `captureGaps` count instead of climbing several times a second.
- This removes an artifact AOM itself generated. It does not repair the shared
  CoreAudio/HomePod safety violations documented in 3.4.6/3.4.7, and it does not
  reconstruct source audio that an app genuinely dropped.
