# AOM 4.0 — Discoverable workspace

2026-11-15 · base d280f75 · local-only UI revision

## Evidence

Reviewed today's Claude session and its changed-file paths, the committed SwiftUI views,
`design-4.0-slim.md`, and `performance-main-window-20261115.md`. The slim pass explicitly
left page-level work for a later pass. Its shared 13 pt hierarchy, single-line status/context,
collapsed navigation, context-menu-only favorites and deep placement of app audio controls
made discovery harder even though the underlying features were present.

The original checkout had uncommitted Info.plist/CHANGELOG edits and three PopClip research
notes, plus another active build. This revision uses an isolated worktree and branch; those
files, installed app, saved presets, release metadata and remote branches are untouched.

## Design references and applied decisions

- [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars):
  stable navigation and meaningful groups. One shared task taxonomy covers all 11 destinations.
- [Apple Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars):
  predictable access to global search and inspection, including when the sidebar is hidden.
- [Raycast Search](https://manual.raycast.com/search-bar): task-led discovery. English and Korean
  aliases find tools without requiring exact feature names; settings categories join command search.
- [Raycast Actions](https://manual.raycast.com/action-panel): visible actions and learned shortcuts.
  System-tool favorites have actual star buttons rather than requiring a context-menu discovery.
- [Linear's 2026 refresh](https://linear.app/now/behind-the-latest-design-refresh): consistent
  placement and hierarchy. Shared headers, spacing and readable surfaces apply across modules.

These are design interpretations, not pixel copies or claims of conformity certification.

## Implemented

- Workspace opens with a searchable directory of every main tool, each with a description and
  explicit navigation affordance. Task categories filter the same taxonomy shown in the sidebar.
- Explore and My Workspace separate discovery from the existing configurable operational dashboard.
  Hidden dashboard tiles never remove a tool from discovery. Saved layout customizations stay intact.
- Cmd-F focuses directory search; Return opens a unique match; clearing/no-results recovery and
  Korean aliases support tasks such as `창 배치`, `다운로드 정리`, `홈팟`, and `복사 기록`.
- Sidebar expands into meaningful task families and gains a permanent Settings button. Search is
  named Search Everything; toolbar search stays available when the sidebar is closed.
- Related-tools links at the bottom of module pages bridge the same task family without resetting
  cached page state. Diagnostics and Touch Visualizer have a visible inspector menu.
- Shared headers use a real title and wrapping context instead of truncating both on one line.
  Page columns become 960 pt maximum, rows 34/44 pt, section gaps 24 pt, cards 12 pt corners.
  Semantic colors, Increase Contrast borders, system fonts and Reduce Motion behavior are retained.
- Page scroll indicators may appear naturally; the AppKit policy no longer forcibly removes them.
- Capture utilities wrap into a responsive grid, so Settings and OCR options are no longer
  hidden at the far end of a horizontal scroller.
- Narrow Window Tiling windows show immediate layout actions and pinning before the long
  gesture configuration sections.
- Audio puts app volumes immediately after system devices and labels the master switch.
- System Tools has category filtering and a reset action, visible favorite buttons for command tools,
  and exposes hardware care in the Power category as well as the complete list.
- Palette navigation uses task aliases without dumping keywords into visible descriptions, and
  links directly to every Settings category.

## Verification

Validation results and screenshot coverage are recorded after building in the delivery report.
New tests cover complete/unique destination coverage, bilingual multi-token search, category scope,
blank and absent results, and palette aliases. Existing navigation/page-lifecycle tests remain relevant
because the page cache and service lifecycle implementation are unchanged.

## Scope and boundaries

This is a navigation, discovery and shared visual-system overhaul, plus targeted Audio/System Tools
improvements. It does not rewrite every specialized editor (annotation timeline, equalizer internals,
automation action editor), alter device/automation engines, install the app, publish a release or push.
Hardware operation and all possible user data/permission combinations require normal product QA.
