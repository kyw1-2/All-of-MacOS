# 7.1 — outside audit and Codex audio review, checked against the code

Inputs: an outside audit of 6.11.0/7.0.0 (pasted 2026-11-21) and Codex's audio
review (`~/Documents/Codex/2026-11-21/new-chat/outputs/AOM-오디오-검수보고서.pdf`,
raw: `…/work/results.txt`, `extra-results.txt`). Every claim was read in the
source before anything changed.

## Audio claims
| Claim | Verdict | Evidence |
|---|---|---|
| Direct AirPlay path has no final limiter | Rejected | `AirPlayDirectStream.render`: `Mixer.mix` → `AudioLookaheadLimiter` (ceiling 0.891, true peak, 150 ms release) → fade. Codex: the proposed SafetyStage overshot its own −1.5 dBFS ceiling (0.99999976 vs 0.868725 shipped). |
| Every app on AirPlay is tapped | Partly true, not adopted | Direct sessions are created only for playing or muted apps. On this Mac master EQ (Custom) and master Boost are on and Terminal is muted, so the proposed bypass would tap the same apps. Needs a measured A/B (Codex p.6). |
| Drift-compensation quality key missing | Unverified effect, not adopted | The key is omitted; its default isn't documented. Raising quality costs IO-thread CPU, the resource that is short. |
| EQ processor freed on the render thread | Rejected | `setEffects` empties the retired slots under the lock before it can create the chain the next swap needs. |
| Fade-in lost to leading silence | Rejected by me, **reproduced by Codex** on the queued path → fixed | The gap's own zeros left `run` ≥ 32, so one silent frame cancelled the fade. Not on the default direct path. |
| Wake timer not cancelled | Partly true → fixed | The `!systemSleeping` guard covered re-sleep; a quick second wake still let the first timer fire early. |

Codex additions, adopted: direct capture vs output activity (dead tap watchdog), real sample time in gap events, the 7.0 volume-track stale comparison, fan change dropping the discharge target, Top Up restore cleared before success, folder pruning limited to listed folders.

## Root cause of the crackle the user hears (measured, not fixed by code)
`audio-health.json`, 23:57–00:42: 23 overloads and 22 output gaps on Chrome → HomePod (direct), in bursts of 4–5 within ~6 s; render cost mean 31.8 µs, max 1.2 ms of a 2.67 ms cycle. At the same time: swap 9.96/11 GB, memory pressure warn, load 13–14, kernel_task 88 % (thermal), UlanziDeck 2.8 GB resident, 12 days uptime. The 6.5 measurement found the same pattern. 7.1 records these values on every overload event.

## Other claims
| Claim | Verdict |
|---|---|
| Discharge 70 ↔ 71 % loop | Confirmed (helper ticks every 5 s while the lease renews; the app's stop ran only with a battery view open) → latch + background watch |
| Battery sampling stops with the window closed | Confirmed ("forever" overstated: menu/launcher refreshes sample once) |
| Thumb wheel direction reset | Confirmed (`setEnabled` without `reversed`, line 221) |
| Hyper Key has no recovery | Confirmed for missing/invalid taps (timeouts were already re-enabled) |
| Folder stability pruned across folders | Confirmed |
| Missing token patterns | Adopted, with word boundaries and a digit requirement for `ASIA…` |
| Paste re-activation at 150/400 ms | Adopted (helps a dropped request; a refused first request still returns early) |
| PointerScroll 3-field patch | **Rejected — harmful**: pixel scroll events already carry continuous = 1 and point deltas; the patch would set the fixed-point delta to pixels (10× the system's value) |

## Deferred (separate changes, per Codex's release advice)
Auto-ducking (needs a render-time duck factor separate from stored gain, multi-PID handling), clipboard URL cleaning (some parameters are functional; terminal "safe paste" is mostly covered by zsh bracketed paste), persistent excluded apps and full-screen pause (window-size test misfires on maximized windows; the check must stay out of the event-tap hot path), per-app scroll speed (needs the application path and device identification). Cleanups: the softener heuristic is test-pinned; AudioOutputRestore's timers run only when its opt-in is on; SMC legacy keys are decided by key presence, not OS version.
