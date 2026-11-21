# AOM 7.3.0 — what the two reports asked for, and what was done

Sources (2026-11-21):

- **Codex**: `~/Documents/Codex/2026-11-21/new-chat-5/outputs/AOM-7.2.3-통합검수와-개선보고서.pdf` — the review of the DeepSeek design against 7.2.2/7.2.3 code, with reproduced bugs and five delivery bundles (P0 file safety, P0 AI scope, P1 launcher and input, P1/P2 modules and shelf, P2 scenes).
- **DeepSeek**: `~/Downloads/AOM-7.2.2-통합설계-v2-멘션게이팅-스니펫-모듈스위치-20261121.md` = Oracle `/data/work/rea/aom-ux-20261117/report/06_AOM722_설계_v2_수정판.md` (Ghidra/REA inventories of Input Source Pro 2.14.0, Yoink 3.7.6, Bunch 1.4.19, Espanso 2.4.1; strings only, no decompilation), and the 14-item review in Telegram reply tg344820029.

Where the two disagree, Codex's correction (it read the code the design was written against) is followed and the difference is noted below.

## Taken

| Report item | 7.3 | Where |
|---|---|---|
| Codex P0-1 Batch Rename Undo moves another file (reproduced) | device+inode per move, Undo and roll-back check it, failures listed; RENAME_EXCL | `Services/MacMagic/BatchRename.swift`, `Views/Files/FilesTools.swift` |
| Codex P0-2 PNG/JPEG/HEIC overwrite (reproduced; 7.2.1 B03) | temp file + exclusive rename to a free name, WebP too | `MacMagicSystemToolService.convertImage`, `commitExclusive` |
| Codex P0-3 corrupt shelf / AI chats | `AOMCheckedFile` (FocusStorage's 7.2.3 policy, generalised) | `Services/Focus/FocusStorage.swift`, `FilesShelf.swift`, `PaletteAI.swift` |
| Codex rec. 1 file activity | session log, Undo once, failures with reasons | `Services/Files/FilesActivityLog.swift`, `FilesActivitySection` |
| DeepSeek 12 / Codex P0 AI scope | per-question `AOMAIRecordScope`; tools/schemas/prompt from the scope; executor re-checks; empty ≠ all; `@ssh` = config+known_hosts | `Services/AI/AOMAIRecordScope.swift`, `AOMAILocalTools.swift`, `AOMAI.swift` |
| DeepSeek v2 fix 1 (proxy is external) | `AOMAIEgress.loopbackProxy` leaves the Mac; Ollama on-device only on loopback with a non-cloud model (Codex: Ollama can run cloud models) | `AOMAIRecordScope.swift` |
| DeepSeek v2 fix 2 (tool name merge) | tools derived from the scope's names, each once | `AOMAILocalTools.tools(for:)` |
| Codex receipts / history | `AOMAIReceipt` under each answer; held turns after a provider switch | `PaletteAI.swift`, `AOMLauncherAI.swift` |
| Codex P1 folder browse (reproduced 2,400 → 2,000) | background listing, all items sorted, ticket, paging, search over all, error kinds | `PaletteLauncherData.swift`, `QuickCommandPalette+Screens72.swift` |
| DeepSeek 13 / Codex snippets | `SnippetTemplate` (syntax 2 opt-in; old snippets literal), 3 insertion routes, changeCount restore, launcher field form, preview | `Services/Palette/SnippetTemplate.swift`, `KeyboardMonitor.swift`, `TriggerListPanel.swift` |
| DeepSeek TOP3-1 / Codex badge | `InputSourceChangeHub` shared with the automation trigger; AX caret → pointer; 200 ms duplicate merge; manual switch cancels the rule's re-apply | `Services/InputSources/InputSourceBadge.swift`, `TriggerSystemSignals.swift`, `AppInputSourcesModule.swift` |
| DeepSeek 14 / Codex modules | `AOMModuleSwitches`; real stop for Files (pilot), Folder Rules, Text Actions, Focus (idle apps, reminders; refused during a session), Mic Mute (never changes the mic), Input Sources; Screen Ruler/Click Hints gate only (their start() is empty); launcher essential | `Services/AOMModuleSwitches.swift`, each module |
| DeepSeek TOP3-2 / Codex shelf | per-item drop reading (URL else promise), receive batch, all files drag out, one shared mouse monitor, batched relocate, hide-after-drag-out option | `FilesShelfPanel.swift`, `FilesFileDrag.swift`, `FilesShelf.swift` |
| DeepSeek TOP3-3 / Codex scenes | `SceneProfile` + `ScenePlanner` + `SceneRunner`; order apps → windows → audio/appearance/Keep Awake → Focus → quit; UID → kind+name → name; preview; Run Failed Steps; cancel | `Services/Scenes/AOMScenes.swift`, `Views/Scenes/ScenesSheet.swift` |
| Codex rec. 4 shortcut finder | `PaletteHotkeyStore.usages` + route `.hotkeyFinder` | `PaletteHotkeys.swift` |
| Codex rec. 5 folder favorites (N05) | `PaletteFolderFavorites` | `PaletteLauncherData.swift` |
| Codex efficiency table | rename date, record-search budget, mdfind streaming top-K, shelf monitors/relocate, DNS/Wi-Fi off main, script hash cache (stat), typed-string preparation, output line cap, cancel-before-start, Focus encode on queue, large-file top-K, extension signing once | see CHANGELOG |
| 7.2.1 audit leftovers | B14, B15, B17, B18, B19, B20, B21, B23 | see CHANGELOG |

## Deviations from the DeepSeek design (and why)

- **Empty shelf and mouse events.** v2 §6.2 says `ignoresMouseEvents = true` while the shelf is empty. A window that ignores the mouse also refuses drops, so the empty shelf opened by a shake could not take the file (Codex p. 7). The shelf keeps taking the mouse; only the badge ignores it.
- **⌘V fallback to typing.** v2 §4.5 types the text once more when a paste fails. Codex: when it isn't clear whether the paste landed, typing again can insert it twice. 7.3 falls back only when the ⌘V event couldn't be sent at all.
- **@mac.** v2 lets @mac read every source. Codex: other AI chats, shell history and SSH need a choice of their own. @mac is wiki + memories + agent instructions.
- **Scene DSL** (Bunch's `launch:`/`audio:` lines) is not built; Codex: after the UI model settles. macOS Focus (DND) isn't switched; the scene starts AOM's own Focus timer.
- **Snippet field timeout (30 s)**: the launcher form waits for you; Esc cancels.

## Left for later

- The Telegram review's other proposals (menu bar hiding, memory/swap watchdog, meeting countdown, OCR → Translation, browser tab search, notch HUD) were not part of the v2 design or the Codex review.
- Codex B22 (IDE vs release bundle inventory), B25 (key-mapping state captured before the queue), B26 (recording clean-up restart): acceptance-environment checks, not reproduced here.
- Launcher icons loaded for visible rows only; a "more results" progress row for Spotlight file search.
- Module switch effect on idle CPU/RSS is not measured; Codex's comparison method (three 60 s idle runs per state) applies.

## Verified

- `AOM73Tests` (29) plus the 7.2.1–7.2.3 suites for the touched code (AOM721AIToolTests, AOM722Tests, AOM723Tests, AOM72LauncherTests, Palette/Files/Focus/TypedString) pass locally; the full suite runs on GitHub CI.
- UI checked with `--aom-preview-snapshot`: Records for the Next Question, the Ask AI scope row (Apple Intelligence and Local Proxy), Find a Shortcut, Window Tiling's Scenes card and sheet (`--aom-preview-scenes`).
- Live: claude-code-proxy's `/health` and `/` bodies, used for the B23 check.
- Not checked on the device: the badge's caret position in each app, snippet insertion in VS Code/Electron, a scene's real audio and appearance switch, TCC prompts.
