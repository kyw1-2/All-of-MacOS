# 3.3.4: what happened to each 3.3.3 re-audit finding

Source: `AOM-3.3.3-재검수보고서-2026-10-30.md` (written against the installed 3.3.3, `1e4553d`),
its §3 findings N333-01 to N333-08 and the §8 follow-up conditions. Its independent tests
(`AllOfMacOSTests/Independent333AuditTests.swift`, copied verbatim in `c4dbd9b`) failed 4 of 6 on
`1e4553d`; the same file, unchanged, passes all 4 now.

Status words as in docs/release-3.3.3-audit-resolution.md: **Fixed** means the named code path is
changed and covered by new or updated unit tests; it is not a hardware pass. **HW** still needs a
person on real hardware.

Test rule for this release (the user's): only the tests that had failed and the new or changed
tests were run; tests that had passed were not re-run. Counts are in CHANGELOG.md.

| ID | Finding | Status | Commit | Tests | Left open |
|---|---|---|---|---|---|
| N333-01 (P1) | `{"password": "…"}` and `{"client_secret": "…"}` reached MCP `read_item` and content search: the inline pattern wanted `:`/`=` right after the key | Fixed | c0ee555 | `N333SecretExposureTests` (5); audit `testMCPMustRefuseJSONPassword`, `testMCPMustExcludeJSONSecretFromContentSearch` | Quoted keys (straight, typographic, escaped), camelCase names and placeholders; JSON up to 2 MiB is also read key by key (nested objects/arrays, escaped keys, JSON in strings). Not detected: secrets only in arrays or numbers, plist `<key>Password</key>`, Korean key names. False positives are fail-closed (e.g. `"token": "quick"` is hidden from MCP). |
| N333-02 (P1) | The render thread could adopt an Audio Unit host a control thread had already released (load before in-use mark) | Fixed | ec765d8 | `N333AudioEffectLifetimeTests` (6, forced interleavings through `effectAdoptionHook`) | Hazard pointers with seq_cst words; bounded retries, no wait on the render thread. ASan/TSan were not run (8 GB host, build budget); the racing test is the sanitizer target. |
| N333-03 | A suggestion request answered with what it computed after the app was excluded meanwhile | Fixed | bbf5aab | `N333SuggestionPolicyTests` (8); audit `testAsyncSuggestionsRecheckExclusionBeforePublishing` | The general answer, the model look and the paste log ask the same decision when their work lands; a refused request answers `[]`. Already published results are not withdrawn when the policy changes later (needs ClipboardPanel to watch settings). |
| N333-04 | A failed continuous write counted as written; the system-volume cache ignored the output device | Fixed | 4349a54 | `N333ContinuousWriteTests` (14); audit `testFailedContinuousWriteMustRetrySameValue` | Success-only cache, one retry after 0.25 s, the default output's device ID in the system-volume key. Device IDs, not UIDs. |
| N333-05 | Tab detach went on after a failed selection and pressed the menu without re-checking the tab and window | Fixed; HW | 21a005e | `N333TabDetachTests` (11) | Stops when the tab cannot be selected; right before Move Tab to New Window the tab must still be selected in the app's focused or main window and the request current. HW: Finder/Preview/Safari, Korean and Japanese menus. |
| N333-06 | A landing snap ran the haptic, activation and pointer warp without re-checking the pause | Fixed; HW | 21a005e | `N333SnapCompletionTests` (8) | Bookkeeping always runs; follow-ups only when generation, pause, target app pause, lock and window still allow; `bringForward` checks the pause itself. |
| N333-07 (B05) | Reset Preferences cleared nine fixed keys | Fixed | ed70709 | `N333PreferenceResetTests` (7) | `PreferenceResetRegistry`, separate from the backup list: every AOM key resets unless kept with a reason; the alert says what is kept. Services that cache settings at launch need a reopen (the report says so). |
| N333-08 (B07) | User two-finger triggers ran on touches the Dock and menu-bar gestures own | Fixed; HW | 0b69635 | `N333GestureOwnershipTests` (8) | `TrackpadUtilityGestures.claimsNow`, asked after the title-bar claim. The reverse direction (a trigger that already ran, then a utility gesture in the same touch) is not arbitrated. |

## §8 follow-up conditions

1. N333-01/02 counter-examples pass; the AU load-before-hazard order is forced in tests. Sanitizer
   runs: not done (see N333-02).
2. Excluded app, secure input and feature switch during pending work: one decision for suggestions,
   the model look and the paste log (N333-03).
3. Real trackpad checks: not done (HW items above, and docs/window-snap-3.3.4.md).
4. HomePod with active audio: the live log of 2026-10-30 (diagnostics on, music playing) showed the
   AirPlay limiter taking 2–6.45 dB in runs while AOM's queues stayed clean; 3.3.4 adds the leveler
   (docs/airplay-crackle-3.3.2.md, 3.3.4 addendum). A 20-minute listening test per state is still
   to do.
5. Real recordings: unchanged since 3.3.3, not re-checked.
6. BTT exports on devices: unchanged, not re-checked.

## Also in 3.3.4 (not in the report)

- Swipe up maximizes (N334): docs/window-snap-3.3.4.md.
- AirPlay leveler and Magic Boost near-silence floor (4f64788): docs/airplay-crackle-3.3.2.md.
- A denser main window: CHANGELOG.md.
