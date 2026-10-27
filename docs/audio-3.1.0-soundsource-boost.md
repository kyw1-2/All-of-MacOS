# Audio 3.1.0: HomePod crackle and SoundSource-style boost

AOM 3.1.0 removes the crackle heard on HomePod (AirPlay) outputs and replaces
the adaptive boost with Magic Boost and Volume Overdrive modelled on
SoundSource 6. Nothing touches core audio services: no coreaudiod change, no
HAL driver, no ARK. AOM keeps its own process taps and AUHAL outputs.

## What caused the crackle (live evidence, 3.0.14)

| Evidence | Observation |
|---|---|
| `audio-health.json` (`AOMAudioDiagnostics=1`) | Capture side healthy (Chrome transport 0 underruns); output bridge `delayedMixResets` 2, `maximumMixDelayMS` 109.6. |
| coreaudiod log | `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` for AllOfMacOS, plus a SafetyViolation on the AirPlay device at io_buffer_size 128. |
| Buffer probe (`work/probe-buffer-size`) | The AirPlay device ignores a per-process buffer size and stays at 128 frames, so a larger buffer is not a fix. |
| CPU profile | The per-sample EQ ran in a GCD timer mixer that could fire up to 110 ms late. |
| Offline A/B with the user's EQ (headroom −10.48 dB) | The zero-attack limiter flattened transient leading edges (see the table below). |

Two faults combined: a late, non-realtime mixer that reset the bridge when it
fell behind, and a limiter with no lookahead that clipped the first samples of
every transient after boost.

## Fixes

- **Realtime mixing.** The AirPlay mix moved from a GCD timer to a Mach time-constraint thread. Behind schedule it catches up in bursts of 4 blocks and only realigns after more than 1 s; it no longer clears the bridge after 100 ms. A test produced 24,480 frames in 0.5 s with a maximum delay of 0.03 ms.
- **Transparent final limiter.** A lookahead peak limiter (ceiling 0.977) replaces the zero-attack limiter. Gain falls before the peak is output, so no waveform is cut; the measured third harmonic of a sine through it is about 4 × 10⁻¹² %.
- **Block EQ.** The EQ processes blocks instead of single samples: 2.95 % → 0.62 % of one core for 10 s of stereo through 17 sections. Automatic EQ headroom stays.
- **Bounded recovery.** The stall limit is 6 s (was 3 s); automatic reconnects back off at 3, 10 and 30 s and the budget resets after 5 minutes. Capture failures are excluded, so an app that cannot be tapped is not re-muted in a loop.
- **Unchanged on purpose.** The 5 ms volume ramp stays (a 20 ms smoother broke continuity tests), master EQ stays per app, and the AirPlay IO buffer stays at the device's 128 frames.

## Magic Boost and Volume Overdrive

Behaviour was recovered from the installed SoundSource 6.0.6 frameworks
(AudioHijackKit2, SSAudio, NodeKit) with Ghidra 12.2 on a separate machine.
Only constants and behaviour were reused; no vendor code is copied.

| SoundSource element | Recovered behaviour | AOM 3.1.0 |
|---|---|---|
| `AHCompressorNode`, preset Music (push 1, speed 0, makeup 1) | Lookahead 512 frames; attack rate 0.015; release rate 5 × 10⁻⁷; maximum makeup ×100; release knee +0.1 per step up to 200, −5 on attack; threshold max(0.9, 1 − push); rates scaled by 44100 / sample rate; output (gain + 0.85) / 2 × makeup; release ×0.01 during digital silence; 40 ms toggle crossfade | `AudioMagicBoost` (`AudioDynamics.swift`), one switch for the output and one per app |
| Other presets | Movie (0.7, 0.3, 1), Voice (0.8, 0.5, 1), Radio (0.9, 1, 0.88) | Not exposed; Music is SoundSource's default |
| Volume Overdrive | Up to 400 % per app | Linear gain 100–400 % (NodeKit total gain = gain × overdrive), then a lookahead limiter at 0.995 with a 20 ms engage crossfade |
| `peak_limiter` | Lookahead 64 frames, window 12, release to 0.1 within sample rate × 0.025 frames | Informed the final bus limiter |

The 1–3 boost strengths are gone: Magic Boost is on or off, as in SoundSource.
The app volume slider is now 0–100 %; stored gains above 100 % migrate to
Overdrive.

## A/B on the user's EQ (offline, 10 s)

| Chain | Peak | Samples ≥ 0.97 | HF splatter vs EQ only | Quiet RMS |
|---|---|---|---|---|
| EQ only | 0.418 | 0 | ×1.00 | 0.0109 |
| 3.0.14: boost level 3 + zero-lookahead limiter | 0.980 | 11 | ×1.14 | 0.0271 |
| 3.1.0: Magic Boost + lookahead limiter | 0.727 | 0 | ×1.08 | 0.1060 |

Magic Boost raises quiet passages about 4× more than the old boost while
keeping peaks well below the ceiling.

## Limits

- The A/B is offline and numeric. No listening test was possible from the
  development session; confirm on the HomePod itself.
- The SoundSource presets other than Music, and its v2 PreGain-in-dB overdrive
  mapping, were deliberately not reproduced.
- AirPlay's own receiver buffering and Wi-Fi conditions remain outside AOM's control.
