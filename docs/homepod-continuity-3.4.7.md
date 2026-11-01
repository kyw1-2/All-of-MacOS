# HomePod continuity audit — 3.4.7, 2026-11-01

## Observed failure and what it establishes

The installed 3.4.6 executable (`a59c8ea1d581e6add99d636cdddd8fbf44463d71`, build `2026110107`)
was audited during active Chrome streaming to HomePod (AirPlay output UID `8f6f5f5d-c1d1-48fa-96c7-14a65c88088f`):

- Over 633 seconds (~10.5 minutes), `softenedDropouts` climbed from 3,212 to **8,086** (~12.7 Hz).
- Meanwhile, output HAL health was completely clean:
  - `renderCostMeanMicros`: 18 µs (0.7% load of 128-frame cycle).
  - Output queue `underruns`: 0, `trims`: 0, `droppedFrames`: 0.
  - `captureGaps`: 0, `captureClockResets`: 0 (AudioCaptureTimeline detected zero missing packet gaps).
  - Device clock skips: only 3–4 HAL gaps total across 10 minutes, cleanly absorbed in-place.
- Despite near-zero hardware/network faults, the user reported severe, persistent "crackling/fluttering" audio ("지지직거리는 소리").
- Root cause: `AudioDropoutSoftener` monitored for any exact-zero run $\ge 32$ frames (0.66 ms) after audio $\ge 0.001$ (-60 dBFS). In digital speech (consonant closure pauses) and music (rhythmic rests), gentle pauses between 0.66 ms and 85 ms occur dozens of times per second. Because every pause was classified as an unheralded "dropout," the softener repeatedly applied a 2 ms (96-sample) fade-out to previous audio and a 2 ms fade-in to following audio, continuously modulating the waveform at ~13 Hz and creating intense acoustic crackle.

## Fix (3.4.7)

1. **Step Discontinuity Guard (`discontinuityThreshold = 0.02`, ~ -34 dBFS)**:
   - Audible clicks/pops occur strictly when an audio waveform with significant instantaneous energy is abruptly severed to zero, or abruptly jumps from zero.
   - `AudioDropoutSoftener` now measures the edge step magnitude. A run of zeros only qualifies as a falling hard edge if `lastSamplePeak >= discontinuityThreshold`. Smoothly decaying instruments, voice pauses, and low-level noise floor transitions are ignored.
   - Likewise, resuming audio only activates a fade-in if `peak >= discontinuityThreshold`.
2. **Preserve Bit-Exact Delivery for Natural Audio**:
   - Natural speech and music without step discontinuity now pass through completely untouched (0 shaping operations).
   - Real hard dropouts (e.g. abrupt IO block timeouts at 0.5 amplitude) continue to be softened with smooth Quintic S-curves, preserving all 3.4.0 crackle-suppression invariants.
3. **Automated Verification**:
   - Added `testNaturalSpeechPauseAndMusicalDecayAreNotMistakenForDropouts` to `HomePodCrackle340Tests.swift`.
   - Verified that smoothly tapered zero intervals produce `softened == 0`.
   - All 10 tests in `HomePodCrackle340Tests`, all 5 tests in `AudioCaptureTimelineTests`, and all 42 suite tests pass with 0 failures.
