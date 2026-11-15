# Design 4.0 — Slim

Date: 2026-11-15. Base: 3.9.1 (`74a81b6`). Scope: the main window (12 pages), the shared
tokens and components, and everything that inherits them.

## Why

3.8–3.9 changed materials and corners but kept the proportions of 3.3: a 22 pt bold sentence on
top of every page, cards stretched to 1,200 pt, 36/48 pt rows, regular controls in every row,
48 pt round buttons and bold tile titles. In screenshots of 3.9.1 at 1280 × 800 the first control
of a page starts roughly 90 pt under the toolbar, and a row's label and its switch sit up to
about 1,000 pt apart.

## References and what is taken from each

| Reference | Taken |
|---|---|
| macOS 26 control metrics (button 16/20/24/28/36 pt for mini/small/regular/large/xl; list row min 28 pt, padding 4 × 10; list header 13, footer 11; card corner 10; sidebar rows 28) | Row 30 pt, row inset 10, card radius 10, small (20 pt) controls inside rows |
| WWDC25 "Build an AppKit app with the new design" (dense inspectors may request the compact control sizes) | Pages are dense utility panes: `controlSize(.small)` for page content, regular only for a page's one primary action |
| WWDC25 "Get to know the new design system" (hierarchy from layout and grouping, not decoration; bars stay clean) | No in-page title; the toolbar title and window subtitle carry the page name and state |
| Linear, "How we redesigned the Linear UI" (density, alignment, less chrome, contrast for content) | One content size (13) with weight and brightness for hierarchy; labels, icons and controls on shared vertical lines |
| Linear, "A calmer interface" ("don't compete for attention you haven't earned", "structure should be felt not seen", fewer and smaller icons) | Section titles recede (12 pt semibold, secondary); cards lose their outline; row icons 16 pt, secondary |
| Loop / Luminare (fixed narrow pane, sections brighter than the canvas, compact rows) | Content column capped at 860 pt and centred; white groups on the grey canvas stay |
| System Settings (macOS 26) | Fixed readable column, group label above its group aligned with the row text, status in rows not headlines |
| Raycast Settings, 1Password 8, Things 3, SoundSource, CleanShot X Settings, Ice | 28–32 pt rows, medium not bold emphasis, monochrome symbols, one accent |

## Rules

1. Hierarchy by weight and brightness, not size. Content is 13 pt; metadata 11–12 pt. Nothing
   in a page is larger than 15 pt except one live figure (a timer, a count) at 22 pt.
2. Emphasis is medium or semibold, never bold.
3. A page starts with content. The page name is the toolbar title; its state is the window
   subtitle and, where a master switch exists, one compact status line.
4. Content is a centred column of at most 860 pt. List + detail pages keep their full-width split.
5. Rows are 30 pt (one line) and 40 pt (with a description). Controls in rows are small; switches
   stay mini.
6. Structure is felt, not seen: groups are a fill one step above the canvas with no outline;
   dividers are inset hairlines; row symbols are 16 pt and secondary.
7. Round glass buttons are for actions that start something (capture modes, quick actions) and
   are 30–32 pt, not 40–48.

## Tokens (old → new)

