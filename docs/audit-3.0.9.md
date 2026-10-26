# 3.0.9 — Audio distortion and recovery audit

Baseline: `7d307158a77b3e2cad48db9956f04d7880a48d2c` (3.0.8).

## Scope

Inspected the process-tap capture/ownership path, app transport, local and
HomePod output graphs, AirPlay PCM bridge, app/master DSP, effect persistence
and controls, automation audio API and preset database decoding. Enumerated
services/tests and searched exception/unfinished-code sites; ran the broad
macOS regression suite covering automation, gestures, windows, clipboard,
capture/export, persistence and system-tool logic. This does not establish
that every line or all hardware/UI combinations are defect-free.

## Confirmed findings and fixes

| Finding | Fix / evidence |
| --- | --- |
| Boosted EQ and app gain were hard-clipped per app and again after summing | Compute headroom from the combined app/master frequency response on control changes; apply it before filtering. Sum first, then use a linked stereo peak limiter with immediate attenuation, 20 ms hold and 100 ms release. No audio callback allocation or wait is introduced. |
| A reconnect can retain a UID with a new numeric device ID; stale live-source graphs prevented replacement | Tokens carry the object ID; retire vanished graphs even with old tokens and move the existing capture to the replacement output. Failed in-place recovery releases the original muting tap. |
| Capturing apps can remain muted when a local capture/output callback stops | Apply a five-second sustained-stall watchdog to local and remote sessions. An idle app is not a failure. Suppress repeated failed tap recreation until explicit retry or topology change. |
| Status used cumulative rendered frames and could report processing after rendering stopped | Track recent capture and render activity separately; expose both plus EQ/error state through scoped automation snapshots. |
| Mute All could consume an asynchronously refreshed, stale UI list | Read current app states synchronously before saving/toggling mute. |
| Automation int32 conversion could truncate fractions/wrap oversized PIDs; volume accepted Boolean NSNumber values; invalid routes silently fell back | Validate finite positive exact 32-bit PIDs before lookup, reject Boolean volume inputs and disconnected UIDs before persisting. |
| Malformed SQLite positions/shortcut values could trap during load | Validate types/ranges and throw recoverable decode errors; tests modify disposable real SQLite databases and verify rejection without deleting the file. |
| Existing boost test emulated a retired tanh algorithm | Exercise the actual AudioAdaptiveBoost compressor instead. |

Also exclude AOM's raw process ID before ownership resolution, so a launcher or
helper responsibility relationship cannot make AOM's own renderer a capture
source. This is a feedback guard, not proof that the reported transient echo
was caused by self-capture.

## Signal measurements

Production Mixer/MixerBox/AudioEQ code, 48 kHz, 1 kHz sine with 0.8 peak,
+12 dB at 1 kHz; steady-state last 24,000 mono samples:

| Metric | Before | After |
| --- | ---: | ---: |
| Samples at the clipping rail | 19,000 / 24,000 (79.17%) | 0 / 24,000 |
| Third harmonic / fundamental | 28.8517% | 0.0000093% |
| Output peak | 1.0 | 0.79208 |

Two summed 0.8-peak apps: final peak 0.98000002 (float rounding), third harmonic
0.001815%; linked stereo ratio retained. Ten +12 dB bands also pass the waveform
regression. These are digital signal measurements, not microphone recordings
or a complete acoustic/true-peak certification.

The real production capture transport -> app/master mixer -> summing bus ->
AirPlay PCM bridge is tested at both 44.1 and 48 kHz. Before headroom compensation,
app +6 / master -3 dB produced +3.000005 dB at 1 kHz. After compensation it produces
-0.086435 dB there, preserving the relative EQ curve and reserving its peak gain.
The overall level of boosted presets can be lower; this is intentional headroom.
Gain, mute, channel independence and effect retuning are also exercised.

## Live observations and limitations

- Before replacement, the installed 3.0.8 app showed Chrome capture, varying
  nonzero output level, HomePod processing active, and master EQ enabled.
- The user reported crackle persisting with EQ/boost temporarily off, then a
  transient echo; refreshing playback improved it. Therefore clipping is one
  reproduced defect, not a proven explanation of every reported artifact.
- HomePod network transport and output buffering cannot be certified by a
  software PCM-path test. Real listening, long sessions, reconnects, sleep/wake
  and multiple receivers remain relevant hardware checks.
- An initial unrestricted local test run stalled in the pre-existing interactive
  OCR integration path. The standard CI exclusions (15 OCR tests) are used for
  the broad run; any additional suite skips are reported in test output.
- Independent agy-verify review timed out without a usable verdict. No passing
  independent review is claimed; direct source review and executable evidence
  determine this release's status.
- The existing AOM Dev signing identity is retained; this is a self-signed
  development release, not an Apple notarized build.

## Local release validation

- Final source: `swift test -j 2` with the documented OCR exclusions completed
  successfully: 1,040 discovered cases, three fixture/render opt-in skips,
  zero failures (1,037 executed assertions-bearing test cases).
- The three additional skips are the two NativeUIRenderTests and the live
  two-window pin fixture test, whose opt-in paths were not configured.
- Audio/persistence focused run: 29 cases, zero failures.
- All 14 tracked shell/command scripts passed `bash -n`; `git diff --check` passed.
- App/XPC signature, DMG integrity, published asset digest and installed source
  revision are checked as separate distribution postconditions, outside this
  source-only test result.
