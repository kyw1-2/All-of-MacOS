# AOM 7.7.0 — menu bar discoverability and clarity

## Problem observed on the installed 7.6.0 (2026112203)

Weather is under Settings > General > Modules; the Shelf and Icon Strip hide behind the launcher/extra; Hider options use a chevron and its right-click menu; spacing was under System Tools > Tweaks. Weather's `NSStatusBarButton.appearsDisabled` made missing or stale readings illegibly gray, with a string-only `NSMenu` for the forecast. None of these had an obvious common entry point in the main left sidebar.

## Oracle evidence reviewed (2026-11-06 / 2026-11-14)

- `/data/work/aom-7.1.0/docs/rea-popclip-ice-bartender-20261106.md`: static Ghidra/REA inventory of Bartender 7.1.0 and Ice 0.11.12. Confirms item metadata and managed visibility, secondary floating bar, search and image caching. Static class/strings alone do not verify proprietary algorithms.
- `/data/work/rea/macutils-20261114/report/04_통합분석_맥유틸리티4종.md`: separate Ice 0.11.12 analysis; `MenuBarItemImageCache`, `MenuBarSearchPanel`, current-host `NSStatusItemSpacing`, `NSStatusItemSelectionPadding`, and private SkyLight API references. No private CGS API or proprietary binaries reused.

## Consolidation

Add main sidebar > **Menu Bar**. It controls AOM status item features via their existing manager instances and persisted UserDefaults keys: weather, Shelf/Strip and favorites, Hider optional 2 sections, 0/10/15/30/60-second auto-rehide, reveal all, spacing Default/Compact/Tight and permission guidance. AOM does **not** claim cross-app programmatic hide or reorder; the Hider moves its own divider, users manually ⌘-drag a native status item. AX menu items are reidentified before pressing so stale/ambiguous targets fail safely.

## Weather

Use native-symbol configuration at 13pt semibold and 13pt monospaced digits. Keep button enabled regardless of network state, expose freshness in its full-detail menu/accessibility label. NSHostingView inside NSMenu shows source city/time, large temperature, apparent temperature, low/high/rain and six hourly temperatures. It uses cached WeatherReading only, with no extra requests; current refresh logic and source attribution remain. Units, recent cities and city picker are unchanged. Weather is still opt-in.

## Checks

- Unit and cached reading city identity guard.
- Hider correctness depends on the divider genuinely left of the chevron and can refuse collapse if moved incorrectly.
- Accessibility permission is requested explicitly and missing read access is explained.
- Menu bar preferences may require relaunch of other applications or login; failed transactional spacing write rolls back and is reported.
- Tests cover navigation without existing shortcut regression, weather data formatting/accessibility and divider position policy.
