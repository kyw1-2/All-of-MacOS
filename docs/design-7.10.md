# AOM 7.10 — Bartender 7 menu bar on macOS 27

## Why

The user on 7.9: the ❮ hid nothing, the Bar didn't work, the Arrange lanes had boxes around icons, and the settings were not as kind as Bartender's — "I don't even know how to operate it". They asked for Bartender 7's features and UI as they are, using DeepSeek's report of the day.

## Sources

- Oracle `/data/work/rea/aom-ux-20261117/report/07_Bartender7_역공학명세_AOM갭.md` (DeepSeek, 2026-11-22): Bartender 7.2.0 structure, mechanisms, gap table against AOM 7.2.2.
- Bartender 7's own nibs, decoded on Oracle (`json/Bartender_nibs3.json`) and read with `strings` for the ones not decoded: `MenuBarLayoutPreferences`, `MenuItemsPreferences`, `HotKeysPreferences`, `AdvancedPreferences`, `Base.lproj/GeneralPreferences`, `Welcome.storyboardc`, `SearchWindow`, `BartenderBarWindowController`.
- Bartender 7's `INTEGRATION.md` (pages `BartenderLayoutView`, `BartenderGeneralView`, `BartenderBarSettingsView`; status item toggles hidden items or the Bar; show-and-click with auto-hide that waits for menus).
- Measured on this Mac (27.3): status items no longer appear in `CGWindowList` (the menu bar is one Window Server window), so empty space is found with an Accessibility hit test.

## Bartender pane → AOM

| Bartender 7 | AOM 7.10 |
|---|---|
| Welcome: Setup, Authorization (Accessibility, Screen Recording), how to access | `MenuBarSetupGuide` — 3 pages, live permission ticks, opens the first time |
| Menu Bar Items (layout): title, 2 lines, 3 strips 60 pt right-aligned, New Items pill, paragraph, Preset row | `MenuBarLayoutEditor` — same order and wording (⌘-drag line adapted: on macOS 27 it reorders, sections are per app) |
| Menu Items (outline per app, "Menu bar item should:", search name) | `MenuBarItemSettingsList` |
| General: show when click / scroll / hover + delays, automatically rehide, Bar, menu bar icon, spacing, show all on big screen | `MenuBarGeneralPane` + `MenuBarTriggers` |
| Bartender Bar settings | `MenuBarBarPane` (at mouse, leave + delay) |
| Hotkeys: show hidden, show all, quick search, keyboard navigate, item hotkeys with activation | `MenuBarHotkeysPane` + `MenuBarHotkeys` (Carbon keys through `PaletteHotkeyStore`) |
| Advanced: ⌘-drag shows all, temporary-show delay, Bar when no room | `MenuBarAdvancedPane` |
| Presets with "Remove Applied Preset" | `MenuBarPresets` (default layout kept while a preset is applied) |

## Not done (Bartender has it)

- Triggers (app focus/launch, image change, power, time, display), profile hotkeys and automatic profiles.
- "Show for updates": macOS 27 removes a hidden app's icons entirely, so there is no picture to watch; an AX-title poll would be a guess.
- Menu bar styling (tint, rounding, gradient), Minimal mode, notch bar, Top Shelf, widgets.
- Compatibility hiding (Control Center approvals) and per-system-item hiding: AOM keeps one method and never edits another app's approvals.
- Gap/spacer items in the palette, AppleScript dictionary, hiding on inactive menu bars.
- Moving icons between apps' order from Settings on macOS 27 (only ⌘-drag in the menu bar reorders).

## /simplify review (4 reviewers)

Fixed: one global monitor with a mask built from the settings (pointer moves only while hover is on), cached menu bar bands, AX hit test on a background queue with 0.25 s timeouts, app-menu width cached per front app, launches coalesced (0.4 s), one sections read per scan using the tested placement policy, the clock hand-off moved into the same monitor (a second global monitor removed), the busy check short-circuits before reading the window list, shared AX helpers (`AOMMenuShelfProbe.attribute/frame`), synthetic clicks tagged with `SyntheticInput` and ignored by the monitor, `AppMetadataCache` for app icons, one `MenuBarHider.reveal(_:section:then:)` for the Bar and hotkeys, one chevron builder for both hiding methods, one hover setting, shared rehide choices, settings re-read when defaults change, one home per setting, merged hotkey rows.

