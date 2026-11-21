# 7.2 — the launcher finishes its own work

Inputs, read before anything changed:

- **Codex, 2026-11-21 09:04–09:48** (`~/Documents/Codex/2026-11-21/new-chat-2/`): the report
  `outputs/AOM-패치검수와-런치바-개선보고서.pdf`, the branch `feat/launcher-inline-tools` (3 commits on 7.1.0)
  and its UI check logs `work/ui-result.log`, `tools-ui-result.log`, `ui-more*.log`. The session ended without a
  final message; its report still had placeholders ("로컬 테스트 결과 기록 예정").
- **DeepSeek on Oracle** (`/data/work/rea/aom-ux-20261117/report/05_AOM710_런처개선_바이너리통합.md`, Telegram reply
  `reply-tg344820028`): nine launcher gaps measured on the 7.1.0 tag, from Raycast 2.13.1's front-end modules and
  22 commercial binaries.
- The user: "런치바 기능은 좀 조잡해서 별로", "홈브루 같은 것도 레이캐스트에서는 런치바에서 바로 확인 가능한데 자꾸 직접
  키는 게 너무 많아".

## Codex's 7.2 patch

| Part | Verdict |
|---|---|
| Tab asks the current model from the root field (AppKit key monitor, IME-safe) | **Kept**, generalised into `PaletteNavigationKeys` for every launcher key (Esc, ⇥, ⌘1…⌘9, ⌥↩, ⌘-/⌘=, hotkey recording). |
| Codex models from `~/.codex/models_cache.json`, `--model` passed to `codex exec` and the Terminal command | **Kept** as is (`CodexModelCatalog`). |
| Homebrew, Network Info, VPN, Spotlight, rule preview, paste queue opened inside the launcher | **Rebuilt.** They embedded the System Tools sheets (segmented pickers, Back buttons, `List`s) in the panel: ↑↓/↩/⌘K didn't reach them and Codex's own check failed on Esc from Ask AI, Homebrew Services and Network Info. Each is now a launcher screen of rows with the same footer, Actions panel and esc, and `LauncherLookups.swift` (with a `"\\(…)"` escaping bug in its status line) is gone. |
| `HomebrewModel.prepare`, the search guard, `withModalInteraction` | **Kept.** Homebrew's confirmations now ask inside the panel (`launcherConfirm`, Cancel selected) instead of an NSAlert over it. |
| Sheet `back:` parameters | Reverted (no longer used). |
| Configure Automation screen | Kept. |

## DeepSeek report 05, checked against the code

