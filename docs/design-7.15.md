# AOM 7.15 — Native Workbench, first structural pass

Inputs: `~/Downloads/AOM-7.14-Claude-UIUX-구현프롬프트-2026-11-24.md` (prompt), `AOM-7.14-Native-Workbench-50refs-2026-11-24.md` (50 references), `AOM-7.13.0-MainWindow-UIUX-2026-11-24-개편명세서.md` (M01–M36) and its HTML mock-up. Base: `6468bfa` (7.14.0).

**This release is not the full redesign.** It changes the shared shell and four pages structurally; the per-page Inspector and the structural work on the other nine pages and Settings are still to do (table below).

## Status

| Item | Status | Change / file |
|---|---|---|
| P0-1 / M03 bottom action bar | DONE | `AOMActionBar` is selection-only (shows only when `AOMBarContexts` has actions; keys kept on its buttons); `AOMToolbarActions` puts Actions (same `AOMActionPanel`, same sections) and Search (same palette binding) in `.primaryAction`; `MainShell` toolbar. Sidebar search unchanged. |
| P0-2 Inspector | NOT_DONE | No shared inspector yet; Automation/Folder Rules keep their existing split editors. |
| P0-3 / M04 opaque content | DONE (cards) | `aomOpaqueContent` environment set on main-window content; `.paper` cards skip glass rim/shadow there. Window background still follows the Translucent Window setting (user preference); launcher/HUD/floating panels untouched. |
| P0-3 typography/rows | PARTIAL | Headers 18 pt/36 pt mark (7.14); module rows 46→40 pt, mark 24 pt. No global row audit. |
| P0-4 single status | DONE | `WorkspaceBanner(state: snapshot.hero)` + chips + recording strip; `WorkspaceHero` and `hero(_:)` removed (dead). |
| P0-4 repeated titles | DONE (3 pages) | Files, Menu Bar, System Tools headers state something. |
| P0-4 narrow header | DONE | `AOMPageHeader` uses `ViewThatFits`: controls move under the sentence. |
| P0-5 preservation | DONE | LRU 5, rawValues, ⌘1–9, Favorites unchanged; no new timers/observers. |
| M02 Favorites | DONE (7.14) | Context-menu order; drag reorder NOT_DONE. |
| M06 Home | PARTIAL | Status unified; Favorites/frequent tools list layout of the mock-up NOT_DONE. |
| M07–M08 Home rows/rail | NOT_DONE | |
| M09–M10 Settings breadcrumbs/feedback | NOT_DONE | |
| M11–M13 Automation/Input | NOT_DONE (existing split editor kept) | |
| M14–M15 Window Tiling tabs/canvas | NOT_DONE | |
| M16–M17 Capture library/preview | NOT_DONE | |
| M18–M19 Clipboard | NOT_DONE | |
| M20–M21 Audio | NOT_DONE | |
| M22–M24 Menu Bar | PARTIAL | Pane list + compact picker + ↑/↓ (`MenuBarPaneNavigation`); lanes/inspector unchanged. Mute Mic tile stays removed. |
| M25–M36 Files, Folder Rules, Text Actions, Focus, System Tools, Activity | NOT_DONE (header text only for Files/System Tools) | |

## Verification

- Snapshots (AOM's own renderer, 1320×860, light): Workspace and Menu Bar after the change — scratch files, not the 84-capture matrix the prompt asks for (NOT_RUN).
- Build and tests: GitHub Actions `tests.yml` on `feat/7.15` (the user asked that builds and tests run on GitHub, not the MacBook).
- Performance (warm/cold page p50/p95, idle CPU/RSS): NOT_RUN.
- Reference links per screen: in the 50refs document; no third-party UI copied.