Deferred: a `HidingBackend` protocol and a single "reveal reasons" state instead of the parallel save/restore paths; one timer for the lift and the rehide countdown; a prefix registry for launcher hotkeys; moving the Hider's statics into `MenuBarPrefs`; a shared shortcut-recorder helper (five copies exist outside this diff).

Orphans (periphery 3.8 on a native SwiftPM index, kept only names that occur once in all Swift code): 20 dead constants/properties, `AOMMenuEditorSection`, and `AOMWorkspaceGreeting` (kept alive only by its own test since 6.0 dropped the greeting). Type-level hits (BatteryCare, SMC, SystemTools result structs) are referenced from other files or targets and were left.

## Gemini review (AI Studio, Gemini 4 Neon, Thinking High, new chat "AOM 7.10 코드 검수 결과", ~39k tokens of raw code)

Fixed (checked against the code first):
- Triggers were started before ❮ existed, so `reconfigure()` returned early and nothing was installed until a setting changed; the wide-display rule was also lost at launch.
- Global monitors miss events sent to AOM itself; a local monitor now feeds the same handler.
- A Bar opened by hover closed under the pointer (AOM's own panel never counted as busy); the Bar's own leave timer now decides.
- Setup page 3 had no way out without Accessibility, and unticking "Do not show this again" was ignored.
- The first drag to Hidden changed nothing visible (icons were showing); a move out of Shown now hides at once.
- Hit-test answers arriving after the pointer left still revealed; custom icons with nested groups counted as empty space (the ancestor chain is checked now, on one serial queue).
- `showTemporarily` could lose its click to an app-launch re-hide; a lift is marked before the request, and a second click on a shown app restarts its time.
- Changing icon spacing restarts MenuBarAgent; the restriction is now asked for again.
- The clock hand-off didn't bump the request generation, checked only the first display's clock, and had no positions until Settings was opened (a quiet read now runs after start).
- App-menu width fallback mixed absolute and relative X; popover detection assumed the main display.
- Chevron hover ignored the hover delays; a second ⌘-drag within 1.2 s was cut short; "Show All" did nothing while Hidden icons showed; the Show All hotkey didn't toggle.
- Item hotkeys after a restart couldn't find a hidden app's icon (its app is let back first); a missing fresh position fell back to an old one that might be another icon; changing the click type could lose the key; recording left every key suspended if AOM went to the back.
- A wide display's "show all" was collapsed by the rehide timer after changing its time.
- Reset layout left a preset applied; the Bar and Advanced panes didn't follow changes made from ❮'s menu.
- White glyphs on light menu bars; strips scrolled from the left; the hovered app's other icons now light up (they move together on macOS 27); the Bar toggle is back in the Bar pane.
- Scrolling ignored momentum and natural scrolling. (Also found while fixing: scroll fields were read on every event type, which can raise for mouse events.)

Disproved or not changed:
- "Clock" detection depending on the macOS language: it comes from the item's Accessibility identifier.
- Item hotkey keys: they already store the stable key (`stableKey ?? pinKey`).
- "❮" in help text when another icon is chosen, a hidden-icon mode, hotkey hints in ❮'s menu, Triggers: left for later.

## Verified / not verified

- Unit tests: `AOM710Tests`, `AOM710BartenderTests`, `AOM79Tests`, `StudioIdentityTests` pass locally; the full suite runs on GitHub CI before release.
- Panes rendered with `--aom-preview-menubar-sample --aom-preview-menubar-tab <pane>` (and `--aom-preview-menubar-setup`) in light and dark.
- Not verifiable from this shell (no Accessibility trust): the empty-space hit test's roles on macOS 27, hover/scroll/⌘-drag in the real menu bar, item hotkey clicks. The installed app runs `--aom-menubar-selftest` for hiding itself.
