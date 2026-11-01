# HomePod continuity audit — 3.4.6, 2026-11-01

## Observed failure and what it establishes

The installed 3.4.5 executable identifies source `8369aca72b556f701645f4a62cbb6384d17c86d0`.
Its diagnostic snapshot covers 1,792.7 seconds starting at 16:37:56.993 KST:

- Four device-clock gaps: 284, 256, 268, and 256 frames (1,064 total).
- Four overloads, four automatic failures/restarts, 25 tap attachments and 20 detachments.
- No source/output queue underruns or trims; the active output callback averaged 18.4 µs
  (0.7% of a 128-frame cycle), with a maximum mix wake delay of 0.1585 ms.
- Gap events at 16:41:49.964, 16:43:33.781, 16:56:24.388 and 17:05:34.956.
  Output restart events followed roughly 1.1–3.2 seconds later, before tap reattachment.
- `coreaudiod` reports simultaneous AOM/Chrome faults, including `SafetyViolationOccurred`
  and negative IO budgets. This establishes a shared device scheduling failure, not whether
  the underlying cause is CoreAudio, receiver firmware, clock synchronization or Wi-Fi.

A temporary private output-only aggregate accepted a 1,024-frame request but read back 128
while running, with zero safety offset/latency. An AudioQueue silent probe also ran with
128-frame physical IO. Both probes stopped and disposed their resources. Neither experiment
establishes a safer backend, so neither was adopted. Default output and installed app were
not replaced. A larger software queue cannot retroactively fill a hardware cycle already missed.

## Reproduced AOM defects and changes

1. **Hidden extra PCM consumption:** `clockSkipFrames` advanced the source cursor, then
   `crossfadeHeldTail` pulled another fade-length of samples. A 448-frame skip actually
   consumed 688 extra source frames at 48 kHz, while diagnostics reported only 448.
   The regression failed in all 18 combinations of six gap lengths and three rate ratios.
   The exact-skip path now fades out the already-held tail and fades in the new timeline
   without pulling a replacement tail. Ordinary backlog trims retain their crossfade.
2. **Missing capture packets were spliced together:** the IO block discarded input sample
   timestamps. Buffer underflow counters and exact-zero detection cannot detect an entirely
   absent packet. Valid consecutive timestamps now identify short holes up to 85 ms; the
   producer inserts that exact interval, shaping both edges in its private lookahead before
   publication. Longer jumps and backward clocks reset the stream. Arrival-time jitter alone
   never inserts samples. Route/rate generations reset timestamp history.
3. **Capture evidence was absent:** `captureGap`, `captureClockReset`, and monotonic source
   counters distinguish missing input packets from exact-zero content and output device gaps.
   A separate preallocated SPSC event ring preserves the consumer ring's single-writer rule.
4. **One tiny shared fault destroyed a working stream:** isolated faults now remain in place.
   Three independent overload/gap episodes within ten seconds qualify for bounded recovery;
   duplicate, stale, startup and counter-reset evidence cannot accumulate. Existing six-second
   stall checks, disconnection handling and per-device recovery budgets remain active.
   This is a recovery policy, not a claim that restarting repairs macOS's shared clock.
5. **Transient property read failure was treated as disconnection:** only a successful
   `DeviceIsAlive == 0` read declares loss. Unknown reads preserve playback; the stall watchdog
   remains the fallback.
6. **Futile device writes remained at setup/reconfigure:** remove physical HomePod buffer-size
   writes altogether. Read actual IO size and adapt the bridge. Capture-only aggregate buffer
   configuration remains separate.

## Validation

Debug compilation and linking passed. The skipped-frame regression first failed 18 assertions
against the unmodified implementation. The broad audio run executed 133 tests; its sole failure
was an old assertion equating an unknown liveness read with disconnection. After updating that
assertion and adding two edge/route tests, all 51 tests in the five affected suites passed.
The latest results across the twelve exercised suites cover 135 distinct passing tests, zero
outstanding failures. This includes EQ/boost/true-peak dynamics, effect lifetime, clock drift,
queue races, output handover, missing capture packets, 1-frame holes, and exact clock skips at
48, 44.1 and 96 kHz output ratios. `git diff --check` and Info.plist syntax validation passed.

The synthetic tests validate source-frame accounting, waveform continuity, source timestamp
handling and recovery decisions. They do not establish that shared HAL safety violations have
ceased, or that the physical HomePod is free of all audible artifacts. A post-build installation
and extended listening run are still needed to assess that outcome.

## Public API basis

Input audio timestamps come from `AudioDeviceIOBlock`/CoreAudio. Apple's tap documentation
explains the tap-to-aggregate capture path; the SDK headers define the timestamp flags and
aggregate-device properties used by the probes:

- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://developer.apple.com/documentation/coreaudio/kaudiosubdeviceextraoutputlatencykey

These API references describe supported mechanisms; the defect and runtime conclusions above
come from the local tests and logs, not from a claim that Apple documents this specific failure.
