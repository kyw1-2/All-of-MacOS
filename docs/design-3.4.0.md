# AOM 3.4.0 design spec: references and rules

Owner: A (DESIGN). Applies to every window, page, panel, HUD and menu that AOM draws (A, B and the module
agents C–I). It builds on docs/design-3.3.6.md: that spec's 95 references (#1–#95) and its rules stay in force
unless part (b) below changes them. The references here are new and continue the numbering at #96.

Why: the user liked the 3.3.6 direction (macOS text styles, regular controls, the system sidebar and title, a
Workspace with module tiles and an overview row) and asked for a full overhaul that takes it to the level of the
best Mac apps, without going back to tiny text or crowded cards. 3.4 also adds four Productivity pages (Folder
Rules, Text Actions, Files, Focus), so the pages need shared templates for rule lists, editors and live status.

Sources were read on 31 Oct 2026. HIG pages were read from Apple's HIG JSON data
(`developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`); the date after a HIG page
is its last change note. WWDC sessions are cited by their developer.apple.com pages. App patterns come from each
developer's documentation where linked, otherwise from the shipping app (app + screen). HIG and session text is
paraphrased, not quoted.

Read part (b) first if you only need the rules. Section b.12 lists the new components with their APIs.

## (a) References (#96–#212)

### HIG pages not used in 3.3.6

