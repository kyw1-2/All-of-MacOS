# Audio session and output lifetime repair — 2026-10-25

Base revision: `8077562`. Reported symptom: a video stops roughly one second after playback starts. This change addresses concrete lifetime defects in that revision. The reported runtime symptom has not been reproduced or verified in this task.

## Source findings

- `syncActiveProcesses()` runs every second and formerly destroyed live taps when settings returned to unity/bypass. Playback lifetime and processing settings were coupled.
- The shared renderer still attached and connected a new AVAudioSourceNode for every app. Pooling AVAudioEngine instances did not make its graph stable.
- Only the first source was inserted in a graph's source registry. Subsequent sources were not counted. Session destruction did not remove any source from the renderer, retaining transports and their closures.
- Device fallback changed dictionary keys without migrating tokens and could overwrite a graph already serving other apps.
- Browser helper process membership was saved at session creation but never updated.
- Failed capture attempted device creation again every five seconds. Repeated device churn could continue while the user was trying to play media.
- Mute-all tore down every tap. Gain/EQ/mute changes should be control changes on existing streams.

These are source observations. They do not independently establish which defect caused the user's specific player to pause.

## Implementation

A hardware output now owns a single permanent 48 kHz stereo source node. App membership changes a preallocated software summing bus, leaving the engine's graph intact. Individual source removal waits for an in-flight render to finish; capture and rendering are both stopped before session resources are released. Idle graphs remain available until shutdown or physical device removal, which deliberately keeps their output stream open.

Live sessions survive silence, bypass, unity gain and mute changes. Helper changes update `kAudioTapPropertyDescription` in place. On macOS 26, bundle matching and process restoration also arm configured apps before their first audio process exists. Earlier macOS versions wait for process objects without treating a quiet app as an error.

Output migration changes the render consumer while preserving the capture tap. All sources from a failed graph are detached before it is rebuilt, avoiding partial recovery with multiple apps. Graphs remain keyed by their real hardware UID; unrelated graphs cannot be overwritten by fallback routing. Audio-engine configuration notifications attempt recovery for real hardware format changes.

The transport converts the capture rate into the fixed render rate and bounds latency after a capture interruption or stalled output. DSP coefficients use the actual render rate. Both per-app output and the final sum are finite and bounded. Silent callbacks clear meters. Silence is shown as waiting for playback, not proof of denied recording permission.

Capture/start failures restore the original output and remain visible until explicit reconnect or a real process/output topology change. Automatic periodic retries no longer repeatedly create and destroy the same failed devices.

## SoundSource / ARK evidence and limits

- Official ARK description: https://rogueamoeba.com/support/knowledgebase/?product=SoundSource&showArticle=Misc-ARK-Plugin-Audio-Capture-Details
- Official SoundSource permissions: https://rogueamoeba.com/support/manuals/soundsource/?page=Permissions
- Apple tap API: https://developer.apple.com/documentation/coreaudio/catapdescription
- Local Xcode SDK `CATapDescription.h` documents macOS 26 bundle IDs and process restoration; `AudioHardware.h` documents that `kAudioTapPropertyDescription` modifies an existing tap.
- Existing server evidence: `/home/ubuntu/work/soundsource/ss.rea.json`, artifact SHA-256 `b03ae2a6b4a3ea4bef8eb488c6219424024001de9214f438f320e0eaa78e82ec`, evidence ID `ev_7fc78f0ada1df46a4e36849f83c233662991702425373c42f566e7f0d84f9dfc`. Its sole analysis record decompiles the app entry point. It provides no ARK audio-path implementation evidence.
- The installed SoundSource package includes ARKManager and other audio frameworks. Their presence/strings do not establish a supported third-party integration API. AOM does not load, copy or claim to implement ARK.

AOM's existing per-app gain/mute, saved output routing/fallback, boost, per-app/master ten-band EQ, closed-app settings and audio automation use the repaired lifecycle. This is not a claim of complete SoundSource equivalence: third-party Audio Unit hosting, SoundSource's proprietary processing algorithms and headphone correction profiles are outside this change. The existing boost is AOM's own effect.

## Validation

At the user's explicit request, no build, test suite, runtime playback check, post-change review or installation was performed. This commit is implementation only. No error-free runtime or complete SoundSource parity claim is made. Push, release and installation are left to the user.