| # | Claim | Verdict | 7.2 |
|---|---|---|---|
| A | No emoji search, only the Character Viewer action | True | `:fire` in the root search (pinned), and an Emoji & Symbols screen with a detail pane. Names come from macOS's CoreEmoji tables at runtime (English and the first non-English language — this Mac is en-KR then ko-KR, so the first version found no Korean name), plus everyday Korean words for ~150 emoji (macOS has no Korean name for 🔥). ↩ types it into the app in front. |
| B | No EventKit / Contacts | True | My Schedule (7 days, Join for Zoom/Meet/Teams/Webex links) and Contacts (copy, write, call, message). Access is asked only from the screen's Allow row; root search shows events and people only after access was given; "Up next" lists today's next two events. Info.plist usage strings and the personal-information entitlements added. |
| C | Per-command hotkeys only for capture/clipboard/text capture | Partly (automations can bind keys to actions, but no launcher row could have one) | ⌘K › Set Hotkey… on commands, screens, apps, Settings pages, quicklinks, snippets and scripts. Carbon hot keys like ⌥Space; refused with the owner's name when the launcher, another row, a Capture shortcut or an automation holds the key, or macOS says another app does. A row that closes the launcher runs without the panel appearing. Listed and removable in Settings › Shortcuts. |
| D | No recent queries | True | "Recent searches" in the empty launcher (4 shown, 30 kept, a week). Choosing one puts the text back; nothing runs. Passwords and tokens (the clipboard secret scanner) are never kept. |
| E | Clipboard has search only | Partly (`type:link` existed, no UI) | Filter chips (All, Text, Links, Images, Files, Colors); ⇥ / ⇧⇥ cycle them. |
| F | No snippets / text expansion | **False**: Typed String triggers with a replacement already expand as you type (`TypedStringEngine`) | A Snippets screen over those triggers: find by keyword or text, ↩ types it, New Snippet from the clipboard or the typed text (a new typed string, so it expands everywhere too), edit, delete with confirmation. |
| G | Actions end the flow (no Send To) | True | ⌥↩ (or ⌘K › Send To…) on any row with text: type into the front app, copy, Large Type, open link / show in Finder, AI commands on the text, Google/Naver, Paste Stack, save as snippet. |
| H | No script extension | True | Script Commands: `~/Library/Application Support/AllOfMacOS/Script Commands`, Raycast's `@raycast.*` metadata read as is (`@aom.*` too): title, mode (silent/compact/fullOutput), icon, package, argument1, needsConfirmation. Asks once per script contents (SHA-256); compact/silent keep running after the panel closes and report in a HUD. |
| I | Routes fixed at 13 | Partly | Folder browsing: ↩ on a folder (Spotlight results, a file's Browse Enclosing Folder) lists it, folders first, with Enclosing Folder. |
| §4 | Filter chip, density, ⌘1…⌘9, loading indicator, edge fade, 32 pt emoji, permission empty states | Adopted | Chips (E); ⌘-/⌘= and Settings for 36/44/52 pt rows; ⌘1…⌘9 run a row where nothing destructive is listed (root, Emoji, Snippets, Clipboard, files, models, layouts, sound, contacts, schedule — never Kill Apps, Uninstall, Homebrew, confirmations), hints after holding ⌘ 0.35 s; busy headers on every loading screen; 8/10 pt fades at the list's edges; emoji drawn as the badge (22 pt in a 44 pt row — 32 pt would not fit) and 96 pt in the detail; separate "access is off" headers. |
| §4 | Action panel `scale(0.98, anchor: .bottomTrailing)` | **Rejected** | 7.0's motion rule: launcher content fades and settles, it never scales. |

Not done here, kept for later (Codex's P2 list): reasoning effort per Codex model, several files at once, a disk-space check before Homebrew upgrades, LaunchBar-style browsing of an app's menus.

## Verification

- `AOM72LauncherTests` (emoji ranking and both languages, CoreEmoji loading and the Unicode fallback, recent searches, hotkey rules/conflicts/persistence, Raycast and AOM script metadata, script trust after an edit, snippets from typed strings, meeting links, contact ranking, ⌘ digits, quick-run routes, folder order, density).
- Isolated previews of every screen with AOM's own renderer (`--aom-preview-snapshot`, no Screen Recording for another process): `--aom-preview-palette-route emoji|snippets|scripts|schedule|contacts|network|vpn|stack|rules|files:<term>|folder:<path>|brew:outdated|installed|services|search|sendTo:<text>|hotkey|newSnippet`, plus `--aom-preview-quick-run-hints` and `--aom-preview-clipboard-filter link`. Calendar and contacts show sample data in previews and never ask for access there.
- Keys (⇥, ⌥↩, ⌘1…⌘9, a recorded hotkey) were not driven from the session shell (it has no Accessibility, so synthetic keys are dropped); their decisions are the pure functions above, and they need a try on the installed app.

## 7.2.1 — Ask AI reads the Mac (user report, 2026-11-21)

Two reports right after 7.2 was installed:

1. "Haiku → DeepSeek" answered `Couldn't reach 127.0.0.1. Is Ollama running?`. Nothing listened on :8082:
   claude-code-proxy had shut down at 10:12 (`proxy.log`: "Shutting down … Finished server process") and only the
   `~/.local/bin/claude` wrapper starts it. `AOMLocalProxy` now starts it the same way when its `/health` doesn't answer
   (local addresses only, once however many questions wait), Ask AI's prewarm starts it while the question is typed, and
   the provider counts as ready whenever it can be started. The Ollama hint is shown only for port 11434.
2. Asked to find the Oracle SSH method in "other AIs' records", the model said it had no access. Native models were plain
   text in, text out. `AOMAILocalTools` gives the tool-calling wire formats (Anthropic Messages, OpenAI chat) four
   read-only tools — `search_records`, `read_file`, `list_directory`, `find_files` — and `AOMAIClient` runs up to eight
   rounds (the last without tools), showing each step under the answer.
   - Sources: `~/.agents/llm-wiki`, `~/.claude/projects/*/memory`, Claude Code `*.jsonl` (newest 400), `~/.codex/sessions`
     (newest 300), AOM's `chats.json`, `~/.zsh_history`/`~/.bash_history`, `~/AGENTS.md`, `CLAUDE.md`, `~/.ssh/config`.
     Every word must be on the line (else the closest lines), three hits per file, 30 in all, about four seconds.
   - Safety: home folder and /etc only; private keys, certificates, keychains, `~/.aws`, `~/.gnupg`, `.netrc`-style files are
     refused (in `~/.ssh` only `config`, `known_hosts` and `.pub`); `.env` lines keep their names; results pass the clipboard
     secret scanner. What is read goes to the chosen provider — the setting says so.
   - Verified live: the preview app on `localProxy:claude-haiku-5-5` searched, read `MacBook-Standby.md`,
     `Runbook-Wiki-Sync.md` and `~/.ssh/config`, and answered with `ssh oracle …` and the sources (`AOM721AIToolTests` covers
     the pure parts and starts a stand-in router).
   - Claude Code and Codex (the CLI agents) already read files in their read-only modes; Apple Intelligence has no tools yet.

## 7.2.2 — the user's cleanup, DeepSeek Harness, and the 7.2.1 audit

Inputs: the user's requests after 7.2.1 ("딥시크하네스도 저기다가 연결해줘", the System Tools items they asked to remove,
"ai요청보니까 끊기고 난리", "메인윈도우에서 글래스효과도 다시"), their answers to the remove/group questions, and the
integrated audit `AOM-7.2.1-통합감사보고서-2026-11-21.pdf` (Claude, 2026-11-21: bugs B01–B26, efficiency E01–E09,
removals R01–R10, additions N01–N09).

### Ask AI

- **DeepSeek Harness** (`AOMDeepSeekHarness`, `PaletteAIProvider.dsh`). The desktop app (`com.deepseek.dsh-desktop`)
  has no command on the PATH; its `dsh` runtime lives in `app.asar`, and its launcher has a headless profile:
  `dsh --profile headless --json [--session-id id] -- "task"` prints newline-delimited `session`, `tool_call`, `text`,
  `final` and `error` events. The app's Electron binary runs Node with `ELECTRON_RUN_AS_NODE=1`. Node can't import ES
  modules from inside an asar (every plugin failed), so the `dsh` subtree is copied once per app version to
  `~/Library/Caches/AllOfMacOS/DeepSeekHarness/<version>` (header: pickle, data at 8 + header size; links are relative to
  the archive root). `DSH_PERMISSION_MODE=read-only`; tool calls show under the answer; ⌘J opens the app.
- **Stalls.** `search_records` read Claude logs (360 MB) as Swift strings and matched line by line. It is now a byte
  scan: an A–Z lowering eight bytes at a time (271 MB in 0.29 s at -O, against 0.91 s for a byte loop, same 174 hits),
  `memmem` for the longest word, the others checked on its line. With no full line, the other words get a pass each for
  the closest lines. Newest files first across sources (B13), `\uXXXX` forms for Korean (B12), 3 s budget, six tool
  rounds, a progress line per step. `AOMLocalProxy` counts as healthy only on 200 from both `/health` and `/` (B23).

### Removed and grouped (asked one by one)

| Asked | Answer | Done |
|---|---|---|
| Force Quit · Quit All | delete | gone; stored ids become Kill Apps |
| Ping · Ports · Renew DHCP | delete | gone (Network Info stays) |
| Time Machine · Local Snapshots | delete | gone |
| Lock Keyboard · Show Keystrokes tile (and Metal HUD) | delete | gone; recordings and `aom://show-keystrokes` keep keystrokes |
| Finder display (5), Dock (3), screenshot defaults (3), repair (2) | group | one tile each with a menu of every option and its state; search still finds each option |
| Statistics tab, Large Type | demote | Statistics hides from the sidebar unless kept; Large Type is last in Send To |
| Home folder collapse | not chosen | unchanged |

R01 (seven unused views, 489 lines) and R03 (Test HUD menu item debug-only) went in without a question; E09 (no helper
process on the slow refresh) too.

### Added (N01–N03, chosen by the user)

- **N01 Batch Rename** (`BatchRename`): a sheet with presets, tokens and every new name before anything moves; any
  problem (duplicate, existing file, empty, `/` or `:`, too long) blocks the set; case-only renames go through a
  temporary name; a failed move puts the earlier ones back (B02); Undo in the toast. `{n}` without text to find now
  numbers the files (B07).
- **N02 Compress PDF**: *Keep Text* (`PDFDocumentWriteOption.saveImagesAsJPEGOption` + `optimizeImagesForScreenOption`,
  macOS 13+) and *Pages as Images* (now 150 dpi, B04) are both made in a temporary folder and shown with sizes; the
  saved one is "Name (compressed).pdf", then "(compressed 2)", never over a file (B03). Merge names unreadable or
  locked PDFs (B05).
- **N03 Folder Rules**: preview items that would run get checkboxes, Select All and Run on N Selected
  (`FolderRulesEngine.runSelected`). The click is the approval; each item is re-read and must have the same volume and
  inode as in the preview (`FolderRulesRunner.isSameItem`) and still match, else it is left alone and counted.

### Audit bugs fixed here

B02, B03, B04, B05, B07 (above), B11 (a script's password argument is typed into a secure field and never shown in the
row title), B12, B13, B23, and B24: `HIDKeyMapping.plan` remembers the pairs AOM's own displaced (Caps Lock → Escape
replaced by the Hyper key's Caps Lock → F18) and puts them back when AOM lets the key go, but only while the key still
holds AOM's pair.

Not done in 7.2.2 (a later pass): B01, B06, B08, B09, B10 (P1/P2 outside launcher and AI), B14–B22, B25–B26, E01–E08,
N04–N09. B01, B06 and B08–B10 went into 7.2.3 (below).

### Verification

- `AOM722Tests` (16): DeepSeek Harness arguments, environment, events and asar extraction; byte scan, escaped Korean
  and the lowering against a byte loop; removed and grouped tools; rename plan, problems, rollback and Undo; both PDF
  compressions (text kept / not), free names, merge reporting; picked-item identity and the run message; B24's plan and
  give-back. `AOM721AIToolTests` updated for the closest-lines pass. Full suite: 390 tests, 0 failures, 17 skipped.
- Real records: the debug build read 4 of 289 files in the 3 s budget (unoptimised byte loop), which is why the word
  lowering went in; the release core reads 271 MB in 0.3 s.
- Previews: System Tools without the removed tiles and the sidebar without Statistics. The glass needs the desktop
  behind the window, which AOM's own snapshot can't show; the code path (no stored setting → on → behind-window
  material, 62 % page tint) was checked, the look itself only on the installed app.

## 7.2.3 — the audit's remaining P1/P2 file and record bugs

The five items 7.2.2 left (B01, B06, B08, B09, B10), each read in the report and checked against the 7.2.2 code before
changing it. B01, B06 and B08 were reproduced on the 7.2.2 tree (adapted tests: Undo moved the other file; Convert
Video returned without an error after writing nothing, and after leaving an existing file as it was; the damaged
`sessions.json` was replaced with no copy kept). B09 and B10 can't be driven from a test on 7.2.2 (the chat history
has no file under tests, `runTransfer` was private) and were confirmed in the code, as the report also marks them.

