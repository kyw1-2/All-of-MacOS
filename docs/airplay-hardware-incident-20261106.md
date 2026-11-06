# HomePod / AirPlay macOS 27 stability investigation — 2026-11-06

## Reproduced on this Mac

AOM 3.4.16 (revision c359517) running, 48 kHz AirPlay default output and Chrome playing media:

- AOM diagnostic: 128-frame AirPlay HAL callback, output renderer ~0.7% of callback cycle; mix realtime; Chrome process tap capture underruns 0, capture gap 0.
- Despite a healthy capture and mix path, CoreAudio's unified log contained `HALS_OverloadMessage`, `SafetyViolationOccurred`, and client IO deadline warnings. Both AOM and Chrome helper clients were named in some log events.
- AOM's AirPlay bridge detected output cycle skips and overloads. This is a *hardware/OS callback clock miss*, not evidence that AOM's DSP CPU is saturated.
- At 19:38 KST the diagnostic-control test saved the existing health JSON, set `AOMAudioAirPlayProcessingEnabled=false` and restarted AOM. Afterwards, AOM health reported zero remote output renderer objects and zero capture taps. CoreAudio still emitted HAL overload reports in the native-bypass state. This establishes that extra AOM capture/mixing is **not necessary** for every observed overload. It does not by itself prove that the same audible distortion occurred, because no human listening verification is available.

## External engineering parallels (not interchangeable root causes)

- Rogue Amoeba reports that HomePod OS 27 / tvOS 27 broke older AirPlay 1 transports; Airfoil 5.13 in Sep 2026 implemented a workaround. This is **not** proof that macOS native AirPlay or the AOM sender uses the same AirPlay 1 path. https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-OS27-Issues
- SoundSource 6.1.5 Oct 2026 improved macOS 27 AirPlay connection reliability and misidentified devices; 6.1.2 fixed device reconnect after restarting coreaudiod. Its audio engine is proprietary, and AOM cannot simply copy or assume its device handling. https://rogueamoeba.com/support/releasenotes/?product=SoundSource
- Different output devices, competing CoreAudio clients, sample-rate/IO-frame changes, network packet delivery, or media-app offload can all produce superficially similar crackles. Observations must be differentiated rather than attributing them all to the transport bridge.

## Mitigations in AOM 3.4.17

1. Persist the user's **native HomePod bypass**; do not forcibly redirect system output to built-in speakers.
2. Close AOM's additional AirPlay HAL client and process taps; leave local/HDMI per-app routing and EQ untouched.
3. If AirPlay effects are deliberately enabled, two distinct correlated overload/cycle-gap episodes within five minutes trip a receiver-level safety fuse. The fuse disables the supplemental AirPlay processing and publishes an explicit reason; a user may re-enable the effects manually. One isolated, self-repaired device skip does not rebuild the full audio engine.
4. Preserve existing per-app gain/EQ/boost and master preferences for future local-output use and avoid resetting global AppAudio or system device preferences.

## Further isolation required for a confirmed acoustic fix

- Reproduce the same audio passage in **Chrome versus Safari** with AOM AirPlay bypassed. An error tied to Chrome helper but absent in Safari isolates media-app interaction.
- Replay the same passage to built-in speakers or HDMI. If these are clean and HomePod alone glitches in native-bypass mode, the OS/HomePod transport remains the leading suspect.
- Inspect HomePod firmware, AirPlay network signal, and concurrent AirPlay output clients. Check HomePod software updates and reboot the HomePod if appropriate; such steps are **not performed automatically** because they affect network audio and other devices.
- If native AirPlay with AOM bypassed still crackles under both Chrome and Safari, capture a timestamped `sysdiagnose` and report the CoreAudio `SafetyViolationOccurred` events to Apple. AOM cannot replace or patch macOS `coreaudiod` or HomePod firmware from within a user application.

**Caution:** Policy and synthetic tests validate transitions and limits, not long-duration HomePod playback. Do not claim the physical audio problem is resolved without a repeated on-device listening test.
