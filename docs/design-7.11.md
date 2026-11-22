# AOM 7.11 — Kill Process, weather fields, panel feature menus, one-click icon, battery check

Spec: the user's "AOM 개선 작업 명세서" (2026-11-22), §1–§6. Base: `main` a8baff7 (7.10.0, build 2026112207).

## §1 Kill Process
- Launcher: "Kill Process", "프로세스 강제 종료", "강종", "kill", "force quit", "killapps" open `.killProcess`. The old screen is now **Quit App · 일반 종료** (asks the app to quit and save); "killapps" still finds both.
- `PaletteProcesses`: every process of the current user (`proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)` + `proc_pidpath`), one row per instance — name, PID, kind (App / Menu bar app / Helper / Process), owner (the outer .app of a helper, or the app a CLI process runs under), path for CLI, memory (existing footprint read). Refreshed every 3 s off the main thread; only the newest read lands.
- ↩ = "강제 종료": no confirmation, no ⌘K actions. Right before SIGKILL the PID's start time is read again; a different start time (PID reused) or a zombie is never signalled. Outcomes: ended (row removed after the process is confirmed gone, search and list kept), already ended, not permitted, still running after the request, protected.
- Protected: AOM and anything inside its bundle, Finder and the gesture-protected system apps (`PaletteAppControl.isProtected`), loginwindow, WindowServer, Dock, SystemUIServer, ControlCenter, WindowManager, NotificationCenter, MenuBarAgent, launchd, TextInputMenuAgent, universalaccessd.
- Return on this screen is ignored while the field has marked (Korean IME) text, and on key repeat (`.onKeyPress(.return, phases: .down)` already excludes repeats; `isARepeat` is checked too).

