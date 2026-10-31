# Click Hints (3.4.0)

Click buttons, links, fields, tabs and rows in the front window by typing the letters on them, without
reaching for the trackpad (Homerow, Vimac and Shortcat style).

## Show the hints

- Press the **Click with Keyboard** shortcut (Settings › Shortcuts › Productivity; ⇧⌘Space by default, see
  "Shortcut" below). Press it again to hide the hints.
- Or choose **Click with Keyboard** in the menu bar menu (Productivity section).
- Or press **Try It** in Text Actions › Click Hints: the hints appear over the AOM window after a moment.

Every clickable item in the front window gets a small pill with one or two letters on its top-left corner.
The labels use the home-row keys first (F J D K S L A G H), and the items closest to the pointer (or to the
window's top-left corner when the pointer is elsewhere) get the shortest labels. A window with more than 81
items borrows top-row letters so labels stay at two letters; only past 676 items does a label need three.

Click Hints needs **Accessibility** permission (System Settings › Privacy & Security › Accessibility). Without
it, the shortcut shows a HUD that says where to allow it, and the Click Hints page shows the same notice.

## Keys while hints are shown

| Do this | What happens |
|---|---|
| Type a hint's letters | Typing narrows the hints; the whole label clicks it. Labels never start one another, so there is nothing to confirm. |
| ⇧ + letters (or ⌃) | Right-click: the item's menu (AXShowMenu), or a right-click at its centre. |
| ⌘ + letters | ⌘-click at the centre: opens a link in a new tab in browsers. |
| ⌥ + letters | Moves the pointer there without clicking (to hover, or to start a drag). |
| Space or ↩ | Clicks the only hint left. |
| ⌫ | Removes the last letter. |
| / | Search by name: type part of an item's name; ↑ ↓ or Tab move the highlight, ↩ clicks it (with ⇧ ⌘ ⌥ as above), Space clicks when one match is left, / or ⌫ on an empty search go back to labels. |
| Esc, a click anywhere, scrolling, or switching apps | Hides the hints. |

The letters are read by key position, so they work the same with the Korean (or any other) input source on.
In search, Korean names also match the keys that type them on the 2-Set layout: `wjwkd` finds 저장, `ghkr`
finds 확인. Case, accents and spaces don't matter.

## What clicking does

- Buttons, links, checkboxes, tabs, pop-ups, disclosure triangles, menu bar and Dock items: the item's own
  action (AXPress, or AXConfirm or AXPick when that is what it offers), so the pointer doesn't move.
- Text fields, text areas, combo boxes and sliders get the keyboard focus, ready for typing or the arrow keys.
- Rows and anything else: a click at the centre of its visible part, posted as AOM's own input.
- An app that is slow to answer (a button that opens a dialog) is never clicked a second time.
- The hints are gone before anything is clicked.

## Options (Text Actions › Click Hints)

- **Label letters**: Home Row (default), Letters (all 26 from the start: more one-letter labels), or Numbers.
- **Hint size**: Small, Regular (22 pt, the default) or Large; each follows a macOS text style, so the system text
  size applies.
- **Include the menu bar**: the front app's menus get hints too (off by default).
- **Include the Dock**: Dock items get hints too (off by default).
- **Start in search**: hint mode starts in search; / switches to labels.
- **Enhanced accessibility** (per app, empty by default): Chrome, Edge, Brave, Arc and Electron apps (VS Code,
  Slack, Discord, Notion) build their accessibility tree only when an assistive app asks. For the apps on this
  list, AOM asks before reading: Electron apps through `AXManualAccessibility` (no side effects; it stays on, as
  Vimac does), other Chromium apps through `AXEnhancedUserInterface`, VoiceOver's flag, which can slow their
  window moves, so AOM sets it only while hints are shown and puts it back. Add an app only when its buttons get
  no hints; Add Running App… lists Chromium and Electron apps first.
- **Excluded apps**: hints never appear there. The list starts with the password managers (1Password 8 and 7,
  Bitwarden, Keychain Access, Passwords).

## Privacy and safety

- Nothing happens while secure keyboard entry is on (a password field or a password app), on the lock screen,
  while AOM is paused (Pause AOM, timed, until resumed or for the front app, or the master switch off), or in an
  excluded app. The HUD says which; the lock screen stays silent.
- Password fields (`AXSecureTextField`) never get a hint, and their contents are never read. Only an item's role,
  frame, enabled state and name are read; never the text in a field or a document.
- Clicks are posted through the session event tap with AOM's own tag, so AOM's gestures and triggers ignore them.

## How it works

- The front app's focused window is read through Accessibility off the main thread, one batch request per item
  (`AXUIElementCopyMultipleAttributeValues`), every request bounded by `AXUIElementSetMessagingTimeout`, within
  about half a second; a huge window stops early and shows what was found. Tables and outlines report only their
  visible rows, lists only their visible children, and anything outside the window or a scroll area's visible part
  is skipped with everything inside it.
- Nested items keep one hint: a button that fills its cell or row is the hint; a small checkbox or triangle in a
  row gets its own. Items smaller than 4 pt, disabled or off screen get none.
- The overlay is one transparent panel per display that has hints, sized to its hints, above the menu bar and the
  Dock, on every Space and over full-screen apps. It ignores the mouse and takes the keyboard without making AOM
  the active app, so the app you were using stays in front. Each pill is a small Core Animation layer (no
  full-screen drawing), on the display's pixel grid, kept whole on its display and nudged right when another pill
  is already there. Pills are opaque keycap capsules with a halo, readable over light, dark and colourful content;
  Increase Contrast swaps the halo for a full-strength border.
- Nothing runs while hints are off: no monitor, timer, panel, image or cache. Settings are read when the hints
  are shown. Keys are `AOMClickHints…`; Settings › Data › Reset Preferences resets them.

## Shortcut

Default: **⇧⌘Space**, the shortcut Homerow and Shortcat ship with. macOS doesn't use it by default
(Spotlight is ⌘Space, Finder search ⌥⌘Space, input sources ⌃Space and ⌃⌥Space, emoji ⌃⌘Space), and AOM's own
defaults don't (Pause Recording is ⌥⇧⌘Space, and only while recording). In VS Code it is Trigger Parameter Hints,
which a global shortcut takes over; choose another one in Settings › Shortcuts if you use that.

## Not included

- A scroll mode (Homerow's ⇧⌘J), double-click, and a "click several in a row" mode.
- Hangul typed through the input method in search (search reads key positions; Korean names match their 2-Set
  keys instead).
- Hints inside open menus and over other apps' windows than the front one.