| # | Source | Pattern | How AOM applies it |
|---|---|---|---|
| 96 | [HIG Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection) | Rely on the system focus effects; a ring for text and search fields, a highlight in lists and collections | Lists use the system selection highlight. Custom tiles get `aomFocusRing` (system focus colour, concentric) only when they take keyboard focus. Fields keep the system ring. |
| 97 | HIG Focus and selection | Don't move focus without people's interaction | No page steals focus on open. Only ⌘K and ⌘F move focus into a field. After a delete, selection moves to the neighbouring row, the one case the HIG allows. |
| 98 | [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop) | Support drag and drop throughout, and offer another way to do the same thing | Quick actions reorder by dragging and by Move Left/Right in the context menu. Folder rows accept Finder folders and also have Choose…. |
| 99 | HIG Drag and drop | Show whether a destination accepts the content; give visual feedback when a drop fails | `aomDropTarget`: an accent ring and wash only over a valid target. A drop that fails shows a danger toast that says why. |
| 100 | HIG Drag and drop, macOS | Let people drag content into the Finder; badge multi-item drags | Recent captures, shelf items and recent files drag out as file URLs (system drag image and badge). |
| 101 | HIG Drag and drop | Let people undo a drag-and-drop operation | Reordering registers "Move Quick Action" with the window's undo manager. |
| 102 | HIG Drag and drop | Show a drag image as soon as the pointer moves about 3 pt | AOM uses the system `.draggable` and `.dropDestination`, which do this, instead of custom gesture drags. |
| 103 | [HIG Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) | Help people predict undo: name the action ("Undo Typing") | `AOMUndo.perform("Hide Tile", …)` sets the action name, so Edit › Undo reads "Undo Hide Tile". |
| 104 | HIG Undo and redo | Show the result of an undo, even when it is off screen | Undoing a hidden tile or a removed quick action brings it back where it was, with a short accent ring. |
| 105 | HIG Undo and redo, macOS | Undo and redo live in the Edit menu with ⌘Z and ⇧⌘Z | Every undoable AOM change goes through the window's `UndoManager`. The toast's Undo button also answers ⌘Z. |
| 106 | HIG Undo and redo | Let people undo several times, and revert a batch at once | Undo is unlimited within the session. Customize › Reset Layout is one undoable step. |
| 107 | [HIG Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) | Integrate status feedback into the interface | Module state lives on tiles, sidebar pills and page status headers, not in alerts or notifications. |
| 108 | HIG Feedback | Confirm that a significant action completed | A toast confirms runs, copies and saves in the window. A HUD confirms global actions outside it (microphone muted, focus started). |
| 109 | HIG Feedback | Show when a command can't run and help people understand why | Failure toasts use the danger tone and give the reason. Unavailable quick actions stay visible, dimmed, with a tooltip that says what is missing. |
| 110 | HIG Feedback | Warn before unexpected, irreversible data loss | Confirm only what can't be undone (Reset Preferences, Empty History). Undoable actions never ask. |
| 111 | [HIG Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications) | Use an alert, not a notification, for errors; handle notifications well while the app is frontmost | AOM never notifies about its own errors. While AOM's window is key, modules show a toast instead of posting a notification. |
| 112 | HIG Notifications | Don't send several notifications for the same thing | Folder Rules posts one summary per run ("Tidied 12 files in Downloads"), never one per file. |
| 113 | HIG Notifications, badging | A badge isn't the only way to show essential information; keep badges current | Sidebar pills repeat what the page header says and update live; no information exists only in a badge. |
| 114 | [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) (June 2025) | Provide a View menu; show/hide items name the current state | View lists Back, Forward and every page, then Show/Hide Sidebar, Show/Hide Inspector and Customize Workspace…. |
| 115 | HIG The menu bar | Provide a Window menu even with one window; show and hide panels there | Window keeps Diagnostics Console and Touch Visualizer as checked items. |
| 116 | HIG The menu bar | App-specific menus go from general to specific; prefer one-word titles | One app menu, Controls (Pause AOM), between View and Window. |
| 117 | HIG The menu bar, menu bar extras | Use a symbol; show a menu, not a popover; let people choose whether it shows; don't rely on it | The status item stays a symbol with a menu, Settings › General keeps Show in Menu Bar, and every item is also reachable from the window or the menu bar. |
| 118 | HIG The menu bar, dynamic items | A dynamic (⌥) item is never the only way; one modifier only | Test HUD Overlay stays the only ⌥ alternate; its job (show the HUD) also has Gesture HUD. |
| 119 | [HIG Menus](https://developer.apple.com/design/human-interface-guidelines/menus) (June 2026) | Title-style capitalization, no articles, an ellipsis when more input follows | Status-menu and context-menu labels follow this ("Customize Workspace…", "Show in Finder"). |
| 120 | HIG Menus (June 2026, icons) | Use menu icons sparingly and uniformly within a group; the same icon for the same action | Status menu: every top-level item has a symbol, the same symbol as the page's button for that action. Context menus carry no icons. |
| 121 | HIG Menus | Most important first; group related items; mind the length | Status menu: Capture, Clipboard, Windows, Productivity, the two toggles, app entry points, More, Quit. |
| 122 | HIG Menus, toggled items | A changing label or a checkmark shows state | "Pause Clipboard History" / "Resume Clipboard History"; checkmarks on Automation, Drag to Snap, Gesture HUD. |
| 123 | HIG Menus, submenus | Use submenus sparingly, one level, available even when their items aren't | More and All Capture Tools are the only submenus, one level deep, always present. |
| 124 | [HIG Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) | Relevant, short, and consistent throughout the app | Every item has one: sidebar rows, tiles, quick actions, attention rows, activity rows, log rows, tokens, folder rows. |
| 125 | HIG Context menus | Every context item also exists in the main interface | Each context command is also a button, a menu bar item or a shortcut. |
| 126 | HIG Context menus (Dec 2023) | Hide unavailable items instead of dimming them | A tile without a switch has no "Turn On"; a row without a file has no "Show in Finder". |
| 127 | HIG Context menus | Show keyboard shortcuts in the main menus, not in context menus | Context menus have no key equivalents. |
| 128 | HIG Context menus | One submenu level at most; follow separator rules | Context menus are flat: open, act, then a separator, then hide/remove. |
| 129 | [HIG Pop-up buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons) | A flat list of exclusive options with a useful default; predictable without opening | A rule condition's attribute and operator are pop-up buttons with defaults ("Kind" "is" "Image"). |
| 130 | [HIG Pull-down buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons) | Commands related to the button; don't put every action in one; confirm destructive items | The ⋯ in `AOMAddRemoveBar` holds Duplicate, Import… and Export…; Delete stays the − button. |
| 131 | [HIG Token fields](https://developer.apple.com/design/human-interface-guidelines/token-fields) | Add a context menu to tokens; offer more ways to turn text into tokens | `AOMTokenField`: Return, Tab or a comma make a token; each token has Copy and Remove; suggestions sit in a pull-down. |
| 132 | [HIG Path controls](https://developer.apple.com/design/human-interface-guidelines/path-controls) | Use a path control in the window body, not the frame | `AOMPathRow` lives in forms and inspectors, never in a toolbar or title bar. |
| 133 | [HIG Outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views) | Keep people's expansion choices; hierarchy in the first column; a search field for long outlines | Sidebar sections and nested condition groups remember whether they are expanded. |
| 134 | [HIG Column views](https://developer.apple.com/design/human-interface-guidelines/column-views) | Show information about the selection when there is nothing nested | The inspector of a list + detail page shows the selected item's preview, history and numbers. |
| 135 | [HIG Panels](https://developer.apple.com/design/human-interface-guidelines/panels) | Panels give quick access to controls related to the content; use one for an inspector; simple controls | Inspectors are the system inspector column inside the window; the floating panels stay for the shelf, the palette and HUDs. |
| 136 | HIG Panels, HUD-style | Prefer standard panels; use colour sparingly; keep HUDs small | `AOMHUDContent`: one tone colour, a 40 pt glyph, at most two lines and a level bar. |
| 137 | [HIG Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) | A small amount of information, one popover at a time, never a warning | ⓘ popovers hold at most three sentences. Warnings use `AOMNotice` in the page. |
| 138 | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) (Mar 2026) | A reasonable default size, one sheet at a time, an alternative to Done | Customize Workspace is one sheet with Done (default, Return) and Reset Layout; Escape closes it. |
| 139 | [HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | Use alerts sparingly; never for common undoable actions or at launch; specific button titles | No alert for hiding a tile or removing a rule (they undo). Alerts keep verb titles ("Reset", "Cancel"). |
| 140 | [HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) (June 2025) | Support Full Keyboard Access; respect standard shortcuts; custom shortcuts only for frequent commands; modifiers in ⌃⌥⇧⌘ order | Pages ⌘1–⌘9, Back ⌘[, Forward ⌘], Inspector ⌥⌘I, Find ⌘F, palette ⌘K. Keycaps render modifiers in the HIG order. |
| 141 | [HIG Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices) (Oct 2026) | Consistent responses; don't redefine system trackpad gestures; padding for comfortable hit regions | Icon buttons keep 28 pt hit areas. Nothing is revealed only on hover; hover only shifts fills. |
| 142 | [HIG Searching](https://developer.apple.com/design/human-interface-guidelines/searching) (June 2026) | One place that finds everything; show the current scope; suggestions; respect search-history privacy | ⌘K is the app-wide search. Page fields name their scope ("Search rules"). Recent searches can be cleared. |
| 143 | [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) (June 2026) | Search as people type; scope bars start broad; tokens for common filters, paired with suggestions | `AOMScopeBar` defaults to All. Pages use `AOMSearchToken` for "App:" and "Kind:" filters with suggestions. |
| 144 | [HIG Launching](https://developer.apple.com/design/human-interface-guidelines/launching) | Launch instantly; restore the previous state | The window reopens on the last page with the sidebar, list widths and inspector as they were (`AOMLastPage`). |
| 145 | [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion) (Sep 2025) | Purposeful, optional, brief motion; none on frequent interactions; animated symbols where they help | Hover never animates position. Symbols pulse while something runs and bounce once on success; Reduce Motion turns all of it into a crossfade. |
| 146 | [HIG Writing](https://developer.apple.com/design/human-interface-guidelines/writing) (Dec 2025) | Be action oriented; build language patterns; give next steps on blank screens; clear error messages | Empty states end with one verb button. Errors read "Couldn't move "x" because …". |
| 147 | HIG Writing | Pick capitalization rules and apply them everywhere | Title Case for buttons, menu items and tool names; sentence case for everything else (b.13). |
| 148 | HIG Writing (Dec 2025) | Use possessive pronouns sparingly | "Workspace", "Rules", never "Your rules" or "My Workspace". |
| 149 | [HIG Inclusion](https://developer.apple.com/design/human-interface-guidelines/inclusion) | Plain language; define technical terms; people-first | "File kind" instead of UTI; tooltips explain terms like secure input. |
| 150 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) (Sep 2025) | No Liquid Glass in the content layer; use it sparingly; clear glass only over rich backgrounds | Glass for the toolbar, sidebar, palette, HUDs and toasts only, always the regular variant. |
| 151 | [HIG Offering help](https://developer.apple.com/design/human-interface-guidelines/offering-help) | Short, actionable tips with rules for who sees them; tooltips describe what a control does without repeating its name | `AOMTipCard`: two sentences and one action, once per page. Tooltips read "Turns Clipboard history on", not "Clipboard". |
| 152 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) (Dec 2025) | Choose items deliberately; a More menu for the rest; customizable on macOS; fewer backgrounds and tints | Every page follows the toolbar pattern in b.3, with at most three groups and secondary commands in a More pull-down. |
| 153 | [HIG Split views](https://developer.apple.com/design/human-interface-guidelines/split-views) | Keep the selection highlighted; allow drag between panes; thin divider; sensible pane limits | `AOMListDetail`: `List` selection, a hairline divider, list 240–360 pt, inspector 260–360 pt. |
| 154 | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) (June 2026) | Let people customize the sidebar; disclosure for groups; let people hide it | Tools, Productivity and Activity collapse and remember it; ⌃⌘S and the toolbar button hide the sidebar. |
| 155 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows) (June 2025) | Windows adapt fluidly to sizes; no custom window UI; nothing critical in a bottom bar | Every page is checked at 1320×820 and 1000×680. No bottom bars. |
| 156 | [HIG Modality](https://developer.apple.com/design/human-interface-guidelines/modality) | Modal only with a clear benefit; an obvious way out; confirm before losing work | Rules and actions edit in place. Only Customize Workspace and first-run steps are sheets. |
| 157 | [HIG Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data) | Offer choices instead of typing; accept drag and paste; validate as people type | Pop-ups for conditions, drops onto folder rows, token fields that reject invalid entries at once. |
| 158 | [HIG File management](https://developer.apple.com/design/human-interface-guidelines/file-management) | People's work is always kept; hide extensions by default; Quick Look | File rows show display names (the Finder's extension setting). Space previews a selected file with Quick Look. |
| 159 | [HIG Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) | Ask only when a feature needs access, and say why | A module asks for its permission when it is turned on; Workspace lists missing permissions only for modules that are on. |
| 160 | [HIG Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) | Haptics complement other feedback, stay short and optional | Snap and gesture haptics stay optional and always pair with a visual change. |
| 161 | [HIG Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) | Size the field to the expected text; show clipped text in an expansion tooltip | Token fields grow line by line. Truncated paths and names show the full text in a tooltip. |
| 162 | [HIG Combo boxes](https://developer.apple.com/design/human-interface-guidelines/combo-boxes) | A meaningful default and relevant choices | Value fields that also take typing ("Downloads", "Desktop") offer those choices in a menu. |

### WWDC sessions 2023–2026

| # | Source | Pattern | How AOM applies it |
|---|---|---|---|
| 163 | [WWDC23 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10148/) | The Inspector API, table refinements, better focus and keyboard input | `AOMListDetail` uses the system `.inspector`; module lists are `List`s with selection. |
| 164 | [WWDC23 Inspectors in SwiftUI: Discover the details](https://developer.apple.com/videos/play/wwdc2023/10161/) | The inspector is a trailing column with its own toolbar toggle and column width | Inspector width 260–360 pt (ideal 300) via `inspectorColumnWidth`; toggled by a toolbar button and ⌥⌘I. |
| 165 | [WWDC23 The SwiftUI cookbook for focus](https://developer.apple.com/videos/play/wwdc2023/10162/) | Focusable custom views, key-press handlers, focus sections | Tile grids are focus sections: arrow keys move between tiles, Return opens, Space toggles the module. |
| 166 | [WWDC23 Make features discoverable with TipKit](https://developer.apple.com/videos/play/wwdc2023/10229) | Tips teach a feature with eligibility rules and frequency control | Considered; AOM keeps the pattern (rules, frequency, one action) in `AOMTipCard` without TipKit's shared datastore (b.6). |
| 167 | [WWDC24 Customize feature discovery with TipKit](https://developer.apple.com/videos/play/wwdc2024/10070) | Tip groups show tips in order, one at a time | At most one tip per page, in a fixed order; a dismissed tip never returns. |
| 168 | [WWDC23 Animate symbols in your app](https://developer.apple.com/videos/play/wwdc2023/10258/) | Bounce, pulse and variable colour express state changes | Pulse while recording or a focus session runs; one bounce when a quick action succeeds. |
| 169 | [WWDC23 Explore pie charts and interactivity in Swift Charts](https://developer.apple.com/videos/play/wwdc2023/10037/) | Charts reveal exact values on selection | The Today week chart names each day's totals in its accessibility label and tooltip. |
| 170 | [WWDC24 Tailor macOS windows with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10148/) | Default size and placement, resizability, window restoration | The main window keeps its 980×600 minimum and restores its frame and last page. |
| 171 | [WWDC24 Work with windows in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10149/) | Scene and window state belongs to the scene | Page, history and sidebar state live in scene storage or `AOM…` defaults, not in globals. |
| 172 | [WWDC24 Catch up on accessibility in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10073/) | Labels, values, custom actions, conditional accessibility | Tiles expose Open and Turn On/Off as accessibility actions; counts are values. |
| 173 | [WWDC24 Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/) | Interruptible, spring-based animations | Tile reflow, sheet and inspector motion use the snappy and smooth springs from `AOMMotion`. |
| 174 | [WWDC24 Create custom visual effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10151/) | Scroll transitions and visual effects for expressive interfaces | Deliberately not used in content: AOM's content stays still; only numbers and symbols animate. |
| 175 | [WWDC25 Make your Mac app more accessible to everyone](https://wwdcnotes.com/documentation/wwdc25-229-make-your-mac-app-more-accessible-to-everyone/) (session 229) | Accessibility containers and sort priority; rotors; actions for hover-only interactions | Each Workspace section is a container; nothing is reachable only by hover. |
| 176 | [WWDC25 Principles of inclusive app design](https://developer.apple.com/videos/play/wwdc2025/316/) | Support several senses; provide customization; adopt accessibility APIs | State shows as glyph, words and colour together; Workspace can hide and reorder parts. |
| 177 | [WWDC25 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/) | Liquid Glass toolbars, toolbar spacers, drag and drop on macOS | Toolbar groups are separated with `ToolbarSpacer` on macOS 26+, plain grouping before. |
| 178 | [WWDC25 Design foundations from idea to interface](https://developer.apple.com/videos/play/wwdc2025/359/) | Answer "where am I, what can I do, where can I go" on every screen | Toolbar title (where), the page's one prominent action (what), sidebar and history (where to). |
| 179 | [WWDC26 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/) | Toolbar visibility priority and auto-minimizing; reordering API for lists, grids and sections | On macOS 27 toolbar items get priorities so search survives narrow windows; reordering uses the new API there and drag/drop before. |
| 180 | [WWDC26 Code-along: Build powerful drag and drop in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/271/) | Reordering, drag containers for several items, a custom drag lifecycle | Customize Workspace reorders quick actions; shelf and recent files drag several items at once. |
| 181 | [WWDC26 Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/) | Keyboard navigation, state restoration after restart, corner concentricity APIs | The status menu is fully keyboard navigable; the window restores state; inner radii stay concentric. |
| 182 | [WWDC26 Design intuitive search experiences](https://developer.apple.com/videos/play/wwdc2026/292) | Search fits the navigation model and helps people move, not just find | ⌘K opens pages, settings and actions; page fields filter in place. |
| 183 | [WWDC26 Refine accessibility for custom controls](https://developer.apple.com/videos/play/wwdc2026/220/) | Custom controls need actions and adjustable values for VoiceOver | `AOMTokenField`, `AOMConditionRow`, tiles and the status header expose their actions and values. |
| 184 | [WWDC26 Platforms State of the Union](https://developer.apple.com/kr/videos/play/wwdc2026/122/) | Every macOS window shares one tighter corner radius; Liquid Glass tuned for legibility | AOM never draws its own window corners or title bar; it takes the system's. |
| 185 | [WWDC26 Use SwiftUI with AppKit and UIKit](https://developer.apple.com/videos/play/wwdc2026/272/) | Observation drives SwiftUI hosted in AppKit hierarchies | HUD panels host `AOMHUDContent` in `NSHostingView`; the status menu stays native `NSMenuItem`s. |
| 186 | [WWDC26 Dive into lazy stacks and scrolling with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/321/) | Lazy containers for long content; reorderable views | Long lists (logs, history) are lazy; the fixed Workspace grids are plain stacks. |
| 187 | [WWDC23 Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160) | Narrow dependencies, stable identity | Each tile observes only its module's status object; sidebar badges observe only their service. |
| 188 | [WWDC23 Design with SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10115/) | Prototype with real data and iterate in the real medium | Every Workspace number is live; previews run the real app in an isolated data folder. |
| 189 | [Meet with Apple: Showcase on the new design and Liquid Glass](https://developer.apple.com/videos/play/meet-with-apple/208/) | Third-party apps adopt native components and keep brand in content | AOM's identity is its module hues in content; chrome is the system's. |

### Acclaimed Mac apps

| # | Source | Pattern | How AOM applies it |
|---|---|---|---|
| 190 | [Raycast Action Panel](https://manual.raycast.com/action-panel) | ⌘K shows every action for the selected item | Every tile, row and token has its full action list in a context menu; ⌘K lists page actions too. |
| 191 | [Raycast API: Action Panel](https://developers.raycast.com/api-reference/user-interface/action-panel) | The first action is primary (↵), the second secondary (⌘↵) | A tile's click is its primary action (open, or run); the switch or second button is the secondary. |
| 192 | [Raycast: Command Aliases and Hotkeys](https://manual.raycast.com/command-aliases-and-hotkeys) | Configure a command's hotkey from where it is used | Each quick action shows its hotkey on the tile and in Customize Workspace; Settings › Shortcuts lists every Productivity hotkey to change it. |
| 193 | [Things 3 for Mac keyboard shortcuts](https://culturedcode.com/things/support/articles/2785159/) | Every command has a shortcut, shown where the command is | Quick-action tiles show their shortcut under the name; tooltips add it to every button. |
| 194 | [Things 3: Quick Entry](https://culturedcode.com/things/support/articles/2249437/) | One global shortcut captures from anywhere without opening the app | Productivity entry points (Measure ⇧⌘7, Drop Shelf, Focus, Mute) run from anywhere and from Workspace. |
| 195 | [Linear: Invisible details](https://linear.app/blog/invisible-details) | Contextual menus everywhere show the action and its shortcut | Context menus everywhere (b.4); the shortcut appears in the matching main-menu item. |
| 196 | [Linear: Select issues](https://linear.app/docs/select-issues) | Act on a selection through the command bar or a right-click | List + detail pages act on the selected rows from the context menu, the toolbar and ⌘K alike. |
| 197 | [Linear changelog: Better menus](https://linear.app/changelog/2020-08-26-better-menus-and-view-options) | Right-click on every object type | Sidebar rows, tiles, attention rows, log rows and tokens all respond to right-click. |
| 198 | [Hazel: Previewing your rule](https://www.noodlesoft.com/kb/previewing-your-rule/) | Preview a rule against a file and see each condition match | Folder Rules' inspector shows a file with ✓ or ✗ beside each `AOMConditionRow`. |
| 199 | [Hazel: Understand the logic of rules](https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/create-edit-rules/understand-the-logic-of-rules/) | Conditions first, then actions in order | One editor pattern: an "If all of the following" header, condition rows, then action rows. |
| 200 | [Hazel 6.0 release notes](https://www.noodlesoft.com/kb/hazel-6-0-release-notes/) | Rule options; text recognition on demand; preview in the background | Previews and scans run off the main thread; the page shows "…" until results arrive. |
| 201 | [PopClip Basics](https://pilotmoon.com/popclip/guide/) | The bar appears on selection or after a 0.5 s press, above the pointer | Text Actions (D) draws its bar as floating chrome near the selection, with `AOMChromeSurface`. |
| 202 | [Default Folder X on Setapp](https://setapp.com/apps/default-folder-x) | A sidebar of recent, favourite and open folders beside Open and Save | Files (F) lists favourites and recents with `AOMPathRow`; Workspace's Files tile counts them. |
| 203 | [Dropover on the Mac App Store](https://apps.apple.com/lu/app/dropover-pro/id1355679052) | Shake while dragging, a shortcut or the menu bar opens a shelf | Drop Shelf is a quick action, a status-menu item and a hotkey: three ways to the same shelf. |
| 204 | [CleanShot X features](https://cleanshot.com/features) | Native look; an overlay to save, copy or drag the capture right away | Recent captures in Workspace drag out as files and have Copy and Show in Finder. |
| 205 | [Tower: Undo anything](https://www.git-tower.com/features/undo) | ⌘Z reverses almost any operation | Hiding tiles, moving quick actions and module edits register undo (b.4). |
| 206 | [Tower: Drag and drop](https://www.git-tower.com/features/drag-and-drop) | Drag to act; ⌥ changes the operation | Shelf and file drops copy with ⌥ and move otherwise, shown by the pointer badge. |
| 207 | [Fantastical help: adding events](https://flexibits.com/jp/fantastical/help/adding-events-and-tasks) | Natural-language input with a live preview of what was understood | Fields that parse (durations, sizes) show the parsed value live under the field. |
| 208 | [Ice](https://icemac.app/) | Visible and Hidden sections you arrange by dragging | Customize Workspace lists shown and hidden parts and reorders by drag. |
| 209 | [SoundSource menu bar controls](https://rogueamoeba.com/support/manuals/soundsource/?page=menu-bar-controls) | The menu bar icon reflects live state; subtle animation keeps it snappy | The status item's symbol reflects paused or off; HUDs animate briefly, never loop. |
| 210 | [Paste help](https://pasteapp.io/help/paste-on-mac) | The history is a resizable bar on the active display | The clipboard shelf stays a panel; Workspace links to it instead of copying it. |
| 211 | [NetNewsWire keyboard shortcuts](https://netnewswire.com/help/mac/6.1/en/keyboard-shortcuts) | Arrow keys move focus between panes; single keys act on the selection | In list + detail pages, → moves focus to the detail and ← back; Space toggles the selected item. |
| 212 | [Proxyman split view](https://proxyman.com/docs/basic-features/split-view) | Two panes per tab, each with its own filters and selection | Each list page keeps its own filter, selection and list width. |
| 213 | [Flighty](https://apps.apple.com/ca/app/flighty-live-flight-tracker/id1358823008) (Apple Design Award) | Live status first: the big time, its state colour and progress | `AOMStatusHeader`: one big live figure with its ring; the Focus tile shows the time left. |
| 214 | Things 3, Today list | One calm list with generous rows and a single accent for the current item | Rows stay 36–48 pt; selection is the system highlight. |
| 215 | Bear, editor and sidebar | Typography carries hierarchy; chrome can hide for writing | Hierarchy from text styles, not borders; the sidebar hides with ⌃⌘S. |
| 216 | Craft, document cards | Generous padding and one level of cards | 16 pt card padding; never a card inside a card. |
| 217 | Arc, command bar and Spaces | Colour identifies a space; one command bar finds anything | Module hues identify modules; ⌘K finds anything. |
| 218 | Tot, seven coloured dots | Colour as a quiet, consistent identity | Each module keeps one hue across tile, page header and HUD. |
| 219 | Nova, sidebar and inspector | A sidebar, an editor and a trailing inspector you toggle | The list + detail + inspector template. |
| 220 | Mimestream, sidebar | Native sidebar with counts only where they matter | Sidebar pills only for abnormal states or live sessions. |
| 221 | Ivory for Mac, timeline columns | Each column remembers its position and state | Pages remember scroll-independent state: filter, selection, widths. |
| 222 | CARROT Weather, layout editor | People choose and order the sections they see | Customize Workspace hides and reorders parts. |
| 223 | Day One, "On This Day" | A small, relevant summary of the past on the home screen | Workspace's Recent and Today cards. |
| 224 | Shottr, pixel ruler | Measuring is one shortcut away and shows numbers on screen | Measure Screen (E) is a quick action with its shortcut. |
| 225 | BetterTouchTool, trigger list | Triggers grouped by source, each with its action | Automation (B) keeps triggers by source; Workspace counts them. |
| 226 | Swish, gesture HUD | A short HUD names the action that just ran | `AOMHUDContent` for global confirmations. |
| 227 | Mona for Mac, settings | Many options organised into a few clear groups | Settings-style pages group options in at most 8-row sections. |

### Apple's Mac apps on macOS 26/27

| # | Source | Pattern | How AOM applies it |
|---|---|---|---|
| 228 | System Settings, View menu | Back ⌘[, Forward ⌘], then every pane | AOM's View menu has Back, Forward and every page. |
| 229 | System Settings, toolbar | Back and forward buttons beside the title | Back and Forward buttons at the leading edge of the toolbar. |
| 230 | System Settings › General › Login Items | + and − buttons under a list | `AOMAddRemoveBar` under every module list. |
| 231 | System Settings, search | Results open the pane and highlight the setting | ⌘K results open the page and scroll to the section. |
| 232 | Finder, path bar (View › Show Path Bar) | The location as a path in the window body | `AOMPathRow` shows ~/Folder paths with the Finder icon. |
| 233 | Finder, Go menu | ⌘[ and ⌘] move through history | AOM keeps a Back/Forward page history. |
| 234 | Finder, column view preview | The last column previews the selection | The inspector previews the selected rule or file. |
| 235 | Finder, toolbar | Customize Toolbar… and a consistent item order | The per-page toolbar order in b.3. |
| 236 | Mail › Settings › Rules | "If any/all of the following conditions are met" with − + per row | `AOMConditionGroupHeader` and `AOMConditionRow`. |
| 237 | Mail, search tokens | "From:" and "Subject:" tokens in the search field | `AOMSearchToken` for page filters. |
| 238 | Notes, sidebar | Collapsible folder groups that remember their state | Collapsible sidebar sections. |
| 239 | Reminders, list sections | Sections inside a list, dragged to reorder | Quick actions reorder by drag. |
| 240 | Passwords, sidebar | Security recommendations shown as a count to fix | The Workspace sidebar pill counts what needs fixing. |
| 241 | Journal (macOS 26), Insights | Streaks and counts as quiet summary cards | Today card figures. |
| 242 | Freeform, inspector toolbar | Formatting controls appear for the selection | The inspector shows controls for the selected item only. |
| 243 | Photos, sidebar Pinned | People pin and reorder what they use | Pinned automations join the quick actions. |
| 244 | Music, context menus | Every song, album and playlist has one | Context menus everywhere. |
| 245 | Shortcuts for Mac, editor | An action list with a library inspector; drag actions in | Rule editors: conditions and actions as rows; the inspector holds the library or preview. |
| 246 | Shortcuts for Mac, Automations | Triggers such as a folder change start a shortcut | Folder Rules runs on folder changes the same way. |
| 247 | Keynote and Pages, Format inspector | A toolbar button and ⌥⌘I show the inspector | Inspector toggle on the toolbar's trailing edge, ⌥⌘I. |
| 248 | Xcode, navigator and inspectors | Three panes: list, editor, inspector, each collapsible | List + detail + inspector template. |
| 249 | Console, log stream | Live entries with time stamps, a Pause, and filter tokens | `AOMLogRow`/`AOMLogSection` with time stamps and Clear. |
| 250 | Activity Monitor, toolbar | A scope control and a search field, nothing else | Toolbar pattern: scope, view options, primary, search. |
| 251 | Screen Time, limits | Progress toward a limit as a ring or bar | `AOMProgressRing` for Focus sessions. |
| 252 | Clock (Mac), Timers | Big digits with a progress ring and Pause/Cancel | `AOMStatusHeader` with Display digits and large actions. |
| 253 | Control Center (macOS 26), Edit Controls | Add, remove and rearrange controls in place | Customize Workspace: show, hide and reorder tiles and quick actions. |
| 254 | Control Center, modules | A control's glyph fills when on | Quick actions that toggle (Focus, Mute) show their state in the glyph and label. |

## (b) AOM 3.4 spec

### b.0 What stays from 3.3.6

Kept as is: the macOS text styles (Body 13 base, nothing in a sentence below 11), regular controls, the system
`NavigationSplitView` sidebar with system rows, the system toolbar title and subtitle, opaque `surface` cards on
the `canvas`, one card level, squircle module badges (`AOMRadius.squircle`), the 8 pt rhythm (24 pt margins and
section gaps, 16 pt card padding, 12 pt tile gaps), Liquid Glass only for chrome, the Workspace order (status,
setup, needs attention, modules, quick actions, overview) and every token name in AOMTokens.swift. 3.4 adds to
this; no existing token changes value except the two module hues in b.8.

### b.1 Information architecture: 12 pages

| Sidebar section | Page (`AOMMainTab`) | Toolbar title | Key | Template |
|---|---|---|---|---|
| (no header) | Workspace (`.home`) | Workspace | ⌘1 | Dashboard |
| Tools | Automation (`.gestures`) | Automation | ⌘2 | List + detail |
| Tools | Window Tiling (`.snapping`) | Window Tiling | ⌘3 | Settings-style |
| Tools | Capture (`.capture`) | Capture | ⌘4 | Dashboard |
| Tools | Clipboard (`.clipboard`) | Clipboard | ⌘5 | List + detail |
| Tools | Audio (`.audio`) | Audio | ⌘6 | Settings-style |
| Tools | System Tools (`.tools`) | System Tools | ⌘7 | Dashboard |
| Productivity | Folder Rules (`.folderRules`) | Folder Rules | ⌘9 | List + detail + inspector |
| Productivity | Text Actions (`.textActions`) | Text Actions | — | List + detail |
| Productivity | Files (`.files`) | Files | — | Dashboard (shelf, favourites, recents) |
| Productivity | Focus (`.focus`) | Focus | — | Status header + settings-style |
| Activity | Insights (`.insights`) | Insights | ⌘8 | Dashboard |

`AOMMainTab.shortcutKey` gives ⌘1…⌘9 to the first nine cases in declaration order, so Insights keeps ⌘8 and
Folder Rules gets ⌘9. The View menu shows the real keys; pages without a key are still listed there and in ⌘K.

- Sidebar sections Tools, Productivity and Activity are collapsible and remember it (`AOMSidebarCollapsed`).
- Back/Forward history: every page change is recorded (at most 50); ⌘[ and ⌘] and the toolbar chevrons move
  through it. Reopening the app restores the last page (`AOMLastPage`).

### b.2 Page templates

1. **Dashboard** (Workspace, Capture, System Tools, Insights, Files): `AOMPage` (1200 pt max, 24 pt margins),
   sections of `AOMSection` or grids of tiles. Grids use column counts that divide their item count (6 → 3 or 2,
   4 → 4 or 2, 10 → 5) so no row is ragged. Never a half-empty window at 1000×680 or 1320×820.
2. **List + detail (+ inspector)** (Automation, Clipboard, Folder Rules, Text Actions): `AOMListDetail`.
   - List column 240–360 pt (ideal 280, `@AppStorage("AOM<Module>ListWidth")`): `AOMListColumn` with an optional
     header (search field or `AOMScopeBar`), a `List(selection:)` of `AOMListRow`s (type-to-select, arrows,
     system highlight), and `AOMAddRemoveBar` (+, −, ⋯).
   - Detail ≥ 420 pt: `AOMPageHeader` for the selected item (name, on/off switch trailing), then `AOMSection`s
     (`AOMConditionGroupHeader` + `AOMConditionRow`s for rules; `AOMSettingRow`s for options), in an `AOMPage`
     with `maxWidth: AOMSize.readableWidth`.
   - Inspector 260–360 pt (optional): `AOMInspector` with `AOMInspectorSection`s (Preview, History, Info);
     toolbar toggle `sidebar.trailing` at the trailing edge, ⌥⌘I.
   - Empty list: `AOMEmptyState` in the detail ("No rules yet" + "New Rule"); the list shows nothing else.
3. **Settings-style** (Window Tiling, Audio, Focus options): `AOMPage(maxWidth: AOMSize.readableWidth)` with
   `AOMSection` + `AOMSettingRow`/`AOMToggleRow`. Wider than 1100 pt: two related sections side by side.
   A module with live state puts `AOMStatusHeader` first (Focus: the session timer).

### b.3 Toolbar pattern (every page)

Leading to trailing, each group only when the page has it:
1. Back and Forward chevrons (shell, `.navigation`), then the system title and subtitle.
2. Scope: a pull-down or segmented control that filters the page ("All Applications ▾").
3. View options: list/grid, sort (symbols with `.help`).
4. The page's one primary action: + New … (at most one prominent item).
5. Search (`.searchable`, placeholder names the scope) at the trailing edge.
6. Inspector toggle (list + detail pages with an inspector), last.

At most three visible groups besides navigation; anything else goes in a More (⋯) pull-down. On macOS 26+
groups are separated with `ToolbarSpacer`; on macOS 27 items carry visibility priority (search and the primary
action highest). A user-customizable toolbar (`.toolbar(id:)`) is not adopted in 3.4: every item on every page
would need a stable id from five different owners, and the fixed pattern above already keeps pages predictable.

### b.4 Interaction layer

- **Hover**: rows and cards shift their fill (`AOMColor.rowHover`, `surfaceHover`); links deepen their label;
  nothing moves or scales; nothing appears only on hover (#141, #175).
- **Press**: fills darken (`rowPressed`, `surfacePressed`) for the duration of the press; no scale on content.
- **Focus**: system focus rings for controls; list selection for rows; `aomFocusRing` for custom focusable
  tiles. Full Keyboard Access reaches every control in reading order.
- **Keyboard**:

  | Keys | Action |
  |---|---|
  | ⌘1 … ⌘9 | Go to page (View menu) |
  | ⌘[ / ⌘] | Back / Forward |
  | ⌃⌘S | Show/Hide Sidebar (system) |
  | ⌥⌘I | Show/Hide Inspector (list + detail pages) |
  | ⌘F | Focus the page's search field |
  | ⌘K | Command palette (or its free alternative) |
  | ⌘N | New item on list pages (the primary action) |
  | ⌫ / ⌘⌫ | Remove the selected item (undoable) |
  | Space | Toggle the selected module or item; Quick Look for files |
  | ↑ ↓ ← → | Move in lists and tile grids; ← → between list and detail |
  | Return | Open the focused tile or row |

- **Context menus on every item** (flat, no shortcuts, unavailable items hidden):
  - Sidebar row: Open, Turn On/Off (modules with a switch), Show/Hide on Workspace (modules).
  - Module tile: Open, Turn On/Off, Hide from Workspace, Customize Workspace….
  - Quick action: Run, Open <Module>, Move Left, Move Right, Remove from Quick Actions, Customize Workspace….
  - Attention row: the row's action, Dismiss (suggestions only).
  - Activity, log and history rows: Open, Copy, Show in Finder (files).
  - Token: Copy, Remove. Folder row: Show in Finder, Copy Path, Choose…, Remove.
- **Drag and drop**: `.draggable` / `.dropDestination` only; targets use `aomDropTarget`; files drag out as URLs;
  reordering is undoable; every drag has a menu or button alternative (#98).
- **Undo**: `AOMUndo.perform(name, undoManager:, perform:, revert:)` for every reversible change made outside a
  text field (hide tile, move or remove a quick action, remove a rule or action). Removing never asks; the toast
  offers Undo for `AOMMotion.undoToastSeconds` (6 s) and ⌘Z works afterwards.
- **Type-to-select**: lists are `List`s with text rows so the system type-select works; tile grids follow focus.
- **Search scopes and tokens**: ⌘K is global. A page search filters that page; its placeholder names the scope;
  `AOMScopeBar` defaults to All; `AOMSearchToken` for structured filters with suggestions.

### b.5 Feedback

| Situation | Pattern | Component |
|---|---|---|
| An action in the window succeeded | Toast, success tone, 2.5 s | `AOMToastModel.show("Ran …")` + `.aomToast(model)` |
| A reversible change | Toast with Undo, 6 s, ⌘Z | `show("Tile hidden", action: { … })` |
| An action failed | Toast, danger tone, the reason | `show("Couldn't … because …", tone: .danger)` |
| A global action outside the window | HUD, about 1.2 s, never takes focus | `AOMHUDContent` in a non-activating panel |
| Something to fix on a page | Inline notice at the top of the section | `AOMNotice` (one verb button) |
| Something to fix anywhere | Workspace Needs attention + sidebar pill | `WorkspaceAttention` rows |
| A task in progress | Determinate bar with "3 of 12" and Cancel | `AOMProgressRow` |
| A module running | Status header ring, tile glyph pulse, sidebar pill | `AOMStatusHeader`, `AOMModuleTile(running:)` |
| A value not known yet | "…" | — |

Errors never use alerts unless data would be lost. Notifications only for events that happen while AOM is not
frontmost and that people asked for (Folder Rules run summaries).

### b.6 Empty states and onboarding

- A whole empty page or detail: `AOMEmptyState` (system ContentUnavailableView): 40 pt glyph, title, one
  sentence, one primary button ("New Rule").
- An empty section inside a card: `AOMInlineEmpty` (20 pt glyph, one Body sentence, at most one button, 48 pt).
- Tips: `AOMTipCard` (glyph, Headline title, one or two Callout sentences, one link-style action, ×), at most one
  per page, shown above the first section, remembered under `AOMTipDismissed.<id>`. Writing: what it does and
  how to start ("Drag a folder here to watch it.").
- TipKit is not adopted: `Tips.configure()` must run at launch and writes a shared datastore, and the brief
  forbids side effects in isolated previews and unit tests. `AOMTipCard` keeps TipKit's pattern (#166, #167)
  with plain per-tip defaults.
- First run (Workspace setup, the welcome tour) stays as in 3.3.6.

### b.7 Motion (Reduce Motion aware)

| Token | Curve | Use |
|---|---|---|
| `AOMMotion.quick` | snappy 0.2 s | hover fills, press, switches, pill changes |
| `AOMMotion.standard` | smooth 0.3 s | expand/collapse, tile reflow, toasts, rings |
| `AOMMotion.panel` | smooth 0.35 s | inspector, drawer, palette, sheets |
| `AOMMotion.success` | bouncy 0.4 s | once per success (none under Reduce Motion) |
| `AOMMotion.settle` | snappy 0.3 s | landing after a drag |

- Numbers change with `.contentTransition(.numericText())` (opacity under Reduce Motion).
- Symbols: `.symbolEffect(.pulse)` while running (recording, focus), `.bounce` once on success; never looping
  decoration. Under Reduce Motion every movement becomes `AOMMotion.crossfade` (0.15 s) or nothing.
- Nothing animates on hover except fills. No parallax, no scroll transitions in content (#174).

### b.8 Colour and module hues

Roles stay: the accent is interaction, semantic colours are status (always with a glyph and words), module hues
are identity in content (squircles on tiles, headers, HUD glyphs) and only while the module is on.

| Module | Hue (light / dark) | Glyph | White-glyph contrast |
|---|---|---|---|
| Automation | systemIndigo | `bolt.fill` | ≥ 4.5 |
| Window Tiling | #00848C / #0A9AA4 | `rectangle.split.2x2.fill` | 4.6 / 3.4 |
| Capture | systemPurple | `camera.viewfinder` | ≥ 3.5 |
| Clipboard | systemBrown | `doc.on.clipboard.fill` | ≥ 3.1 |
| Audio | systemPink | `waveform` | ≥ 3.1 |
| System Tools | #7C7C82 | `wrench.and.screwdriver.fill` | 4.3 |
| Folder Rules | #1E7B34 / #2E964A (green) | `folder.badge.gearshape` | 5.3 / 3.8 |
| Text Actions | #B07800 / #B98500 (amber) — **changed from #C46200** | `character.cursor.ibeam` | 3.8 / 3.3 |
| Files | systemBlue | `folder.fill` | 4.0 / 3.6 |
| Focus | #D2560A / #E8650F (tangerine) — **changed from systemRed** | `timer` | 4.1 / 3.3 |

Focus moved off red because red already means danger and recording in AOM (#37): a running session must not read
as an error or a recording. Text Actions moved to amber so it no longer sits on Focus's orange.

New colour roles (AOMTokens.swift): `focusRing` (keyboardFocusIndicatorColor), `selection` and
`selectionInactive` (system selection colours), `rowHover` and `rowPressed` (tertiary system fill at 70% / 100%),
`dropWash` (accent 12%), `field` (textBackgroundColor).

### b.9 Typography, spacing, density, iconography

New tokens (all existing ones keep their values):

| Token | Value | Use |
|---|---|---|
| `AOMFont.display` | Large Title 26 semibold, monospaced digits | The one big figure of `AOMStatusHeader` |
| `AOMFont.timestamp` | Subheadline 11, monospaced digits | Log and history time stamps |
| `AOMFont.token` | Callout 12 | Token pills |
| `AOMSize.moduleTileMin` | 224 | Workspace module tiles (3 columns from 696 pt) |
| `AOMSize.quickActionMin` | 132 | Quick-action tiles (5 columns from 700 pt) |
| `AOMSize.sectionTitleHeight` | 22 | `AOMSectionTitle` row (was a raw 22) |
| `AOMSize.moduleListRange` / `moduleListIdeal` | 240–360 / 280 | List column of list + detail pages |
| `AOMSize.detailMinimum` | 420 | Detail column minimum |
| `AOMSize.inspectorWidth` / `inspectorIdeal` | 260–360 / 300 | Inspector column |
| `AOMSize.tokenHeight` / `tokenFieldMinHeight` | 22 / 28 | Token pills and fields |
| `AOMSize.logRow` | 28 | Live log rows |
| `AOMSize.toastMaxWidth` | 520 | Toasts |
| `AOMIcon.statusBadge` / `statusRing` | 48 / 64 | Status header squircle and ring |
| `AOMIcon.listBadge` | 24 | Squircles in module item lists |
| `AOMIcon.hudGlyph` | 40 | HUD glyph frame |
| `AOMMotion.toastSeconds` / `undoToastSeconds` | 2.5 / 6 | Toast durations |

- Density: rows 36 pt (control), 48 pt (with a description), 28 pt (logs, dense lists), 24 pt (tables).
  Inspectors use `.controlSize(.small)`; everything else regular.
- Glyphs next to text take that text's style (`.font(AOMFont.body)` + `.imageScale`), never a fixed point size.
  The 3.3.6 leftovers are fixed: `AOMInfoButton` takes `textStyle` (Body by default; Headline in section titles,
  Title 3 in page headers), `AOMModeButton` draws Body at the large symbol scale, `AOMSectionTitle` uses
  `AOMSize.sectionTitleHeight`.
- Iconography: SF Symbols only; hierarchical in rows, monochrome white in squircles, palette for status; filled
  variants in squircles and the status menu, outline in the sidebar (the system tints them).

### b.10 Materials and Liquid Glass (macOS 26+, with fallbacks)

| Surface | macOS 26+ | macOS 14–25 | Reduce Transparency / Increase Contrast |
|---|---|---|---|
| Toolbar, sidebar | System Liquid Glass, scroll edge effect | System materials | System |
| ⌘K palette, toasts | `aomChrome` (`.glassEffect(.regular)`) | `.popover` / `.hudWindow` material + hairline | Opaque `raised` + 1 pt border |
| HUD panels | `aomFloatingSurface(.hud)` | `.hudWindow` material | Opaque + border |
| Buttons on chrome | `.glass` / `.glassProminent` | `.bordered` / `.borderedProminent` | — |
| Cards, tiles, lists, forms, inspectors | Opaque `surface` / `canvas` | same | 1 pt `strongLine` border |

Never glass in content, never glass on glass, never a hand-made blur, never an extra shadow on glass.

### b.11 Dark mode and Increase Contrast

- Every colour is a dynamic token; nothing hard-codes white or black text except white glyphs on hues.
- Increase Contrast: hairlines become 1 pt `strongLine`, washes go from 12% to 22%, pills and tokens get a 1 pt
  border, focus rings stay 3 pt. Differentiate Without Color adds the tone glyph to every pill.
- Every new screen is checked in light and dark at 1320×820 and 1000×680.

### b.12 New components (AOMModuleKit.swift)

| Component | Use | API sketch |
|---|---|---|
| `AOMListDetail` | List + detail + optional inspector | `AOMListDetail(listWidth: $w, showsInspector: $i) { list } detail: { … } inspector: { … }` |
| `AOMListColumn` | Header, rows, footer | `AOMListColumn(header: { search }, rows: { List(selection:) {…} }, footer: { AOMAddRemoveBar(…) })` |
| `AOMAddRemoveBar` | + − ⋯ under a list | `AOMAddRemoveBar(addLabel: "New Rule", add: …, removeLabel: "Delete Rule", remove: selection == nil ? nil : …) { Button("Duplicate") {…} }` |
| `AOMInspector`, `AOMInspectorSection` | Inspector content | `AOMInspector { AOMInspectorSection("Preview") { … } }` |
| `AOMConditionGroupHeader` | "If [all ▾] of the following are true" | `AOMConditionGroupHeader(match: $rule.match)` |
| `AOMConditionRow` | One condition or action | `AOMConditionRow(canRemove: n > 1, add: …, remove: …) { Picker…; Picker… } value: { TextField… }` |
| `AOMConditionMatch` | all / any / none | `enum`, Codable |
| `AOMTokenField`, `AOMTokenPill` | Extensions, app names, words | `AOMTokenField(tokens: $exts, placeholder: "Add extension", suggestions: […], normalize: { $0.lowercased() })` |
| `AOMPathRow` | A folder or file | `AOMPathRow(url: folder, choose: { folder = $0 }, remove: …)`; drop a Finder folder on it |
| `AOMStatusHeader` | Big live figure | `AOMStatusHeader(.focus, active: running, title: "Deep work", figure: "24:12", unit: "left", detail: "Ends at 15:30", progress: 0.4) { Button("Stop") {…} }` |
| `AOMProgressRing` | Determinate ring | `AOMProgressRing(progress: 0.4, tint: AOMModule.focus.hue)` |
| `AOMLogEntry`, `AOMLogRow`, `AOMLogSection` | Live activity | `AOMLogSection("Activity", entries: log, clear: { … }) { entry in Button("Undo") {…} }` |
| `AOMProgressRow` | A running task | `AOMProgressRow(title: "Optimizing images", progress: 0.25, detail: "3 of 12", cancel: …)` |
| `AOMInlineEmpty` | Empty card row | `AOMInlineEmpty(symbol: "tray", message: "No files yet.", actionTitle: "Add Folder…", action: …)` |
| `AOMTipCard` | One tip per page | `AOMTipCard(id: "folderRules.drop", symbol: "folder.badge.plus", title: "Watch a folder", message: "…")` |
| `AOMHUDContent` | HUD panel content | `AOMHUDContent(symbol: "mic.slash.fill", title: "Microphone Muted", tone: .warning)` |
| `AOMIconButton` | 28 pt symbol button | `AOMIconButton("plus", label: "Add Condition") { … }` |
| `AOMFlowLayout` | Wrapping chips | `AOMFlowLayout { ForEach … }` |
| `AOMUndo` | Undo with redo | `AOMUndo.perform("Delete Rule", undoManager: undoManager, perform: {…}, revert: {…})` |
| `AOMSearchToken` | Search tokens | `.searchable(text: $q, tokens: $tokens) { Label($0.title, systemImage: $0.symbol ?? "tag") }` |
| `aomHoverHighlight`, `aomFocusRing`, `aomDropTarget` | Interaction layer | modifiers |
| `AOMToastModel.show(_:tone:seconds:actionTitle:action:)` + `.aomToast(model)` | Toasts with tone and Undo | existing `show(_:)` and `.aomToast(message)` keep working |

Existing components unchanged in name and signature: `AOMPage`, `AOMPageHeader`, `AOMSection`,
`AOMSectionTitle`, `AOMSettingRow`, `AOMToggleRow`, `AOMInfoButton` (new optional `textStyle:`), `AOMStatusPill`,
`AOMModuleBadge`, `AOMModuleTile`, `AOMNotice`, `AOMEmptyState`, `AOMListRow`, `AOMScopeBar`, `AOMCardLink`,
`AOMModeButton`, `AOMStatStrip`, `AOMKeycap`, `AOMShortcutKeys`.

### b.13 Writing

- Title Case: buttons, menu items, tool and page names, toolbar items, HUD titles ("Microphone Muted").
- Sentence case: section titles, descriptions, tips, toasts, empty-state sentences.
- Ellipsis when more input follows (Choose…, Customize Workspace…, Uninstall App…).
- Toasts: past tense, what happened ("Tile hidden", "Moved 3 files to Invoices"). Errors: "Couldn't … because …".
- Empty states: what is missing and the one next step ("No rules yet. New Rule").
- No possessives ("Your…"), no jargon without a tooltip, no exclamation marks.

### b.14 Shell, menus and status menu

- Sidebar: `List(.sidebar)` with system rows; sections Workspace (no header) / Tools / Productivity / Activity,
  collapsible; pills only for abnormal or live states: Workspace ⚠ n (permissions), Automation Paused, Capture
  Rec/Paused, Clipboard Paused, Audio Off/Direct/AirPlay/Effects, a Productivity module ⚠ 1 when its
  `AOMModuleStatus.attention` is set, Focus On while a session runs. Context menu per row (b.4).
- Toolbar: b.3. The shell adds Back/Forward; Workspace adds Customize (`slider.horizontal.3`) beside New Automation.
- Window: content minimum 980×600 (unchanged), frame autosaved by the system, last page restored.
- View menu: Back ⌘[, Forward ⌘], every page with its key, Show/Hide Sidebar (system), Customize Workspace….
- Status menu (`makeStatusMenu`): sections Capture, Clipboard, Windows, Productivity (module items, built per
  click), then Keep Awake and Automation, Open All of MacOS and Settings…, More, Quit. Title Case, verbs,
  checkmarks for toggles, one submenu level, one symbol per top-level item, every item also reachable elsewhere.

### b.15 Workspace 3.4

Top to bottom, each part only when it has real content:
1. Status header (3.3.6 hero): plain while all is well, a tinted notice with permission chips when not.
2. Setup (first run), unchanged.
3. Needs attention: permissions, suggestions, and each Productivity module's `attention` with Open.
4. Tools: the six 3.3.6 tiles, 3 columns (2 below 696 pt), "n of 6 on".
5. Productivity: Folder Rules, Text Actions, Files, Focus as `AOMModuleStatusTile`s reading
   `AOMModuleStatusBoard`, 4 columns from 932 pt, 2 below, "n of 4 on".
6. Quick actions: 10 by default in 5 columns (2 rows at both window sizes): Capture Area, Capture Window, Record
   Screen, Copy Text, Clipboard History, Measure Screen (`ScreenRulerModule.measure()`), Drop Shelf
   (`FilesModule.showShelf()`), Focus Session (`FocusModule.toggleSession()`), Mute Microphone
   (`MicMuteModule.toggleMute()`), Window Switcher; then pinned automations. Horizontal tiles when a cell is at
   least 190 pt, stacked (glyph over name) below. Drag or Move Left/Right to reorder; remove from the context
   menu; all undoable.
7. Overview: Recent activity, Today, This Mac (3.3.6), three columns from 960 pt.

Customize Workspace (toolbar button, View menu, tile and quick-action context menus): a sheet with Shown/Hidden
switches for Tools, Productivity, each module tile, Quick actions (each one, reorderable), Recent activity,
Today and This Mac; Reset Layout; Done. Keys: `AOMWorkspaceHidden` (part ids), `AOMWorkspaceQuickActions`
(ordered ids). Needs attention and the status header can't be hidden (they carry critical state).

### b.16 Patterns for the five features from the user's app analysis (added 31 Oct)

The user reverse-engineered Rapidmg, AppCleaner, TextSniper, Mission Control Plus and Raycast's Homebrew
extension and asked that AOM consider five features. A owns none of their engines; this section fixes how they
look and behave so whichever agent builds them (the integrator assigns; suggested owners in brackets) lands on the
same patterns. The brief's behaviour rules apply on top: destructive work asks first and moves to the Trash,
processes use argument arrays with timeouts off the main thread, failures say why.

| Feature | Where it lives | UI pattern | Rules |
|---|---|---|---|
| Auto DMG install (Rapidmg) [C, already in Folder Rules] | A built-in Folder Rules rule ("Install apps from disk images in Downloads"), off by default | The rule's detail is a normal `AOMConditionGroupHeader` + `AOMConditionRow`s (Kind is Disk Image) with one action row "Install the app and move the disk image to the Trash". Each install is an `AOMLogRow` (Show in Finder, Open) and one summary notification per run | Never replace an app in /Applications without asking: an existing app with the same name gets an alert ("Replace “X” in Applications?" Replace / Keep Both / Cancel); the old copy goes to the Trash. Detach in all paths; never `-force` unless the normal detach failed. A disk image without exactly one app logs "Skipped: no app inside" instead of guessing. |
| App uninstaller with leftovers (AppCleaner) [I, System Tools] | System Tools › Apps: Uninstall App… (an open panel, or drop an app on the row) | A review sheet: the app and each leftover as an `AOMPathRow` with a checkbox and its size in the accessory, grouped Application Support / Caches / Preferences / Containers / Logs…, the selected total in the footer, Move to Trash as the destructive button, Cancel as default | Matches on the bundle id are checked; matches on the name only are listed unchecked (a name like "Notes" matches other apps' files). Never Apple apps, AOM itself or a running app (ask to quit first). Everything goes to the Trash (Finder's Put Back undoes it); the toast says "Moved 14 items (1.2 GB) to the Trash". |
| Additive copy and direct OCR (TextSniper) [Capture/Clipboard owners; TextCaptureInstant and ClipboardStore exist] | A Capture setting "Add to the clipboard instead of replacing" and a Copy Text option to skip saving the image | In the window: a toast "Added to clipboard · 3 lines". Outside it: `AOMHUDContent(symbol: "doc.on.clipboard", title: "Added to Clipboard", detail: "3 lines")` for about 1.2 s, with the optional capture sound | Additive mode shows its state wherever Copy Text is offered (a checkmark in the menu, a pill on the Capture page) so a person always knows the next copy appends. Recognition runs off the main thread; nothing touches the disk when the option is on. Secure input and password fields are never read. |
| Hover close in Mission Control (Mission Control Plus) [owner of MissionControlOverlayService] | Mission Control, over each window thumbnail | A 20–24 pt circular close button in the thumbnail's top-leading corner, drawn with `AOMFloatingIconButtonStyle(destructive: true)` (glass on macOS 26, material before), shown while the pointer is over that thumbnail | The one hover-only control in AOM (Mission Control is a transient overview); the W / ⇧W keys stay the keyboard path. Closing presses the window's own close button through Accessibility (`kAXCloseButtonAttribute`), so unsaved documents still ask. The overlay panel never takes focus and goes away with Mission Control. |
| Homebrew outdated and cleanup (Raycast Homebrew) [I, System Tools, already in its scope] | System Tools › Homebrew | Header row "12 outdated · Homebrew 4.x" with Check Now; a list of `AOMListRow`s "name  1.2 → 1.3" with Upgrade; Upgrade All and Clean Up as buttons; a running task is an `AOMProgressRow` with Cancel; output goes to an `AOMLogSection` | Network and brew runs only after a click (no background polling on 8 GB). Find brew at /opt/homebrew/bin/brew or /usr/local/bin/brew and say so if neither exists. Clean Up first shows how much it will free (`brew cleanup -n -s`) and asks. Read pipes while the process runs (large JSON output fills the pipe) with a timeout. |

Workspace can offer any of these as quick actions once their entry points exist: each one is one new case in
`WorkspaceQuickActionKind` (title, symbol, module, help, shortcut, run) in WorkspaceCustomization.swift.

### b.17 Four more features from the user's routine, and Paste parity for the clipboard (added 31 Oct)

The user proposed four new features (none duplicates an existing AOM tool) and reported a clipboard regression.
As in b.16, A fixes the look and behaviour; the integrator assigns the engines (suggested owners in brackets).

| Feature | UI pattern | Rules |
|---|---|---|
| Shake-to-Shelf (Dropover, Yoink) [F: `FilesModule.showShelf()` already owns the shelf] | Shaking the pointer during a file drag (3 direction changes within 0.5 s) opens the existing drop shelf beside the pointer as floating chrome (`aomFloatingSurface(.panel)`, 12 pt from the pointer, kept on screen). Shelf actions: Drag All, Compress to ZIP, AirDrop (the system share sheet), Clear. | Off by default, one switch in Files › Shelf ("Shake while dragging opens the shelf") with ⇧-while-dragging as the alternative. The monitor exists only while the switch is on, sees only `.leftMouseDragged` and does nothing outside a drag (no cost when idle, #186). The shelf never takes focus; files stay where they are until dropped. ZIP goes next to the first file, never overwrites. |
| Keyboard click hints (Homerow, Vimac) [D or H; the message's section for it was empty] | A shortcut overlays two-letter hint labels on the clickable elements of the front window: 22 pt capsules (`AOMKeycap` look, Callout semibold), the accent fill only on the matching prefix, Escape cancels. | Labels come from Accessibility, off the main thread, with `AXUIElementSetMessagingTimeout`; never over secure text fields or while secure input is on; the overlay panel ignores the mouse and disappears on any app switch. |
| Menu shortcut sheet (KeyClu) [H: menu search already parses the front app's menu bar] | Holding ⌘ for 1.2 s shows the front app's menu shortcuts as a centred HUD sheet: columns per top-level menu (File, Edit, View…), each row the item title with `AOMShortcutKeys` caps trailing; releasing ⌘ hides it at once. | Off by default (Settings › Shortcuts, "Hold ⌘ to show the app's shortcuts"), never while another modifier or a mouse button is held, never in full-screen games; hold time adjustable 0.8–2 s. Parsing runs off the main thread and is cached per app version. AOM's own gesture Cheat Sheet stays separate. |
| Smart link router and clean URLs (Velja, Choosy) [H: deep links and quicklinks] | Settings › Links: a list of rules (`AOMConditionRow`: "Host contains uos.ac.kr" → "Open in Safari"), a "Remove tracking parameters" switch with the parameter list as an `AOMTokenField` (utm_*, fbclid, gclid, si, igshid), and ⌥-click shows a compact browser picker (a menu at the pointer listing installed browsers with their icons). | AOM routes links only after the person makes it the default browser in System Settings (an explicit choice, explained first); unknown links go to the browser picked as fallback. App links (Figma, Zoom, Notion) open the app only when it is installed, otherwise the web page. Nothing is logged except the rule that matched. |

**Clipboard shelf and preview keep Paste's design (exception to the 3.4 restyle).** The user reports that in
Paste a single click on an item's title in the preview starts editing it, that AOM needs a double-click, and
that the preview no longer looks like Paste. Rules for the owner of ClipboardPanel.swift [B]:
- One click on the preview title edits it in place (I-beam on hover, Return saves, Escape cancels, a click outside
  saves). Today ClipboardPanel.swift `ClipboardPreviewSheet` uses `.onTapGesture(count: 2) { beginTitleEdit() }`;
  it becomes a single tap.
- The shelf and preview follow Paste's layout as AOM had it before the token restyle (3d1e047, 137efed): the
  card's coloured header with app icon, title and time, the content preview, and the preview's own title bar.
  The 3.4 tokens apply to the Clipboard page in the main window, not to the shelf or its preview.