- **B01 Shelf Undo** (`FilesTransfer.Move.identity`). Move To and the Trash record the device and inode of the file at
  its new place (`FolderRulesSafety.identity`, the check Folder Rules has made since 6.4.0). `moveBack` refuses a
  missing file, a different file under the name, and a taken old place, in that order. An in-place edit keeps the
  inode and still comes back; an app that saves by replacing the file makes a new inode, and Undo then refuses — the
  safe side, within the toast's few seconds.
- **B10 partial Shelf actions.** The Undo closure is set whenever something moved, even with failures; the message
  reads "Moved 2 of 3 items to X. Couldn't move “c” … because …". Undo matches results to shelf items by id
  (`ShelfMove`), not by path. Undo of Remove (`itemsToRestore`): a received file that came back returns as it was, one
  whose old place was taken keeps its item pointing at the file in the Trash, one that is gone stays off.
- **B06 Convert Video.** `export(to:as:)` (back-deployed to macOS 10.15 in the SDK) throws on `.failed` and
  `.cancelled`; the deprecated `export()` returns either way, hence the warning. The export goes to an
  `itemReplacementDirectory` on the destination's volume, must be non-empty with a video track, and then replaces
  (`replaceItemAt`) or moves into the destination. The save panel's Replace now works: AVFoundation won't write over a
  file, so before it failed and said "converted".
