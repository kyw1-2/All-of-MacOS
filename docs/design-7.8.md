# AOM 7.8.0 — Codex menu bar & window spec, launcher themes

Source: Codex, `~/Documents/Codex/2026-11-22/aom/outputs/AOM-메뉴바-윈도우-UI-통합-기능명세서.pdf` (10 pages, against 7.7.0 / 788ac52), plus the user's request of 2026-11-22: the launcher was too faint ("투명도도 너무 옅고") and had no themes, unlike Raycast's.

## Launcher themes

`Services/Palette/AOMLauncherTheme.swift`: `AOMLauncherTheme` (13 presets: system, light, dark, midnight, graphite, ocean, forest, plum, ember, paper, mint, rose, sky), `AOMLauncherMaterial` (frosted / glass) and `AOMLauncherAppearance` (theme, opacity 0.3–1, default 0.68; keys `AOMLauncherTheme`, `AOMLauncherOpacity`, `AOMLauncherMaterial`; reloads on `.aomSettingChanged`).

- `AOMLauncherSurfaceModifier` (AOMCraftTokens): frosted = `NSVisualEffectView(.hudWindow, behindWindow, active)` with a rounded `maskImage` (`VisualEffectBackground.cornerRadius`), the theme's tint at the opacity on top; glass = `glassEffect(.regular)` + tint (macOS 26+). Reduce Transparency / Increase Contrast: the tint opaque. The modifier sets `colorScheme` for fixed themes and two environment values, `aomLauncherSelection` (row fill: the accent at 17/24 % or the neutral fill) and `aomLauncherOpaqueBase` (the Actions panel).
- `AOMLauncherController.applyAppearance()` sets `panel.appearance` (aqua/darkAqua/nil), so the launcher ink (dynamic NSColors) resolves for the theme; `AOMLauncherThemedRoot` applies the theme's accent as tint/accentColor.
- Theme screen: `PaletteRoute.themes` (`Views/Launcher/QuickCommandPalette+Themes78.swift`) — themes with swatches, six opacity steps, two materials. Selection previews (`AOMLauncherAppearance.preview`); leaving the screen or closing the launcher drops the preview. Opens on the current theme. Root command `launcher.screen.themes`; preview flag `--aom-preview-palette-route themes`.
- Settings › General › Launcher: theme picker (+ Try in Launcher), opacity slider, material.

## MB-01 — containers are walked

Codex's AX read of macOS 27 `com.apple.MenuBarAgent`: 6 children = 2 `AXLiveActivity` (pressable) + 4 `AXHostingView` (no name, no actions), each holding `AXMenuBarItem/AXMenuExtra` (description + identifier, `AXShowMenu`/`AXPress`). This session's shell has no Accessibility trust, so the shape comes from Codex's probe output (its session log), encoded as the test fixture.

- Pure `AOMMenuExtraFlatten.items(_:maxDepth:)` over `AOMMenuExtraNode`: a direct child that is pressable or named stays; a container is walked (depth 3, first pressable/menu-extra per branch, images and plain groups skipped); a cut-short walk sets `truncated` (→ the app counts as read in part); an empty container stays one row.
- `AOMMenuShelfProbe.flatItems(pid:)` reads only containers deeper (budget 60 reads/app). Snapshot, `activate` and the launcher's `PaletteMenuBarItems` all use it; open = `AXShowMenu` when offered, else one `AXPress`; `resolve` still refuses an ambiguous target.
- `AOMMenuBarIdentity.identify` names Apple's items by identifier (or an exact description): Battery, Sound, Control Center, Clock, Wi‑Fi, Bluetooth, Focus, … with SF Symbols. `baseName` falls back to the app name when the title is a changing value; `detail` keeps the value.

## MB-02 — the person's name, symbol, group

`AOMMenuBarAliasStore` (`AOMMenuBarItemAliases`, JSON) keyed by `AOMMenuShelfItem.stableKey`: `bundle|ax:<id>` (unique identifier), `bundle|sys:<function>`, or `bundle|desc:<steady description>`; nil (no editing) for a changing title with no identifier. Never the ordinal or the frame. Editor: `Views/MenuBar/MenuBarItemEditor.swift` (row, glyph, popover with name, group, 40 symbols, Restore Default). Shown in the Menu Bar page, Shelf, Strip, launcher. `AOMMenuShelfController.open(stableKey:)` rescans and opens only a single match.

