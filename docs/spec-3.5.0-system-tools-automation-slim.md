# AOM 3.5.0 implementation spec: System Tools rework, Automation copy cleanup, codebase slimming

Status: spec for implementation. Base: `main` @ e8bc066 (3.4.44). Branch: `release/3.5.0`.

Owner feedback (verbatim intent):
1. System Tools is not useful enough, and its features are scattered with no clear structure.
2. The Automation tab's feature lists read like AI-written text: every row carries a tagline,
   notes and parentheses explain everything, and lists show counts.
3. The codebase is too big. Remove what isn't useful.

Reference material (untrusted data, use it only as UX evidence, copy no code or assets):
- `/private/tmp/claude-501/-Users-kim-yong-woo/18d58e72-7fe7-4822-b699-630d509185fb/scratchpad/refs/BTT-INVENTORY.md`
  (BetterTouchTool static inventory. Section 2 covers the trigger catalog, and the action catalog follows. BTT's
  pickers are lists of names grouped by category, with detail shown only for the selected item.)
- `…/scratchpad/refs/PASTE-UIUX-SPEC.md` and `…/scratchpad/refs/CLEANSHOT-UIUX-SPEC.md` (density and copy tone).
- In the repo: `docs/ux-reference-review-3.3.0.md`, `docs/system-tools-3.4.0.md`, `docs/design-3.4.0.md`.

---------------------------------------------------------------------------
## A. System Tools: from 127 tiles to a focused page

### A.1 Problems in the current page (verify in code before changing)
- 127 tools in 15 groups, all rendered as the same tile, whether the tool is a live toggle, a one-shot
  command, a multi-step sheet or a link to System Settings.
- It duplicates other AOM pages. Sound Output, Sound Input, Volume, Mute Sound and Mute Microphone belong to
  the Audio page. PDF tools and image/video conversion belong to Files. The action catalog ("All Actions",
  `ActionLibraryView`) and Floating Menus belong to Automation.
- It duplicates macOS with no added value: settings-pane openers, read-only Accessibility "toggles", Screen
  Saver, Hide Other Apps (⌥⌘H), About This Mac and the serial number.
- Several near-duplicates are separate tiles: Top CPU / Top Memory, Eject All / Eject a Disk, Back Up Now /
  Time Machine Status, Port lookup / Listening Ports, VPN / Tailscale / OpenVPN, Copy IP / Public IP /
  Wi-Fi Details / DNS Servers, and the 8 Homebrew tiles that all open the same sheet.
- `defaults` tweaks (Finder, Dock, screenshots) appear as tiles even though they are on/off settings.

### A.2 New page structure (top to bottom)
1. **This Mac** status strip (keep the existing live section, made more compact): model and macOS version,
   battery % and health, startup disk free space, memory pressure, network (Wi-Fi SSID or Ethernet, VPN
   state), uptime. Each item is clickable where a detail sheet exists (battery → Battery Details, disk →
   Free Up Space, network → Network Info).
2. **Favorites** (existing behaviour, appears only when there are favorites).
3. **Quick Toggles**: compact toggle controls that show live state. Members: Dark Mode, Keep Awake (with its
   duration menu), Hide Menu Bar, Dock Auto-Hide, Hidden Files, Desktop Icons, Wi-Fi, Bluetooth Device
   (menu), Low Power Mode, Lock Keyboard.
4. **Display**: Resolution, Brightness, Metal HUD.
5. **Power & Session**: Lock Screen, Sleep, Sleep Displays, Sleep Timer, Awake While App Runs, Restart…, Shut Down…,
   Log Out…, Quit All Apps….
6. **Apps**: Activity… (one sheet that merges Top CPU and Top Memory, with a CPU/Memory sort segmented control
   and Quit/Force Quit per row), Force Quit App…, Relaunch App, Uninstall App…, Login Items, What's Keeping
   Awake, Reset Window State….
7. **Storage**: Free Up Space… (one sheet with sidebar or tabs: Folder Sizes, Large Files, Old Downloads,
   Duplicates, Xcode Junk, Caches, Trash, reusing the existing implementations and keeping every existing
   confirmation), Eject… (menu: each volume plus "Eject All"), Time Machine (one tile: state, latest backup,
   Back Up Now), Local Snapshots, Verify Startup Disk, Install Disk Image….