| Token | Old | New |
|---|---|---|
| `AOMSpace.pageMargin` | 24 | 20 |
| `AOMSpace.pageTop` | 20 | 12 |
| `AOMSpace.sectionGap` | 24 | 18 |
| `AOMSpace.titleGap` | 8 | 6 |
| `AOMSpace.cardPadding` | 16 | 12 |
| `AOMSpace.tileGap` | 12 | 8 |
| `AOMSpace.rowInset` | 12 | 10 |
| `AOMSize.contentMaxWidth` | 1200 | 860 |
| `AOMSize.readableWidth` | 760 | 720 |
| `AOMSize.rowStandard` / `rowDetail` | 36 / 48 | 30 / 40 |
| `AOMSize.rowSingle` / `rowDouble` / `listRowDouble` | 28 / 44 / 48 | 26 / 38 / 42 |
| `AOMSize.moduleRowHeight` / `moduleControlSlot` | 52 / 72 | 38 / 64 |
| `AOMSize.sidebarMin` / `Ideal` / `Max` | 200 / 220 / 280 | 190 / 208 / 260 |
| `AOMSize.quickActionButton` / `quickActionCell` | 48 / 92 | 32 / 76 |
| `AOMSize.modeButton` | 40 | 30 |
| `AOMSize.tokenHeight` / `logRow` | 22 / 28 | 20 / 24 |
| `AOMFont.pageTitle` | Title (22) bold | Title 3 (15) semibold |
| `AOMFont.heroSentence`, `pageStatus` | 17 / 15 semibold | Body (13) semibold |
| `AOMFont.title` | Title 3 semibold | Title 3 medium |
| `AOMFont.section` | Headline (13 bold), primary | Callout (12) semibold, secondary |
| `AOMFont.headline`, `bodyEmphasis` | 13 bold / semibold | 13 medium |
| `AOMFont.metric` | 13 semibold | 13 medium |
| `AOMFont.metricLarge` | Title (22) semibold | Title 2 (17) medium |
| `AOMFont.display` | Large Title (26) semibold | Title (22) medium |
| `AOMFont.hero` | Large Title (26) bold | Title (22) semibold |
| `AOMRadius.keycap` / `control` / `well` / `card` / `panel` | 5 / 6 / 8 / 12 / 18 | 4 / 5 / 6 / 10 / 14 |
| `AOMIcon.row` | 20 | 16 |
| `AOMIcon.tileBadge` / `tileGlyph` | 32 / 16 | 24 / 13 |
| `AOMIcon.headerBadge` / `empty` | 40 / 40 | 28 / 28 |
| `AOMIcon.inlineGlyph` / `hitArea` | 16 / 28 | 14 / 24 |
| `AOMIcon.statusBadge` / `statusRing` / `listBadge` | 48 / 64 / 24 | 36 / 48 / 20 |

## Components

- `AOMPageHeader`: one 24 pt line. The status sentence in 13 pt semibold, the context after it
  on the same baseline in 12 pt secondary, the pill, then the trailing controls (small). No
  second line.
- `AOMSectionTitle`: 12 pt semibold in secondary colour, inset to the row text (`rowInset`), so
  the title, the rows' labels and the footer share one leading line.
- `AOMSection` / `aomCard` / `aomPane`: fill only; the 0.5 pt outline stays for Increase Contrast.
- `AOMSettingRow`: 30 / 40 pt, vertical padding 3, description in 11 pt, control `.small`.
- `AOMPage`: column 860 pt centred; the page content gets `controlSize(.small)`.
- Empty states: 28 pt glyph, 13 pt medium title, 12 pt secondary line, one regular button.
- Stat strips and figures: label 11 pt secondary over the figure at 17 pt medium.

## Per page (second pass — not implemented in 4.0.0)

From screenshots of every page at 1280 × 800 after the token pass. 4.0.0 ships the token and
component pass above; the items below are the next pass.

All pages
- The page header's text starts on the section titles' leading line (`rowInset` inside the
  column) and its trailing controls end on the cards' inner trailing line.
- A master switch in a page header is `.small`; switches anywhere in a list or a row are mini.
- Buttons inside cards, rows, notices and empty rows are small. A page has at most one regular
  button (an empty state's action).
- Notice titles are 13 pt medium; a notice with a short message is one line with its action.
- Plain command rows (a symbol and a name that runs something) are 13 pt regular, not medium.

List columns (Automation, Folder Rules, Text Actions, Clipboard list)
- One-line rows 28 pt, two-line rows 36 pt, vertical padding 3; leading symbol 16 pt frame;
  mini switches; the selection fill has radius 6 and 6 pt side insets.
- Horizontal chip scrollers never show a scroller.

Automation
- The permission notice above the list is one compact line ("Accessibility is off" + Allow…).
- Editor header: the "Enabled" switch is small; "Applies to" picker small.

System Tools
- Quick toggles are 40 pt tiles: a 24 pt round glyph, the name in 13 pt regular and the state
  in 11 pt secondary on one line each; five per row at the full column, wrapping below 150 pt.
- This Mac cells keep one row of six.

Audio
- The output device's sub-rows (Equalizer, Balance, HomePod effects) are ordinary indented
  setting rows with mini switches and small controls, each 28 pt, labels on one leading line.
- "Stable AirPlay dynamics" is removed: on the direct HomePod path output-wide Magic Boost
  never runs on AirPlay, so the switch has nothing to control. HomePod effects shows its state
  as the row's description ("EQ and per-app volume apply on the HomePod" / "Apps play directly").

Capture
- The empty gallery is 140 pt tall.

Files
- The Open and Save dialog diagram is at most 150 pt tall.

Workspace
- Quick-action names are 11 pt, up to two lines, shortcuts 10 pt tertiary.
