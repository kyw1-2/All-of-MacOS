# AOM 7.9.0 — Bartender-style menu bar, the Bar, weather card

## Why

The user's review of 7.8 (2026-11-22): the Menu Bar page showed overlapping words; nothing looked like Bartender's layout or the Bartender Bar / Hidden Bar UI they asked for; weather was untouched and looked dated. Root causes (shared with the user): the Oracle commercial-app analyses weren't read before the UI work (the same miss as 6.5), the spec was implemented as a text checklist, previews were checked with an empty item list, and 7.8 lowered the window's blur so the text of windows behind showed through.

## Oracle evidence used

- Bartender 7.1 (`/data/re/20261106-aom-popclip-menubar/bartender/Bartender 7.app/Contents/Resources/{INTEGRATION,ARCHITECTURE}.md`): Layout page with Shown / Hidden / Always Hidden; images from ScreenCaptureKit captures cached on disk under identity keys (never frames); Bartender Bar = floating mini bar, clicking an item = show-and-click (ephemeral) that auto-hides later but not while a menu/popover is open; on macOS 27 movement uses MenuBarAgent's `TrailingItemPreferredPositions` (needs a file grant) and a mouse mover with fresh AX coordinates and a global ⌘-drag; hiding uses a private "Assessment Mode" or Control Center approvals; Clock/Control Center are force-visible.
- Ice 0.11.12 (macutils report 04): `LayoutBarContainer/LayoutBarItemView` (the layout lanes), `MenuBarItemImageCache` (skips while an item is moving), `IceBarPanel`, ScreenCaptureKit linked.
- Hidden Bar 1.11.1 (`/data/re/20261102/names_hiddenbar.json`): `StatusBarController`, `LegacyLengthEngine`, a macOS 27 `NativeVisibilityEngine` over the private MenuBarClientCore, `HoverToExpand`, auto-hide.

AOM keeps its no-private-API rule: hiding stays its own divider's length; moving is the user's ⌘-drag performed with CGEvents; pictures come from ScreenCaptureKit with the user's Screen Recording grant.

## What changed

- `Services/MenuBar/MenuBarLayout.swift`: `MenuBarSection`, `MenuBarLayoutItem`, pure `MenuBarLayoutPolicy` (section by divider edges — works for a collapsed 10,000 pt divider; locked items; left-to-right lanes; drop points; median bar colour), `MenuBarCommandDrag` (⌘ down, mouse down, 14 drag steps, up, ⌘ up, pointer restored), `MenuBarItemImager` (one SCScreenshotManager capture of each display's menu bar band, cropped per AX frame at the display's scale), `MenuBarLayoutModel` (refresh with a brief reveal only for missing/old pictures, move with verification by rescan, disk cache `Application Support/AllOfMacOS/MenuBarImages`, sample data).
- `Views/MenuBar/MenuBarLayoutEditor.swift`: lanes with drag & drop (`draggable`/`dropDestination`), inspector (rename, move menu, open), permission prompts, `MenuBarBarPreview`.
- `MenuBarStrip.swift`: the Bar — right-aligned under ❮, pictures only, hover/selection, opens hidden items by revealing first.
- `MenuBarHider.swift`: `RevealMode` (menu bar / bar), `hoverReveal` (tracking area on ❮ — no global monitor), `axFrames()`, `revealForInspection()` / `endInspection()` restoring the previous state, options in ❮'s menu.
- `MenuBarControlPage.swift`: cards Layout, Hidden icons, Bar, Weather (live card preview), AOM menu (one row → editor window), Icon spacing.
- `MenuBarWeather.swift`: one request now asks for humidity, wind, UV, sunrise/sunset, 13 hours and 7 days; `WeatherMenuCard` (header, hero, six detail chips, eight hours, week with `WeatherRangeBar`), sized to fit.
- Window glass: every level on `underWindowBackground`; Balanced 0.46/0.42 page, 0.72/0.64 card; Clear 0.30/0.28, 0.62/0.55.
- Previews: `--aom-preview-menubar-sample` (18 items, long Korean names, all three lanes, Seoul weather), `--aom-preview-menubar-bar`; snapshots include windows taller than 32 pt.

## Not verified here

This shell has no Accessibility trust and no screen capture without the macOS private-picker prompt, so the real ⌘-drag on macOS 27's MenuBarAgent surface, the SCK pictures and the ghost-text fix were checked by code and sample renders only. If macOS refuses a move, AOM says so and asks for a manual ⌘-drag.

## Tests

`AllOfMacOSTests/AOM79Tests.swift`: sections (incl. collapsed divider), lanes and locks, drop points, cache key round trip, sample lanes and moves, the full forecast parse and old-cache decode, compass/UV/symbols, reveal mode default. `AOM78Tests.testWIN01MoreColourThanSevenSevenWithoutGhostText`.