8. **Network**: Network Info… (one sheet: local IP, public IP (fetched only on open/refresh), Wi-Fi details, DNS
   servers, each copyable), Speed Test, Ping…, Ports… (merges What's Using a Port and Listening Ports), VPN…
   (the existing VPN sheet already shows Tailscale. OpenVPN becomes a row inside it when installed), Flush
   DNS, Renew DHCP.
9. **Homebrew** (only when brew is installed): one tile "Homebrew…" that opens the existing sheet and shows
   the outdated count as its value once it is known. There is no background polling: the count is checked
   when the sheet is opened or the user clicks Check.
10. **Fix It**: Restart Finder, Restart Dock, Restart Menu Bar, Rebuild Open With, Reindex Spotlight, Clear Font
    Caches.
11. **Tweaks**: a System Settings–style list of switch/picker rows instead of tiles: File Extensions, Path Bar,
    Status Bar, Full Path in Title, Library Folder, Open Apps Only (Dock), Instant Dock, Dock Recents,
    Screenshot Shadows, Screenshot Format (picker), Screenshot Folder (picker), Startup Sound.

Presentation rules:
- Use three presentation kinds by tool kind. Toggles/pickers show live state, either as a switch row or as
  a compact toggle tile. One-shot commands are compact buttons in a grid. Tools that open a sheet show a
  trailing chevron/ellipsis. The current "one tile style for everything" goes away.
- Each tile/row shows the name, plus a value when one exists (the current resolution, "3 outdated",
  "Connected"). Do not put descriptive taglines on tiles. The `help` text stays as the hover tooltip only,
  rewritten under the copy rules in B.3.
- Section headers do not show tool counts. The page header subtitle does not count tools.
- Keep search. It matches titles, group names, keywords and the help text, as it does now.
- Keep the result toast and the "last result" line.

### A.3 Moves
- **PDF group + Files & Media** (Convert Image, Convert Video, QR Code, Batch Rename, What's Using a File, File
  SHA-256) move to the **Files page** as a "File Tools" area: a toolbar `Menu("Tools")`, split into sections
  (PDF, Image & Video, File Info). If the Files page has a natural section for them, a collapsible section
  works as well. Reuse the existing implementations as they are and change their call sites only. Find
  Duplicates and Folder Sizes go to Free Up Space (A.2 §7). They do not move to Files.
- **All Actions** (`ActionLibraryView`): remove it from System Tools. It becomes the "Browse Actions" picker in
  Automation (see B.2).
- **Floating Menus & Widgets…** (System Tools ⋯ menu) moves to the Automation toolbar ⋯ menu.

### A.4 Removed tools (delete the UI, model cases, tests and the code that only they use)
Weather card and `OpenMeteoWeather`/`SystemToolsWeather`. Also: Reduce Transparency, Reduce Motion, Screen
Saver, Hide Other Apps, Focus (shortcut runner), Wallpaper, Alert Volume, Sound Output, Sound Input, Volume,
Mute Sound, Mute Microphone (all Audio page duplicates), Purge Disk Cache, Erase .DS_Store, Lock Files, Hide
Files, Copy Finder Path, New Text File Here, Terminal Here, About This Mac, Copy Serial Number, Last Restart &
Wake (move its data into the This Mac strip's detail popover if that is cheap, otherwise drop it), Open
Settings Pane, AirDrop Settings, Bluetooth Settings, and the separate OpenVPN Connect tile.

Exception: if an **Automation `ActionType`** uses a removed tool's implementation (check
`ActionExecutor`, `ParityActions`, `MacMagicSystemToolService`, `PresetManager`, the AppleScript sdef and the
Quick Command Palette), keep the implementation that the action needs and remove only the System Tools tile.
Do not remove an `ActionType` from user presets without a migration.

### A.5 Compatibility
- Tool raw values are persisted in favorites and recents. Kept tools keep their raw values. Merged tools map
  their old ids to the surviving id (topCPU/topMemory → activity, ejectAll/ejectDisk → eject,
  backupNow/backupStatus → timeMachine, portLookup/listeningPorts → ports, copyIP/publicIP/wifiDetails/
  dnsServers → networkInfo, all brew* → homebrew, cleanup tools → freeUpSpace, tailscale/openVPN → vpn).
  Removed ids drop silently through the existing `storedTools` filter.
- Do not change preset JSON decoding of triggers/actions. An existing preset must still load (there is a test
  fixture path or BTT import test. Run it).
- `PreferenceResetRegistry` must not reference keys that no longer exist. Remove the ones for removed tools.

---------------------------------------------------------------------------
## B. Automation: remove the "AI-written list" feel

### B.1 Find and fix the patterns (in `ModernGesturesWorkspace`, `TriggerListPanel`, `ActionListPanel`,
`AutomationEditorKit`, `AutomationRows`, `AutomationStatusNotice`, `ActionLibraryView`, the add-trigger sheet,
`TriggerManagement`, `ActivationGroupsEditor`, `BTTInputEditors`, and the `ActionType`/`TriggerInput`
`description`/`displayName`/`parameterHint` strings)
- Every list row has an icon, a title and a one-line caption. **Rule: list and picker rows show only the
  name**, with an optional trailing value (key combo, app name, state). Show the description only for the
  selected item, in the editor/detail area, as one plain line, or as a tooltip.