## ME-01…03 — AOM's menu

`Services/MenuBar/AOMStatusMenuLayout.swift`: `AOMMenuCommandCatalog` (Workspace quick actions, launcher/window/settings, automation, HUD, clipboard stack/pause, keep awake, snap, shelf/strip/reveal all, App Audio engine/mixer, Scenes by UUID, named menu bar items by key); `AOMStatusMenuLayout` (version, revision, `menu: [Entry]?` with one level of groups, `panel: [String]?`, `panelPerRow` 1–4); `normalized` (no leading/trailing/double separators, no empty groups, no missing commands); `starter` from Workspace's quick actions (ME-03); `AOMStatusMenuStore.save(_:basedOn:)` refuses a stale revision; `restoreDefaults`.

- Right-click/⌥-click: `AppDelegate.makeUserStatusMenu()` — Stop Recording first while recording, the person's entries, then All Commands (the 7.7 menu as a submenu), Edit Menu…, Quit. Until a menu is applied the 7.7 menu shows (now with Edit Menu…). The panel's ⋯ is always the full menu.
- Click panel: `AOMStatusMenuStore.panelCommands()` (Workspace order while `panel == nil`), `quickPerRow`, a pencil to the editor.
- Editor `Views/MenuBar/AOMMenuEditorView.swift` (window via `AOMMenuEditorNavigation.open()`, and Menu Bar › AOM menu): add list with search, order with up/down/remove/group/separator, rename and group picker, a preview that only selects. Pure edits in `AOMMenuDraftOps`.

## HB-01 — not hidden while in use

`MenuBarHider` rehide is a 0.5 s timer: busy = pointer in the menu bar band, any window at the pop-up menu level, or a mouse button down; busy restarts the countdown (`MenuBarRehidePolicy`).

## WIN-01 — the window lets the colour through

`AOMTranslucency.Level` subtle / balanced (default) / clear: page tint 0.62/0.55 → 0.32/0.30 → 0.16, card 0.82/0.72 → 0.60/0.55 → 0.46/0.42, blur `underWindowBackground` (subtle) or `sidebar`. Codex's 7.7 numbers (margin 8, card 2 out of 255, light) imply the old blur passed ~10 %; `passThrough` models the stack, and with a conservative 25 % for the sidebar blur Balanced clears the spec's ≥ 20 / ≥ 8. **Not re-measured on screen**: repeated screen capture from this session triggers macOS 27's private-window-picker prompt, so the blue/orange test should be re-run from Codex or by hand.
- `AOMPageTint` replaces the shared dynamic `pageBackground` colour in all 13 places; it observes the switch and the level, so Settings changes apply to the open window. Settings explains when Reduce Transparency / Increase Contrast is forcing solid. FolderRulesPage's second tint removed.

## UI-01 — rounded corners

`AOMCardSurface` clips content to the card's continuous shape when the padding is under 0.6 × radius (cards of rows) — `.paper` and `.well`; shadows stay in the background layer, padded cards keep free content. Fixed spots: AnnotationEditor layer rows, MenuBarStrip panel and chips (continuous shape, `strokeBorder`, clipped scroller), Menu Bar Shelf rows.

## Still open from the spec

- MB-02 "AOM 바로가기로 고정" (an AOM status item standing in for another app's item), per-item shortcuts, "최근 추가" for new icons.
- HB-02/03: below-the-bar expansion as a Hider mode (the Strip covers the gesture), first-run wizard, per-OS "real hide supported" matrix.
- ME: drag-and-drop ordering (buttons now), per-entry display conditions, live sessions inside the editor's preview.
- AC-03 profiles (Scene/display-driven menu switching).
- UI-02/03: the 85-file audit beyond the common card and the named spots; WIN-03 on-screen re-measurement.

## Tests

`AllOfMacOSTests/AOM78Tests.swift`: flatten (Codex's MenuBarAgent shape, named items, depth cut, empty containers), identity names, stable keys under changing values, alias store, menu normalization and draft edits, save conflict/restore, starter commands exist, rehide policy over 20 s of menu use, pass-through thresholds, clip rule, themes and the theme route.
