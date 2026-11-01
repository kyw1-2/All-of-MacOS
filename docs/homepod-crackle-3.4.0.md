# HomePod crackle, 3.4.0 addendum

Report (31 Oct 2026): "HomePod still crackles quite a lot." Follows docs/airplay-crackle-3.3.2.md (3.3.2–3.3.4).

## Live evidence (installed 3.3.8, read-only, 31 Oct 19:00–22:00)

- AOM's own AirPlay path stayed clean in audio-health.json: 0 underruns, trims, clears and drops in the bridge and in
  every app queue; mix thread realtime at priority 97, no late wakes; render cost 20.6 µs mean of a 2,667 µs cycle.
- HAL cycle gaps on the HomePod (fixed 128-frame IO, no safety offset): 71 gaps and 72 overloads in 12.6 h, each
  already faded back in (3.3.3).
- CoreAudio's own overload reports for the HomePod in 3 h (`log show`, coreaudiod analytics): about 20–30
  `ClientTimeout` dropouts in Chrome's own audio IO (reported with up to one silent 128-frame cycle),
  `SafetyViolationOccurred` for several clients at the same moments (AOM, Chrome and system sounds; about 100
  reports), and `PageFaultsOnIOThread` 6 times (Chrome and an unnamed client).
- Memory: 8 GB Mac with 5.5 GB of 7 GB swap in use and 68 MB free while several builds ran; AOM resident at only
  38 MB after 12 h (most of it compressed). No page fault was attributed to AOM itself; the wiring below is
  preventive.
- Leveler engagements are smooth gain moves (3.3.4) and not clicks.

## Causes AOM can act on

1. A dropout in an app's own audio. Chrome (and other apps) run their own IO at the HomePod's 128-frame cycle; when
   one misses a cycle, AOM's tap most likely receives a hole of exact zeros (CoreAudio reports a silent cycle; not
   verified at the tap), and AOM played both hard edges of it: a click.
2. Page faults on realtime audio threads. Under memory pressure macOS compresses or swaps out memory; an IO thread
   that touches a compressed audio buffer can miss the 2.7 ms cycle, and the HAL skips it.

## What 3.4.0 changes

- `AudioDropoutSoftener` (AirPlay routes, capture thread, no allocation): a run of 32+ exact zeros that follows
  audible audio fades out the 2 ms before it; if the run is a dropout (at most 85 ms) and audible audio follows, that
  audio fades back in over 2 ms. A longer run is a pause: its start is softened and what follows is left as it is.
  Audio without such runs is untouched. Counter: `captures.<pid>.softenedDropouts`.
- `AudioRealtimeMemory`: the PCM queue rings and work buffers, the shared resampling kernel and the softener's gains
  are wired with `mlock` (about 1 MB for the AirPlay bridge, 0.8 MB per tapped app, 0.26 MB for the kernel), so the
  IO threads never wait for memory. A refusal is counted, not fatal. Counters: `outputs.<uid>.wiredKilobytes`,
  `wireFailures`.

## What remains outside AOM

- Device-wide safety violations at the HomePod's fixed 128-frame IO (all clients at the same moment, often after a
  gPTP clock change). The device keeps 128 frames whatever AOM asks for (3.3.2 measurement).
- Heavy load on the Mac. Parallel builds and swap make every app's audio IO late, Chrome's included. Fewer heavy
  apps while listening, or the HomePod fed from an idle Mac, reduces both kinds of dropout.
- Wi-Fi and receiver glitches (AirDrop, Continuity, 2.4 GHz).

## Checking it

1. `defaults write com.kyw.allofmacos AOMAudioDiagnostics -bool true`, relaunch, play to the HomePod.
2. In `~/Library/Application Support/AllOfMacOS/Diagnostics/audio-health.json`: `softenedDropouts` counts the app
   dropouts that became dips; `wiredKilobytes` should be above 0 and `wireFailures` 0; `deviceCycleGaps` still counts
   the device's own gaps.
3. A click that still happens: look in `events` within a second of it (see the 3.3.3 listening test).

Not listened to on the HomePod in this round; the softener and wiring are covered by synthetic tests
(`HomePodCrackle340Tests`).

## Post-release correction (1 Nov 2026, not yet committed or installed)

The installed app and checkout both identify `40bff9bc0379` (3.4.0,
2026110101). At 11:10 KST, after about 85 minutes, its diagnostics showed
19,577 softened zero runs in Chrome but only 13 output cycle gaps/overloads;
app and output queue underruns, trims, clears and drops were all zero. This
counter detects waveform patterns, **not proven missed IO cycles**: ordinary
content can contain exact silence too. It cannot identify the cause of every
reported click. The 13 HAL gaps remain a separate observation.

The old softener could fade only samples within the current capture packet.
A hole at its beginning (or one recognized in the next packet) left its
falling edge untouched. A standalone reproduction with 128-frame packets,
0.5 amplitude and a one-packet hole failed the `< 0.01` sample-step assertion:
the step was 0.5. The existing tests covered only holes with enough preceding
audio and detection frames in the same packet.

The correction retains a producer-owned stereo delay of `2 ms + 32 frames`
(128 frames / 2.67 ms at 48 kHz). Recognition can now fade the preceding audio
before it is published to the concurrent PCM queue, across any packet
boundary. The delay is preallocated and wired; callbacks allocate nothing
and never rewrite consumer-visible queue storage. A per-sample recovery fade
also makes results independent of packet segmentation. All of a large
callback is processed in bounded slices; previously only its first 16,384
frames were examined. Rate/route changes and capture gaps discard pending
audio. Local output keeps the bypass. The new diagnostic field is
`captures.<pid>.dropoutLookaheadFrames` (128 at 48 kHz AirPlay, zero on local).

Verification covers all 128 offsets of a hole relative to a callback, packet
sizes 1–8,192, repeated holes, bit-exact unaffected audio after delay, quiet
signals, long pauses, stereo polarity, 8–384 kHz, reset/rate changes, and
holes beyond the transport's work buffer. The debug build and 130 selected regression tests passed with zero failures
on 1 Nov 2026, including all 9 HomePodCrackle340Tests. These synthetic checks do not certify physical
HomePod playback: after installation, listen to the same content and compare
click timestamps with `cycleGap`/`overload` events. This patch does not claim
to eliminate receiver/network gaps or reconstruct missing source audio.

An isolated optimized benchmark of the production softener processed 10,000
1024-frame callbacks (10.24 million stereo frames) in 0.0461 s, about 4.61 µs
per callback on this Mac. The benchmark substitutes only the memory-wiring
adapter, still calling mlock/munlock. This is algorithm cost, not a realtime
scheduling or whole-pipeline guarantee.
