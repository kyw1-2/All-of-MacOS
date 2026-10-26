# 3.0.10 — Repeated crackle investigation

Baseline: `e95f295` (3.0.9, build 2026102604).

## Evidence

The user reported repeated crackle after the earlier immediate listening check.
The earlier sine-wave tests established a clipping correction, but did not
certify continuous realtime delivery. With AOM processing disabled, the user
confirmed that crackling stopped while HomePod native playback continued.

Live CoreAudio logs recorded IO overload and a Chrome safety violation with
AOM among the active clients, a smallest IO buffer of 128 frames at 48 kHz,
and a safety gap of approximately 3.31 ms. These logs indicate missed deadlines;
they do not by themselves attribute every overload to a particular function.

The old capture transport and AirPlay receiver used `NSLock.try()`. Contention
returned a pre-cleared output buffer or discarded an entire input callback.
The standalone production-code stress reproduction uses 128-frame capture,
480-frame render blocks, and deliberately frequent control-state reads:

| Five-second contention stress | Silent 10 ms output blocks |
| --- | ---: |
| 3.0.9 mutex transport | 10 / 496 |
| New SPSC transport | 0 / 501 |

The new run also reported zero dropped input frames, zero buffer underruns and
zero render handoff contentions. The control polling is deliberately heavier
than normal application use; this is a contention reproduction, not a claim
that all ten gaps occurred on a physical HomePod.

## Changes

- A preallocated stereo SPSC queue uses acquire/release write/read cursors.
  Producer and consumer never lock or dispatch. Each side owns its cursor;
  only the consumer owns interpolation/priming/fade state.
- Control/capture clear requests publish a monotonic cutoff and generation;
  the consumer applies them without racing its sample history. New samples
  after the cutoff remain available.
- A full queue refuses new frames rather than overwriting frames in use.
  Stale receiver backlog is discarded by the consumer and counted separately.
- The non-realtime AirPlay mixing worker may wait for brief source-list or
  handoff locks. The HAL callback remains non-blocking.
- Idle/priming sources publish a zero meter and skip unnecessary EQ and compressor
  processing. Filled buffers retain the same DSP path.
- AOM requests a larger capture quantum only on its own private AirPlay
  aggregates, within advertised bounds. This is best effort and does not
  rewrite the machine's selected output or hardware volume.
- Optional local diagnostics report captured/rendered/queued frames, dropped
  frames, underruns, clears/discards, maximum dispatch delay and handoff
  contention. No sample audio is recorded. The diagnostics switch defaults off.
- Modern macOS uses Synchronization.Atomic; the macOS 14 path uses barrier
  atomics. The compatibility path compiles for arm64 macOS 14.

## SoundSource EQ migration

The user confirmed the saved custom `Speaker Preset` was the intended profile.
Its stored normalized values were converted using the installed SoundSource
Equalizer.js formatter: `(value - 0.5) * 24` dB. Band frequencies match AOM.
The exact ten values were applied to AOM's Custom master EQ and verified through
preferences and the live sliders. Previous AOM EQ settings were saved locally.
SoundSource's own DSP algorithm and AOM's filters are different; this migration
copies band settings, not proprietary filter implementation.

## Validation

- Full local suite before the final counter-only additions: 1,044 discovered
  cases, 3 opt-in fixture/render skips, zero failures; existing 15 interactive
  OCR exclusions retained.
- Production PCM-path tests still pass at 44.1/48 kHz, including EQ response,
  gain/mute, linked stereo limiting and hot-input distortion regressions.
- New queue tests verify wraparound ordering, concurrent producer/consumer and
  health readers, and clear semantics retaining new audio.
- Standalone contention comparison described above is compiled with `-O`.
- The optional AGY review was unavailable (interrupted without consuming or
  returning a review); no independent PASS is claimed.

Installation, live counter observation and the final listening result are
recorded in the task's delivery report. A finite observation cannot establish
perfect behavior for every hardware, network or CPU workload.
