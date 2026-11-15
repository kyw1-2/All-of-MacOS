# Main window stalls — 2026-11-15

Base: 3.9.1 (`74a81b6`).

## Causes

1. **Audio control on the main thread.** A 15 s `sample` of the installed 3.9.1 (main window
   closed, App Audio on) spent about 10 % of all main-thread time in
   `AppAudioEngine.syncActiveProcesses()`: per-process `IsRunningOutput` reads (375 of 808
   samples), owner resolution (128), the app list and statuses (~100), device and transport
   reads. It ran on every CoreAudio process-list, device and default-output notification, on
   every per-process playing change and from a 1 s timer, in every window of the app.
2. **Every page switch rebuilt the page.** `MainWindow` was a `switch` over the selected tab.
   An in-app bench (`--aom-preview-bench`, release build, quiet machine) measured 0.4–3.0 s on a
   first visit and 0.3–0.4 s on later visits, and the App scene graph was re-evaluated on every
   switch because the App and 22 views observed `AppState.selectedMainTab`.
3. Smaller: the Files page measured every favourite's display name in its view body and
   re-measured its column layout each pass; Back/Forward recording re-rendered during the switch.

## Changes

- Audio control is split into a gather on a private queue (`AudioControlSnapshot`: process
  objects, owners, playing state, default output, devices, transports, app identities) and a
  short apply on main. Diagnostics report `controlGatherMeanMS` and `controlApplyMaxMS`.
- Navigation has its own publisher (`AOMNavigation`); the App and unrelated views no longer
  observe the selected page.
- Visited pages stay alive (`AOMPageHost`), each with a fixed identity. Hidden pages keep their
  last size, contribute no toolbar items, search field, subtitle or keyboard shortcuts, and stop
  their timers, polling and timelines (`AOMPageActivity`, one object per page, observed only by
  small leaf modifiers so a switch does not re-render page bodies).
- Toolbar search on five pages is an `NSSearchField` inside the page's conditional toolbar.
- Files caches display names and layout measurements.
- Preview hooks: `--aom-preview-visit`, `--aom-preview-search`, `--aom-preview-hide`; the bench
  reports `cpu_ms` (main-thread CPU time) and `first` per switch.

## Result (in-app bench, release builds, isolated preview with the user's preset)

| | 3.9.1 | 4.0.0 |
|---|---|---|
| Later visits, wall time per switch (quiet runs) | 310–400 ms | about 200 ms (CPU 197 ms) |
| First visit, wall time per switch | about 400 ms | 410–450 ms |

Window Tiling revisits take 70–80 ms, Automation about 350 ms. What remains on a revisit is the
toolbar being rebuilt for the new page and SwiftUI's update of the two pages; both hiding methods
(opacity and an off-window offset) measured the same. The audio change does not show in this
bench (previews skip audio); it removes a stall that happened about once a second in every window
while App Audio was on.
