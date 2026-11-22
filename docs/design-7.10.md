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

## Gemini review

See the section added after the AI Studio review.

## Verified / not verified

- Unit tests: `AOM710Tests`, `AOM710BartenderTests`, `AOM79Tests`, `StudioIdentityTests` pass locally; the full suite runs on GitHub CI before release.
- Panes rendered with `--aom-preview-menubar-sample --aom-preview-menubar-tab <pane>` (and `--aom-preview-menubar-setup`) in light and dark.
- Not verifiable from this shell (no Accessibility trust): the empty-space hit test's roles on macOS 27, hover/scroll/⌘-drag in the real menu bar, item hotkey clicks. The installed app runs `--aom-menubar-selftest` for hiding itself.
