# AOM 6.4 — DeepSeek round 2 and the Codex audit

2026-11-18 · base 6.3.3 (`33a67c5`)

Inputs:
- DeepSeek, Oracle: `/data/work/rea/aom-ux-20261117/report/02_상용앱2차_바이너리분석_통합.md` (Telegram reply tg344820025).
  Ten apps in Ghidra: SoundSource 6.2.0, Pearcleaner 5.4.3, LinearMouse 0.13.0, Shottr 1.10.0, Stats 3.1.0,
  Alfred 5.8.1, KeepingYouAwake 1.6.8, BetterTouchTool 6.1152, Raycast 2.12.1.0, CleanShot X 5.0.2.
- Codex, MacBook: whole-app defect audit, `~/Documents/Codex/2026-11-18/aom/outputs/`.

Rule for every item: it goes where the user already looks for that job, it reuses the screen that
job already has, and it copies the reference app's behaviour, not its chrome.

## DeepSeek items

| # | Reference | Item | Decision | Where |
|---|---|---|---|---|
| B11, B16 | Alfred `AlfredKnowledgeManager sortResults:withQuery:`, Raycast `rootSearchEntryMethod:invokedAt:` | ⌘K learns from use | **6.4** | The palette. The row picked for a query comes first next time (Alfred); rows of equal match quality order by decayed use, one-week half-life (Raycast); an empty palette opens with up to five Suggestions once a row was used twice. Rows keep their section colour; "Forget This Suggestion" in the row menu. Momentary rows (calculator, clipboard, captures, fallbacks, latest file) are never learnt. Item IDs and short queries only, in `AOMPaletteKnowledge.v1`. Entry method was left out: AOM opens ⌘K from one hotkey and the menu panel, too few paths to rank by. |
| B19 | Stats `keep_menubar_positions` | Menu bar items keep their place | **6.4** | Each AOM status item has its own autosave name; without one macOS keyed positions by creation order, and the Focus and microphone items, which come and go, shuffled the others. |
| B18 | KeepingYouAwake (Amphetamine is App Store only) | Keep Awake conditions | **6.4** | System Tools › Keep Awake menu, a new "Automatically" section: While an External Display Is Connected; Let the Mac Sleep on Low Battery (10/20/30/50 %). Switching to another user ends Keep Awake (KYA). A rule-started session says "Display connected" on its tile and ends with the display. |
| B1 | SoundSource `hiddenSourceTabs` | Hide apps from the mixer | **6.4** | Row menu "Hide from List" in the mixer panel and on the Audio page. Hidden apps leave Favorites, search still finds them, Show All lists them under Hidden. Audio processing is unchanged. |
| B4 | Pearcleaner `checkOrphanedFiles` | Data of removed apps | **6.4** | Free Up Space › Removed Apps: ~/Library entries named after a bundle ID that no installed or running app (or parent ID) has, unchanged for 7+ days. Nothing is preselected (helpers and frameworks share IDs). |
| — | CleanShot X "the following conditions may break the scrolling capture" | Say what breaks scrolling capture | **6.4** | ⓘ beside the scrolling capture status line. |
| B5 | Pearcleaner sentinel | Always-on orphan watcher | Not adopted | An all-day file watcher for a monthly chore; the scan runs on demand. |
| B2 | SoundSource drop errors | Four drop-failure reasons | Not adopted | AOM's mixer has no drop target; apps are added through an open panel that only offers apps. |
| B3 | SoundSource overdrive | Volume overdrive | Already in AOM | `AppAudioPreferences.overdrive`, up to 400 %. |
| B6 | LinearMouse HID acceleration + restore | — | Already in AOM | PointerEngine with `AOMPointerAccelerationRecovery`. |
| B7 | LinearMouse event-thread scrolling | — | Already in AOM | `PointerScroll` timer. DeepSeek's own correction: display-link pacing is Mos only. |
| B8 | LinearMouse `AXEnhancedUserInterface` | — | Already in AOM | WindowManager and TitleBarWindowSnap toggle it. |
| B9, B10 | Shottr toolbar order, window policy | Customisable capture toolbar | Later | The Quick Access overlay's buttons are a fixed CleanShot set; an order editor needs its own design pass. |
| B12 | Alfred debug channel | Extension debug log | Later | AOM has no extension runtime yet (round 1 F5). |
| B13 | BTT preset bundles, duplicate policy | — | Partly in AOM | The BTT importer already reports name clashes; bundle formats need a sample file to test against. |
| B14 | BTT `NextUnusedGestureID` | — | Not needed | AOM triggers use UUIDs. |
| B15 | BTT action category badges | — | Already in AOM | 6.1–6.2 rows show the input's mark and the action line. |
| B17 | Raycast exclusive launcher | — | Later | Needs an audit of every AOM panel's show path first. |
| B20 | Stats combined popup | — | Already in AOM | The menu bar panel (6.0). |

## Codex audit

See the 6.4.0 changelog entry for what was verified and fixed. Found while it ran:
- Enable Trigger / Disable Trigger posted a request nothing received: the action reported success and
  changed nothing. `AppState.applyTriggerSelector` now handles it.
- `AllOfMacOS.xcodeproj` is stale (417 sources missing, a deleted file referenced). Releases and CI
  build with SwiftPM, so shipped builds were unaffected.
