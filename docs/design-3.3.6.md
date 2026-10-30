# AOM 3.3.6 design spec: references and rules

Owner: UI-A. Applies to every main-window page (UI-A, UI-B, TOOLS). Token names in
`Views/AOMTokens.swift` stay; their values change as listed in part (b). Read part (b) first if you
only need the rules.

Why: 3.3.5 set every page to fixed 12 pt text and `.controlSize(.small)` (11 pt button labels), so
text was smaller than the macOS default (13 pt body, HIG Typography) and Workspace left the lower
half of a 1320×820 window empty. 3.3.6 goes back to the macOS semantic text styles and regular
controls, and gives Workspace enough real content to use the height.

Sources were read on 30 Oct 2026. HIG pages were read from the HIG JSON data
(`developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`). The HIG text
is paraphrased here, not quoted. App patterns are described from the shipping macOS 27 apps.

## (a) References

| # | Source | Pattern | How AOM applies it |
|---|---|---|---|
| 1 | [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography), "macOS built-in text styles" table | Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13 bold, Body 13, Callout 12, Subheadline 11, Footnote/Caption 10 | `AOMFont` maps every role onto these styles. No fixed point sizes. |
| 2 | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), type sizes | macOS default text size is 13 pt and the minimum is 10 pt | Body is 13 pt. Sentences are never below 11 pt. 10 pt is only for badges and keycaps. |
| 3 | HIG Accessibility, control sizes | The default macOS control is 28×28 pt and the minimum is 20×20 pt | Icon buttons get a 28 pt hit area (`AOMIcon.hitArea`). Regular controls are the default. |
| 4 | HIG Accessibility, spacing | Leave about 12 pt around bezeled controls and about 24 pt around bezel-less ones | 12 pt between tiles and between buttons. 24 pt between sections. |
| 5 | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout), visual hierarchy | Put the most important content at the top and on the leading side | Workspace order: status, setup, needs attention, modules, then the rest. |
| 6 | HIG Layout | Align elements so they are easy to scan, and use indentation to show hierarchy | One leading edge for every section. Grid columns are shared across sections. |
| 7 | HIG Layout | Group related items with negative space, containers or separators | 24 pt between sections, 12 pt inside a group, hairlines between rows. |
| 8 | HIG Layout | Use progressive disclosure to keep layouts clean | Setup steps collapse into one line. Needs attention shows 3 rows plus "Show All". |
| 9 | HIG Layout, macOS | Don't put critical controls or information at the bottom of a window | No bottom bar. Quick actions sit above the fold. |
| 10 | HIG Layout | Tell controls apart from content: Liquid Glass and the scroll edge effect for controls, no solid fills under them | The toolbar has no custom fill. `aomScrollEdge()` stays. |
| 11 | [HIG Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Use large displays to show more content in fewer nested levels, at a comfortable density | Workspace shows status, modules, today's numbers, this Mac and recent activity on one screen. |
| 12 | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), macOS | Sidebar row height, text and glyph size follow the sidebar size people pick in General settings | Remove `.sidebarRowSize(.small)` and the fixed 12 pt label and icon fonts. |
| 13 | HIG Sidebars (updated June 2026) | Sidebar icons use the app accent by default. Give icon colours a clear purpose | Sidebar icons keep the accent. Module hues stay in content. |
| 14 | HIG Sidebars | Show at most two levels and give each group a short label | Workspace, then Tools and Activity. |
| 15 | HIG Sidebars, macOS | Don't put critical items at the bottom of a sidebar | No sidebar footer. |
| 16 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), titles | Give every window a useful, concise title (under 15 characters) and don't use the app name | The system toolbar title is the page name ("Workspace", "System Tools"). |
| 17 | HIG Toolbars | Avoid custom toolbar backgrounds and appearances. Prefer standard components | The 3.3.5 custom 13 pt title label goes. The system title returns. |
| 18 | HIG Toolbars, item groupings | Sidebar button and title on the leading edge; important actions and search on the trailing edge | "New Automation" (+) and search fields stay trailing. |
| 19 | HIG Toolbars | Aim for no more than three groups | At most three toolbar groups per page. |
| 20 | HIG Toolbars | Use the prominent style for one key action, on the trailing side | At most one prominent toolbar item per page. |
| 21 | HIG Toolbars | Don't place a text action next to a symbol action as if they were one | Toolbar actions are symbols with a `.help` tooltip. |
| 22 | [HIG Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) | Prefer lists for text. Short row text avoids truncation | Recent activity and Needs attention are lists, not tiles. |
| 23 | HIG Lists and tables, macOS | Sortable, resizable columns and alternating row colours in wide multicolumn tables | For UI-B's tables (Insights, Clipboard). Not used on Workspace. |
| 24 | [HIG Collections](https://developer.apple.com/design/human-interface-guidelines/collections) | Use the standard row or grid layout. Use a table for text | Module tiles and quick actions use a grid. Activity uses a list. |
| 25 | HIG Collections | Leave enough padding around items for hover and focus effects | Tiles have 16 pt padding and a hover fill. |
| 26 | [HIG Charts](https://developer.apple.com/design/human-interface-guidelines/charts), descriptive content | Title the chart and summarise its main message | The week chart is titled with its total ("12 this week"). |
| 27 | HIG Charts, axes | Start bar charts at zero, use familiar tick values and few grid lines | Bars start at 0, with at most 3 grid lines and weekday labels only. |
| 28 | HIG Charts | Make every chart accessible | The chart has one VoiceOver summary plus a label per day. |
| 29 | [HIG Gauges](https://developer.apple.com/design/human-interface-guidelines/gauges), macOS level indicators | Use a continuous capacity indicator for large ranges. Change the fill colour for significant ranges | Disk and memory are continuous bars. The bar turns orange below 10% free disk or under high memory pressure. |
| 30 | [HIG Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), macOS | Put switches in the window body, never in the toolbar | No switches in toolbars. |
| 31 | HIG Toggles, switches | Use a switch for settings you want to emphasise. In grouped forms use a mini switch, or a regular one for the primary setting | Module tiles use a small switch. Rows in grouped sections use mini switches. |
| 32 | HIG Toggles | Don't swap an existing checkbox for a switch. Use checkboxes for hierarchies | Checkbox lists stay checkboxes. |
| 33 | [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | Give the most likely action the prominent style, and use style rather than size to show preference | One `.borderedProminent` per section, only for the action that fixes the current state. |
| 34 | HIG Buttons, macOS push buttons | End the title with an ellipsis when the button opens another window, view or app | "Allow…", "Set Up…" and "Create…" keep the ellipsis. |
| 35 | HIG Buttons, macOS | macOS shows a tooltip after hover | Every icon-only button has `.help`. |
| 36 | HIG Buttons | Always include a press state for custom buttons | Tile and card button styles darken the fill on press. |
| 37 | [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) | Don't use the same colour to mean different things | Accent means interaction, semantic colours mean status (always with a glyph and text), module hues mean identity. |
| 38 | HIG Color | Use dynamic system colours and don't redefine their meanings | Text, separators and fills use `NSColor` label, separator and fill colours. |
| 39 | HIG Color, Liquid Glass | Apply colour to glass sparingly, only for status or primary actions | No tinted glass in AOM. |
| 40 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Don't use Liquid Glass in the content layer | Cards and tiles are opaque `surface`. Glass is for chrome only (`aomChrome`). |
| 41 | HIG Materials | Use vibrant colours on top of materials | Sidebar and HUD text uses system label colours. |
| 42 | HIG Materials, macOS | Choose behind-window or within-window blending on purpose | `VisualEffectBackground` keeps behind-window for HUDs and panels. |
| 43 | [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | Dark palettes are dimmer backgrounds with brighter foregrounds, not inversions | Tokens have separate light and dark values. Every screen is checked in both modes. |
| 44 | [HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols), rendering modes | Monochrome, hierarchical, palette and multicolor modes | Row glyphs are hierarchical secondary. Squircle glyphs are white monochrome. Status glyphs use palette. |
| 45 | [HIG Icons](https://developer.apple.com/design/human-interface-guidelines/icons) | Match the weight of an icon to the text next to it | Glyphs inherit the row's text style (`.font(.body)` and so on), not a fixed 11 pt. |
| 46 | HIG Icons | Centre asymmetric glyphs optically | Badges centre glyphs in a fixed square frame. |
| 47 | [HIG App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) (updated June 2026) | macOS icons are rounded-rectangle squircles | Module badges are continuous squircles with radius = 22.5% of the size (`AOMRadius.squircle`). |
| 48 | [HIG Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding) | Keep onboarding fast and optional. Teach by doing. Prefer contextual tips | Setup is three inline steps on Workspace, each with its real action. |
| 49 | HIG Onboarding | If people skip a tutorial, don't show it again | "Skip" is remembered (`workspace.setupSkipped`). |
| 50 | [HIG Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Keep task-specific options in context instead of in Settings | Module on/off switches sit on the Workspace tiles. |
| 51 | [HIG Boxes](https://developer.apple.com/design/human-interface-guidelines/boxes) | Keep a box small relative to its view and don't nest boxes | No card inside a card. The status header is not a card while AOM is running. |
| 52 | [HIG Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) | Prefer determinate indicators | Setup shows "1 of 3" with a determinate bar. |
| 53 | [HIG Loading](https://developer.apple.com/design/human-interface-guidelines/loading) | Show something as soon as possible | Live values show "…" until the first sample instead of an empty card. |
| 54 | [HIG Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) | Label what a disclosure shows or hides | "Show All Steps" and "Hide Steps", never a bare chevron. |
| 55 | [HIG Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls) | About 5 to 7 equal-width segments, either text or images | Page scope bars (UI-B) follow this. |
| 56 | [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) | Placeholder text says what you can search for | The sidebar search opens ⌘K with "Search pages, settings and actions". |
| 57 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | Avoid custom window UI | System frame, system title and system sidebar. |
| 58 | [HIG Split views](https://developer.apple.com/design/human-interface-guidelines/split-views), macOS | Set reasonable minimum and maximum pane sizes | Sidebar 200–280 pt, ideal 220 pt, for medium sidebar rows. |
| 59 | [HIG Labels](https://developer.apple.com/design/human-interface-guidelines/labels) | Prefer system fonts | The SF Pro text styles everywhere. Monospaced only for codes, paths and logs. |
| 60 | [WWDC25 "Meet Liquid Glass"](https://developer.apple.com/videos/play/wwdc2025/219/) | Glass is the navigation layer floating above content | Toolbar, sidebar, ⌘K and HUDs only. |
| 61 | [WWDC25 "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323/) | Standard toolbars, sidebars and controls pick up the new design automatically. Scroll edge effects replace bar backgrounds | Use the system title and standard buttons. No hand-drawn title capsules. |
| 62 | [WWDC25 "Build an AppKit app with the new design"](https://developer.apple.com/videos/play/wwdc2025/310/) | Controls are taller on macOS 26 and later. Corners should be concentric | Regular control size by default. Inner radii use `AOMRadius.concentric`. |
| 63 | [WWDC25 "Get to know the new design system"](https://developer.apple.com/videos/play/wwdc2025/356/) | Clear hierarchy, concentric shapes, bolder left-aligned headings | Section titles are Headline (13 bold) and left-aligned. |
| 64 | [WWDC25 "Elevate the design of your iPad app"](https://developer.apple.com/videos/play/wwdc2025/208/) | Layouts adapt to resizable windows | The tile grid goes from 3 columns to 2. The lower area goes from 2 columns to 1. |
| 65 | [WWDC20 "Adopt the new look of macOS"](https://developer.apple.com/videos/play/wwdc2020/10104/) | Full-height sidebars, inline toolbar titles, symbol iconography | Standard `NavigationSplitView` sidebar and system toolbar title. |
| 66 | [WWDC21 "SwiftUI on the Mac: Build the fundamentals"](https://developer.apple.com/videos/play/wwdc2021/10062/) | Sidebar plus detail, and data-rich detail views | Workspace detail shows real counts. Pages open from tiles. |
| 67 | [WWDC21 "SwiftUI on the Mac: The finishing touches"](https://developer.apple.com/videos/play/wwdc2021/10289) | Respect system settings (accent colour, sidebar size) and menus | Accent and sidebar size are the system's. Controls › Pause AOM stays in the menu bar. |
| 68 | [WWDC20 "The details of UI typography"](https://developer.apple.com/videos/play/wwdc2020/10175/) | Text styles carry tracking and leading per optical size | Use text styles, not `Font.system(size:)`. |
| 69 | [WWDC22 "Design an effective chart"](https://developer.apple.com/videos/play/wwdc2022/110340/) | Lead with one at-a-glance summary, then detail | The Today card shows big numbers above the week chart. |
| 70 | [WWDC22 "Hello Swift Charts"](https://developer.apple.com/videos/play/wwdc2022/10137/) | `BarMark` with simple axes | The week chart is a Swift Charts `BarMark`. |
| 71 | [Food Truck sample](https://github.com/apple/sample-food-truck), TruckView dashboard | A grid of summary cards. Each card has a header link and a chart or count, and opens its detail | Workspace cards open their page from the header. |
| 72 | [Backyard Birds sample](https://github.com/apple/sample-backyard-birds) | Glanceable summary grid with rounded cards. `ContentUnavailableView` when empty | Compact in-card empty states (glyph, sentence, one button). |
| 73 | Destination Video sample (WWDC24, visionOS/macOS) | Shelves: a titled row of items with a "See All" | Section titles with a trailing "View All ›" link. |
| 74 | System Settings, any pane | Grouped Form: inset rounded groups, bold 13 pt section headers, 13 pt rows, controls trailing | `AOMSection` and `AOMSettingRow`: 36 pt rows, 48 pt with a description. |
| 75 | System Settings, LabeledContent rows (General › About) | Label leading, value trailing in secondary text | "This Mac" rows: "Memory … 5.6 GB of 8 GB". |
| 76 | System Settings › General › Storage | One capacity bar, then values | The disk bar on Workspace shows free of total. |
| 77 | System Settings › Battery | Level and health readouts with a chart | The battery row shows the real percentage and state. Health and cycles stay on System Tools. |
| 78 | System Settings sidebar | Colourful 20 pt squircle icon per pane | Squircles with module hues appear in content (tiles and headers), not in AOM's sidebar (#13). |
| 79 | Reminders, smart-list tiles | Tile with a coloured icon, a large bold count and the list name | Module tile: squircle, name, large count with its unit, status line. |
| 80 | Passwords (macOS 15+), category grid | Category tiles with counts at the top. The Security tile shows the number of problems | Tiles are grouped at the top. A tile that needs a permission shows a warning glyph and text. |
| 81 | Home, accessory tiles | Icon, name and state. Off accessories are dimmed. The tile toggles, the name opens details | Off modules show a grey squircle. The tile opens the page and the switch is a separate target. |
| 82 | Control Center, toggle modules | The glyph fills with the accent when the module is on | A tile's squircle shows its hue only while the module is on. |
| 83 | Activity Monitor, CPU/Memory footer | Live load and memory figures with a pressure graph | "This Mac" shows live CPU % and memory with a pressure-coloured bar. |
| 84 | Screen Time, weekly chart | Big total above a bar chart for the week, with today highlighted | Today card: big counts, then 7 bars with today in the accent colour. |
| 85 | Shortcuts, gallery and library | Rounded action tiles: glyph on the leading side, title, one click runs it | Quick actions are a grid of equal tiles with the glyph, the name and the shortcut. |
| 86 | Music and TV, shelves | Headers with a trailing "See All" | "Recent activity … View All ›". |
| 87 | Xcode Organizer, Metrics | A metric title, a big number and a small chart in one card | The Today card follows this pattern. |
| 88 | Finder sidebar | Small, medium and large sizes from General settings | The sidebar uses the system size (#12). |
| 89 | Disk Utility, volume header | A capacity bar with used/free legend and exact numbers | Same bar and legend for "Disk". |
| 90 | Freeform, empty board | One sentence and one create button, no illustration wall | Empty Recent activity: one line and an action. |
| 91 | Journal, suggestions | Dismissible suggestion cards | Suggestions in Needs attention have a dismiss (×) button. |
| 92 | Mail sidebar | Small counts sit trailing in the row | Sidebar status pills stay trailing and only show abnormal states. |
| 93 | App Store (Mac), section headers | Bold section headers with "See All" and generous spacing between shelves | 24 pt between sections. Headline (13 bold) titles. |
| 94 | System Settings › Privacy & Security | A row per permission with its state and a button that opens the pane | Permission chips open the right System Settings pane. |
| 95 | Notes and Reminders sidebars | `.listStyle(.sidebar)` with system rows and accent glyphs | `AOMSidebar` uses system rows. |

## (b) AOM 3.3.6 spec

### b.1 Type scale (macOS semantic text styles)

| Token | Style | Size | Use |
|---|---|---|---|
| `AOMFont.hero` | `.largeTitle.bold()` | 26 | Large glyph placeholders only. No text. |
| `AOMFont.heroSentence` | `.title2.weight(.semibold)` | 17 | The Workspace status sentence, once per window. |
| `AOMFont.title` | `.title3.weight(.semibold)` | 15 | Editor titles, onboarding step titles, sheet titles. |
| `AOMFont.pageStatus` | `.title3.weight(.semibold)` | 15 | The module page header sentence (`AOMPageHeader`). |
| `AOMFont.section` | `.headline` | 13 bold | Section titles ("Needs attention", "Rules"). |
| `AOMFont.headline` | `.headline` | 13 bold | Card and tile titles, emphasised row titles. |
| `AOMFont.body` | `.body` | 13 | Rows, sentences, buttons. The base size. |
| `AOMFont.bodyEmphasis` | `.body.weight(.semibold)` | 13 | Emphasis inside body text. |
| `AOMFont.callout` | `.callout` | 12 | One-line descriptions, tile status lines. |
| `AOMFont.caption` | `.subheadline` | 11 | Metadata (times, counts beside titles), footers. |
| `AOMFont.badge` | `.caption.weight(.medium)` | 10 | Pills and keycaps only, never sentences. |
| `AOMFont.mono` | `.callout` monospaced | 12 | Key codes, paths, logs, JSON. |
| `AOMFont.metric` | `.body.weight(.semibold)`, monospaced digits | 13 | Live values in rows. |
| `AOMFont.metricLarge` | `.title.weight(.semibold)`, monospaced digits | 22 | Tile counts, summary figures (Workspace Today, Insights). |

Rules: no `Font.system(size:)` for text. A glyph next to text takes that text's style (`.font(AOMFont.body)`),
or `.imageScale(.small/.large)`. No body text below 13 pt. No sentence below 11 pt.

### b.2 Spacing (4 pt grid, 8 pt rhythm)

| Token | 3.3.5 | 3.3.6 | Use |
|---|---|---|---|
| `pageMargin` | 16 | 24 | Detail column inset on every side. |
| `sectionGap` | 14 | 24 | Between page sections. |
| `titleGap` | 6 | 8 | Section title to its card. |
| `cardPadding` | 10 | 16 | Inside cards and tiles with free content. |
| `tileGap` | 6 | 12 | Between tiles and cards in a grid. |
| `rowInset` | 10 | 12 | Row horizontal inset. |
| `rowSymbolInset` | 34 | 40 | Divider inset for rows with a 20 pt leading glyph (12 + 20 + 8). |
| `m` / `l` (legacy) | 10 / 14 | 12 / 16 | |

### b.3 Sizes

| Token | 3.3.6 | Note |
|---|---|---|
| Sidebar width | 200 / 220 / 280 | min / ideal / max, for system medium rows. |
| `rowDense` | 24 | Tables and dense lists (the system table row). |
| `rowStandard` | 36 | A grouped-form row with a regular control. |
| `rowDetail` | 48 | A row with a title and a one-line description. |
| `rowSingle` / `rowDouble` / `listRowDouble` | 28 / 44 / 48 | List rows. |
| `contentMaxWidth` | 1200 | Dashboards and grids fill the detail column up to this. |
| `readableWidth` | 760 | Forms and editors. |
| `tileMin` | 240 | Module tile minimum width. 3 columns from 3×240+2×12 = 744 pt. |
| `tileHeight` | 104 | Module tile: squircle row, then the count line. |
| `windowMinWidth` × `windowMinHeight` | 980 × 600 | Unchanged. |

### b.4 Content width: no empty half-windows

- Dashboards (Workspace, Insights, System Tools) fill the detail column up to 1200 pt, leading-aligned
  and centred beyond that. At 1320×820 that is the full column (about 1050 pt).
- Workspace must use the height of a 1320×820 window. Its lower area is two columns: Quick actions
  and Recent activity on the left, Today and This Mac on the right (340 pt). Below about 900 pt of
  column width they stack into one column.
- Forms (settings-like pages) cap at 760 pt. When the column is wider than about 1100 pt, put two
  related groups side by side instead of leaving one narrow centred column.
- Every number shown is real data from an existing service. If a value isn't known yet, show "…",
  never a made-up value.

### b.5 Cards, grouped forms and lists

- Grouped form (`AOMSection` with `AOMSettingRow`/`AOMToggleRow`): settings. Headline title, an opaque
  card, 36/48 pt rows, hairlines inset under the text, mini switches.
- Cards (`aomCard`, tiles, metric cards, charts): glanceable summaries on dashboards only. One level:
  never put a card inside a card.
- Lists (rows in a section card, or `List`): text items such as activity, attention and history.
- Status header: plain on the canvas while all is well. It gets a tinted card only when AOM needs
  something (paused, permission missing).

### b.6 Controls

- Regular control size everywhere by default. The page-wide `.controlSize(.small)` from 3.3.5 is removed.
- `.small` only inside dense tables, `List` rows in narrow side columns, and inspectors.
- `.mini` only for switches inside grouped rows (HIG #31).
- `.large` for the single primary button of an empty state or a first-run step, if needed.
- One `.borderedProminent` per section, only for the action that fixes the current state.
- Icon-only buttons: 28 pt hit area, `.help` tooltip, `accessibilityLabel`.

### b.7 Icons and squircles

| Token | Size | Glyph | Use |
|---|---|---|---|
| `AOMIcon.row` | 20 | row text style | Leading glyph in rows. |
| `AOMIcon.tileBadge` | 32 | 16 semibold | Workspace tiles, quick actions. |
| `AOMIcon.headerBadge` | 40 | 20 semibold | Page headers. |
| `AOMIcon.hero` | 40 | 22 | Workspace status. |
| `AOMIcon.empty` | 40 | | Empty-state glyph. |
| `AOMIcon.hitArea` | 28 | | Icon-button hit area. |

Squircle radius is `AOMRadius.squircle(size)` = 0.225 × size, continuous. Other radii: keycap 5,
control 6, well 8, card 12, panel 18.

### b.8 Colour and materials

- Accent = interaction. Semantic colours = status, always with a glyph and text. Module hues =
  identity in content (tiles, headers) and only while the module is on.
- Canvas white / #282828. Surface (cards) #F4F4F6 / #323234, a little stronger than 3.3.5 so cards
  read without relying only on the hairline. Hairline = `separatorColor`.
- Liquid Glass only for chrome (toolbar, sidebar, ⌘K, HUDs) behind `#available(macOS 26, *)`, with a
  material fallback. No glass in content.

### b.9 Empty states

- In a card: a 20 pt hierarchical glyph, one sentence in Body secondary and at most one button,
  leading-aligned in a 48 pt row. Never an empty card with nothing in it.
- A whole page with nothing in it: `AOMEmptyState` (ContentUnavailableView), 40 pt glyph, title,
  one-sentence message, one primary button.

### b.10 Sidebar

- `List(.sidebar)` with system rows. No `sidebarRowSize` override, no custom label font or icon size.
  Status pills stay trailing and only show abnormal states.
- The search capsule at the top stays (the visible way into ⌘K). Body text, 28 pt tall.

### b.11 Toolbar

- System title (`navigationTitle`) and subtitle (`navigationSubtitle` via `aomToolbarSubtitle`). The
  3.3.5 custom 13 pt title item is removed. Nothing in the spec needs it: the system title is the
  standard size, and #16, #17 and #61 ask for the system component.
- At most three groups. One prominent action, on the trailing side.

### b.12 Workspace

Order (top to bottom), each part shown only when it has real content:
1. Status header: 40 pt tone squircle, the sentence (Title 2), a detail line (Body secondary),
   permission chips, and the one action on the trailing edge.
2. Setup (first run): a card with a progress line and the three steps as columns, each with its
   real button. Skip, and Show the Tour.
3. Needs attention: list rows (glyph, Body sentence, one button, dismiss for suggestions).
4. Modules: tiles in 3 columns × 2 rows (2 × 3 when narrow) with a squircle, the name, a status line,
   a large count and one control.
5. Lower area, two columns:
   - Left: Quick actions (a grid of tiles: glyph, name, shortcut; pinned automations after them),
     then Recent activity (rows, "View All ›" to Insights).
   - Right: Today (actions run, captures and copies today, big numbers; a 7-day bar chart of AOM
     actions with today in the accent colour), then This Mac (CPU, memory bar, startup disk bar,
     battery) from the System Tools monitor, with "System Tools ›".
