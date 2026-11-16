# AOM 5.0 — Studio

2026-11-16 · base 4.0.0 (`4951442`) · main window, Settings window, ⌘K palette, HUDs

## Why

Through 4.x every tool in AOM drew the same outline symbol in the accent colour: the sidebar, the
Explore cards, page headers and row icons all looked alike, so eleven tools read as one undifferentiated
list (see the 4.0.0 screenshots: blue on grey everywhere). The pages themselves were already dense and
consistent after the 4.0 slim pass; what was missing was *identity* — knowing at a glance which tool you
are in and which you are about to open — and a place where each page says what you can do next.

## References and what was taken

| App | Pattern studied | Applied in 5.0 |
|---|---|---|
| Raycast ("A fresh look and feel", Action Panel manual) | Bottom action bar: left = where you are + toasts, right = contextual actions with their shortcuts; ⌘K Action Panel grouped into sections; coloured command icons | `AOMActionBar` under every page; `AOMActionPanel` (Run / Go to / All of MacOS, ↑↓ ↩ Esc); palette rows wear coloured marks |
| System Settings (macOS 26) | White glyph on a coloured squircle for every pane and row; pane header with its icon | `AOMAppIcon`, sidebar rows, page headers, setting rows, Settings window sidebar and rows |
| Loop / Luminare (PR #918: coloured sidebar icons, brighter sections, fewer animations) | Coloured sidebar icons that match system apps; no decorative motion | Sidebar identity marks; motion only on hover lift (Reduce Motion respected) |
| BetterTouchTool (configuration overview: App list → trigger categories → actions → config side bar) | Trigger categories as the entry point | Empty Automation page becomes a gallery of the five input kinds |
| Paste (pinboards with colours, card shelf) | Colour as a way to tell collections apart at a glance | Module hues identify tools in cards, quick actions and the palette |
| Swish (live tooltips, haptics, "native feel") | HUD that shows the state in a readable mark | `AOMHUDContent` glyph becomes a tone-coloured squircle |
| Bartender / Ice / CleanShot menus | A control header with the app's state and master switch | Sidebar header: brand mark, Running/Paused, master switch |
| Arc / Raycast home | A welcome band with greeting and state | Workspace banner: greeting, brand gradient wash, one line of state |

These are interpretations of public material, not copies of any app's artwork.

## Rules

1. **Colour has a fourth job: identity.** Each destination has a fixed symbol + hue (`AOMMainTab.identity`,
   `AOMIdentity.swift`). Workspace alone uses the brand gradient (indigo #544EE3 → magenta #D93F96).
2. **Controls never take a module hue.** Switches, selection, prominent buttons stay on the system accent;
   status keeps semantic colours with glyph + words.
3. **One mark component.** `AOMAppIcon(identity, size:, active:)`: white filled glyph at 52 % of the side, continuous
   squircle (22.5 % radius), top-lit hairline, hue-tinted drop shadow from 28 pt, grey fill when off
   (no filter layers), solid edge under Increase Contrast.
4. **Sizes.** Row 20 · bar 18 · card 34 · header 40 · hero 52 (`AOMIcon.identity*`).
5. **Rows inherit the page.** `AOMRowIcon`, `AOMModuleBadge(symbol:)`, `AOMModeButton` and `AOMEmptyState` read
   `\.aomPageTab` (set by `AOMPageHost`) and draw in that page's hue; outside the main window they are graphite.
6. **Every page ends in the action bar.** Identity + name + tagline on the left; related tools (marks only,
   names in tooltips), Actions, Search ⌘K on the right. Search left the toolbar (it was the third copy).

## Implemented

- `AOMIdentity.swift` — identities, brand colours, `AOMAppIcon`, `AOMRowIcon`, page-tab environment, taglines,
  Settings category identities.
- `AOMActionBar.swift` — action bar, action-panel model, popover panel with keyboard navigation.
- Sidebar: control header (brand mark, Running/Paused, master switch), 34 pt search field, identity rows
  (Automation's mark goes grey while AOM is paused), Settings footer with keycap.
- Page header: 40 pt identity mark (opt-out `identity: false` for headers inside editors and detail panes).
- Setting rows: System Settings row icons in the page hue; divider inset follows (10 + 20 + 10).
- Empty states: 52 pt mark in the page hue, Title 3 heading.
- Workspace: brand banner with greeting and state replaces the slogan; the "AOM is running" card shows
  only when something needs you (paused, permission, recording) or in My Workspace; Explore cards get
  marks, a hue wash and a hover lift; quick actions become coloured marks.
- Automation: the empty page lists Trackpad, Keyboard, Mouse, Drawing and Other as cards.
- Capture: mode buttons are capture-hued marks (Record keeps red).
- ⌘K palette: navigation rows use the destination's mark, Settings rows their category mark, commands
  their tool's hue (by id prefix), other sections a section hue.
- Settings window: coloured sidebar and row icons (rows use the tint each row already declared).
- HUDs: tone-coloured mark.
- Preview hook `--aom-preview-actions` opens the Actions panel for screenshots.

## Verification

- `StudioIdentityTests` (7 tests): unique symbols, SF Symbol availability, distinct hues in light and dark,
  action-bar related tools and quick-action ownership, panel sections, greeting by hour.
- Screenshots of Workspace, Automation, Window Tiling, Capture, Clipboard, Audio, System Tools (light),
  Workspace / Window Tiling / System Tools (dark), the palette, the Actions panel and Settings in the
  isolated preview (`--aom-ui-preview`).

## Not changed

Specialised editors (annotation, equalizer internals, automation action editor), clipboard shelf panel,
engines and data formats. Hues of yellow/amber rows keep white glyphs at about 3:1 (large-glyph threshold),
as System Settings does.