- **B08 Focus files** (`FocusStorage.loadChecked`). Missing starts fresh; undecodable is moved to
  `<name>.unreadable-<date>.json` first; unreadable (permissions) or not movable blocks saving. `FocusLogStore`,
  `FocusListsStore` and `FocusActivityStore` use it, and the Focus page shows a notice with Show in Finder, as Folder
  Rules does for `rules.json`. The timer state file still starts fresh (it holds no history).
- **B09 AI chats** (`AOMLatestWriter`). One serial queue per file and a generation counter: each write takes the next
  number; when its turn comes and a newer one exists, it is skipped; encoding happens on the queue. The newest list is
  always written last. Not changed: deleting the chat that is open in AI Chat and then starting a new one saves it
  again (the open conversation is saved on New Chat); that is a separate follow-up.

### Verification

- `AOM723Tests` (14): B01 a different file under the name is left alone, an in-place edit still comes back; B10 the
  partial move keeps Undo and moves the one file back, a blocked Undo says where the file is and the shelf keeps it,
  the messages, Remove's per-item restore from a stand-in Trash; B06 an unwritable folder throws and writes nothing, an
  existing file is replaced with a real MP4 (a ten-frame H.264 movie made with `AVAssetWriter`), a non-video throws;
  B08 a damaged log is set aside and survives the next save, an unreadable one is never saved over, lists and activity
  too; B09 a save held mid-write while a delete and a newer save queue behind it ends with the newest list, and the
  superseded write is skipped.
- Full suite: 404 tests (390 + 14), 0 failures, 17 skipped. On the 7.2.2 tree the adapted B01, B06 (two) and B08 tests
  showed each bug.
