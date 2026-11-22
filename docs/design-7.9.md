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

## Gemini review (AI Studio, Gemini 4 Neon, thinking High, 2026-11-22)

Sent the ten menu bar files (~52k tokens) and three sample screenshots. Checked against the code and fixed:
NSScreen read off the main thread in the imager; MenuBarAgent missing from the scan's first rank; lanes left-aligned in a horizontal scroll view; offscreen/notch/other-display items photographed as app-menu text or black; the crop's size and the image's real scale; bar colour sampled across the notch; overlapping refreshes ending each other's reveal (`refresh` now refuses while busy); the always-hidden divider added before the state to restore was read; an always-hidden item not revealed when only Hidden was out; `stop()` leaving inspection/hover state; popovers and panels hanging from the menu bar not holding the Hider; a Shown drop landing between the divider and ❮ and reordering failing without the Hider; dragging items that aren't on screen; ⌘ sent as keyDown (now flagsChanged, one event number, click state 1, warp to start, no input suppression); the Bar showing Always Hidden icons (now ⌥ or its eye button) and cutting wide icons (width from the pictures, scrolls); cache names over 255 bytes (SHA-256 + index.json, index of live keys only); weather's in-flight slot stuck after an unrequested cancel; DateFormatters per render; settings out of sync with ❮'s menu; the Bar preview not following Hide icons; spacing not restarting MenuBarAgent.
Also taken: an insertion line while dragging; no double-tap delay; lock badges in ink that reads on the sampled bar colour; the Bar's eye / search / settings buttons and closing a second after the pointer leaves; the Shelf toggle's wording; weather chips 2 × 2 with 10.5 pt labels and a sunrise/sunset line, hairlines in light mode, the week in its own well, Now = the current reading, plain stacks instead of a lazy grid.
Not taken: multi-display section misclassification (frames are compared on one axis that spans displays the same way the dividers do), the swap-threshold worry for wide icons (the drop point is past the divider's edge, not over the icon), splitting the page into tabs, triggers and profiles (P2).

## Not verified here

This shell has no Accessibility trust and no screen capture without the macOS private-picker prompt, so the real ⌘-drag on macOS 27's MenuBarAgent surface, the SCK pictures and the ghost-text fix were checked by code and sample renders only. If macOS refuses a move, AOM says so and asks for a manual ⌘-drag.

## Tests

`AllOfMacOSTests/AOM79Tests.swift`: sections (incl. collapsed divider), lanes and locks, drop points, cache key round trip, sample lanes and moves, the full forecast parse and old-cache decode, compass/UV/symbols, reveal mode default. `AOM78Tests.testWIN01MoreColourThanSevenSevenWithoutGhostText`.