## §2 Weather
- `WeatherReading.converted(to:)`: the same observation in °C or °F (wind km/h ↔ mph); the menu bar, card and Settings use `MenuBarWeather.current` (city-matched, converted), so a unit switch shows at once and offline, and a late reply can't revert it (generation check unchanged).
- `MenuBarWeather.Field` (temperature, feels like, today's high/low, rain chance, humidity, wind) in the user's order (`AOMWeather.fields.v1`); upgrades map Temp/Feels/Icon to `[temperature]` / `[feelsLike]` / `[]`. One formatter (`line(_:fields:limit:)`) for the menu bar and Settings' preview; long lines drop their last fields, the tooltip has the whole line and the measured time.
- Weather icon menu: **Menu Bar Display…** (opens Menu Bar › Weather) and Show ▸ per-field toggles.

## §3 Panel feature menus
- `AOMFeatureMenus` (capture, clipboard, keep awake) — the panel and the Workspace cards run the same commands.
- Panel: new **Capture** tile (menu only); **Clipboard** and **Keep Awake** keep their round switch as its own click area, and clicking the name opens an inline menu under the tiles (not an NSMenu, so the icon's next click closes panel and menu together). Capture/Open History close the panel first, then run after 0.2 s. Keep Awake shows "N min left". The ✕ or a second click on the name closes the menu without running anything.
- Workspace: Capture, Clipboard and System Tools (Keep Awake) cards have a visible menu button (`AOMModuleTile(menuButton:)`) with the same commands; the right-click menus stay.

## §4 One click, one toggle
- Cause (from the code): the status button acts on mouse-up; the mouse-down made the non-activating panel resign key → `windowDidResignKey` closed it → the mouse-up's `statusItemClicked` saw it closed and opened it again.
- Fix: `AOMStatusPanelController.close()` notes when it runs with a button held over the icon; `toggleStatusPanel` consumes that once and does not reopen. A close done by the toggle itself clears the note, so fast open/close stays responsive.

## §5 Battery below 80 % — not met on this Mac
- Mac: MacBookAir10,1 (M1), macOS 27.3 (26C5047e). No SMC code, key, helper or Discharge was touched or called.
- Interface checked: PowerUI `PowerUISmartChargeClient` (the path AOM's `NativeChargeLimit` already uses; System Settings' charge limit).
  - `isMCLSupported` → true; `getMCLLimitWithError:` → 80, enabled.
  - `availableChargeLimitsWithError:` → **(80, 85, 90, 95, 100)**.
  - `setMCLLimit:error:` 70 / 75 / 60 → **NO, PowerUISmartChargingErrorDomain error 4**, state unchanged (80, enabled); 80 → YES (restored).
  - Other PowerUI entry points exist (`temporarilyOverrideMCLTargetSoC:error:`, smart charging, OBC) but none offers a lower ceiling; they were not exercised.
- Apple vs the Oracle proposal (`/data/agent-channels-gemini/telegram/delivered/reply-tg144496762.json`, "AlDente 해부 기반"): Apple's own path is 80–100 % in 5 % steps; the proposal's step 2 (60/70 % ceilings, sailing) depends on an SMC helper (`CH0B`/`BCLM`), and on this firmware the charge-inhibit keys are absent or behind a private entitlement (docs/design-6.7-launcher.md §7). AlDente's below-80 % option is SMC-based, not a macOS API.
- Result: §5 is **not met**. The UI keeps offering only what macOS accepts (80–100 %); "Hold Here" below 80 % says plainly that it charges to 80 % because macOS can't hold lower. Remaining real-device condition if a supported path appears: a battery below 70 % on AC, observed over time.

## §6 Reviews (on commit 647015d)

Reviewer A — launcher and menu bar input: the `deepseek` agent (it reported itself as Haiku 5.5 and could not confirm whether the DeepSeek bridge served it). Reviewer B — battery, regressions, deployment: Sonnet 5.5 (`claude-sonnet-5-5`). Both read-only.

Fixed:
- B: `AOM67LauncherTests` still expected "Kill Apps" and `killapps`/`강제 종료` → Kill Apps. Updated to the 7.11 rule, and Quit App no longer carries `killapps`/`kill apps` (A: two commands shared the alias), so "killapps" deterministically opens Kill Process.
- B: `build-and-sign.sh` publishes by itself (and on its first run imports old DMGs from Downloads/Desktop as prereleases) unless `ALLOFMACOS_SKIP_AUTO_RELEASE=1` — the release now builds with it set and publishes once with `publish-dmg.sh --from-build`.
- B: the version bump has to be committed before the build so `AOMSourceRevision` matches the pushed commit and `AOMSourceDirty` is false.
- B: after a kill a refresh could drop the selection onto the first (largest) row; the neighbouring row is now selected when ↩ is pressed.
- A+B: a right-click on the icon armed the reopen block; only the left button counts.
- A: Kill Process rows still opened a ⌘K action panel; ⌘K does nothing there now.
- A: Keep Awake's Turn Off uses `hasAssertion`, as `KeepAwakeService` asks.
- A: Settings' weather preview showed made-up values with no reading; it now says "Sample values".
- B: "Hold Here" from the menu bar panel gave no feedback below 80 %; it shows the message (charges to 80 %, macOS can't hold lower).

Not changed (with reason): the PID check and `kill` are not atomic (microseconds apart; the start-time check is what prevents hitting a reused PID); `[skip ci]` must be in the head commit (it is); the DMG is not byte-reproducible, so its SHA-256 is compared with the local file `publish-dmg.sh` made.

### Swarm audit (`docs/AOM-7.11-수정-및-결함-보완-명세서.md`, received during the work)
Applied: bounded reads of `pbi_name`/`pbi_comm` (a 32-character name has no NUL); more session services protected (cfprefsd, distnoted, tccd, secd, trustd, securityd, lsd, usernoted); a trackpad tap on the icon counts as a press even when the button is already up; a turned-off charge limit that reports 0/255 is "no limit", not an error; the hand-off after the panel closes is 80 ms instead of 200 ms.
Not applied: "MCL allows only a fixed 80 %" — measured on this Mac it offers 80/85/90/95/100, so the 80–100 list stays; "offline unit change shows the old unit after a restart" — the menu bar converts the cached reading, so it can't; focus restoration when the panel closes — not reproduced and the panel is non-activating, left for a real-device check; MenuBarItemID, AlDente detection, pixel-width truncation — out of this release's scope.
