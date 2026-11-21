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