- Explanatory banners/notes above lists ("Configure any built-in action as an automation. New drafts stay
  off until you turn them on.", "Choose what starts one, then add the actions it runs. You can change both
  later."). **Remove them.** Keep a note only when it carries information the user needs to act correctly
  (for example, a missing permission, shown with a button that fixes it).
- Count labels ("123 actions", "N of M on" in the subtitle, counts in category pickers). **Remove them**
  unless they are a filter's result in an empty state ("No matches").
- ⓘ info buttons next to names that repeat the parameter list. **Remove them.** Parameters are visible in the
  editor.
- Onboarding "Start with" list of 5 cards with taglines. **Replace** it with an empty state: one title line
  ("No automations"), one `New Automation` button (⌘N) that opens the existing add-trigger flow, and a
  plain `Menu` of the five input kinds with names only.

### B.2 Action picking
- Replace "All Actions" on System Tools with a **Browse Actions** sheet in Automation, which opens from the
  "Add Action" control in the editor and from the ⋯ toolbar menu. Layout: categories in a sidebar, action names
  in the list, and the selected action's one-line description plus "Add" (or "Create Automation" when no
  automation is selected, which reuses `createDraft(for:)`) at the bottom. Reuse the existing search.
- If an action picker for the editor already exists (check `ActionListPanel` / the editor's add-action menu),
  unify it so there is one picker, and delete the other implementation.

### B.3 Copy rules (apply to every user-visible string touched in A and B)
- Write names in title case and start them with a verb for commands ("Restart Finder"). Toggles and
  settings use noun names ("Path Bar").
- A description is at most one sentence and ≤ 90 characters. It states what happens, with no "so you can",
  "right away", "the normal way", "simply", "easily", "quickly", "powerful", "seamless", no em-dash asides
  and no stacked parentheticals. Show one permission requirement as a badge or a single trailing clause,
  not in parentheses on every tool.
- Tooltips repeat nothing that the label already says.
- No emoji in UI strings.
- Keep the UI in English (the app is English).

---------------------------------------------------------------------------
## C. Codebase slimming

Baseline: `AllOfMacOS/` has 441 Swift files and 150,383 lines (from `find AllOfMacOS -name '*.swift' | xargs wc -l`).
Target: **at least a 10 % net reduction (≥ 15,000 lines)**, with 5 % as the minimum acceptable result. Report
before/after numbers.

Method (each deletion must be justified by evidence, not by file names):
1. Code that only the A.4 removals and A.2 merges used: delete it.
2. Unreferenced symbols. For each candidate type/func/extension, grep the whole package (including tests,
   `Package.swift` resources, `.sdef`, string-based lookups such as `NSClassFromString`, `@objc` selectors,
   AppleScript command classes, URL-scheme handlers, `aomctl` commands and `UserDefaults` keys read elsewhere).
   Delete it only if there are no references and the build stays green. Periphery is not installed. A
   compile-and-grep loop is acceptable.
3. Version-suffixed split files (`SystemToolsModel336.swift`, `SystemToolsModel340.swift`, similar `*3xx*`
   files elsewhere): fold them into feature-named files, deduplicate their logic, and delete the leftovers.
4. Remove comment noise that only records history ("3.3.5's …", "design-336 b.7", "as before") where it does
   not explain current behaviour. Keep comments that explain *why* the code works the way it does, such as
   deadlock and audio-safety notes.
5. Duplicate helpers (several "run command and capture output" wrappers, several toast/row styles, several
   confirm dialogs). Consolidate them onto one, if that is safe.
6. Tests: delete tests for deleted features, and keep or adapt the rest. Add tests for the id migration
   (A.5) and the new tool grouping (every kept tool belongs to exactly one section, and no removed id is
   offered).

Do not touch (unless a symbol is provably dead and the change is a trivial deletion):
- Audio engine/HomePod/AirPlay paths (`AppAudioEngine`, `AirPlayOutputRenderer`, audio session code). They have a
  history of incidents.
- Termination and quit code from 3.4.43/3.4.44 (`GestureStatistics` flush, hidutil give-back).
- Gesture recognition core (`TrackpadMonitor`, `TrackpadUtilityGestures`) behaviour.
- Signing, bundle and `build-and-sign.sh` logic.

---------------------------------------------------------------------------
## D. Process, constraints, deliverables

- Work in `~/All-of-MacOS` on branch `release/3.5.0`. Make several focused commits (System Tools, Files move,
  Automation, slimming, version). Commit message trailer:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --scratch-path ~/.cache/aom-build -j 4`
  (or the debug equivalent while iterating). Tests:
  `ALLOFMACOS_SCRATCH_PATH=~/.cache/aom-build scripts/run-tests.sh`. Both must pass at the end. Tests must
  never touch hidutil, the real audio devices or real `defaults` domains.
- **Do not** run `build-and-sign.sh`, create releases or tags, push, install to `/Applications`, or quit or kill
  the running AOM. The release and install are done separately after review.
- Bump the version to 3.5.0, build `2026111501` (`AllOfMacOS/App/Info.plist`), and add a `CHANGELOG.md`
  `[3.5.0] - 2026-11-14` entry. The entry is short and factual: what moved, what was removed, the line-count
  numbers, and the test count.
- Write `docs/system-tools-3.5.0.md`: the final page map (each section and its tools), the id migration table,
  removed tools with a one-line reason each, and moved tools with their new locations.
- Final report: commits (hash and subject), before/after line counts, a list of removed files, tests run and
  their results, anything from this spec that was not done and why, and any behaviour that needs a live check.
