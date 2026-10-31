# Pages and panels, 3.4.0

What changed on the existing pages and panels, and how to use it. The full before → after list (93 items with
design references) is aom-335-kit/ui340-items-B.md; the design rules are docs/design-3.4.0.md.

## Capture

- Ten tools: All-In-One, Area, Window, Full Screen, Scrolling, Self-Timer, Record Screen, Text, QR Code and the new
  **Measure Screen** (⇧⌘7, also in the menu-bar Capture menu). In a narrow window the tools wrap to two rows.
- **Search captures** in the toolbar; filters All, Screenshots, Recordings and **Kept** (captures kept in history;
  this used to read "Pinned", which is a different thing: Pin to the Screen).
- The gallery works from the keyboard: arrows move, Return edits, Space previews, ⌘C copies, Delete removes from
  history. One click selects, a double-click edits (a recording opens the recording editor).
- Copying and failures now say so in a toast. While **Add Copied Text to Clipboard** is on (More Capture Modes in
  the Capture menu), the page shows "Copy Text Adds".
- Screen Ruler's settings appear below the tools once that module is in (section from the Screen Ruler branch).

## Clipboard

- The shelf looks like Paste again: the source app's colour across the card header, the title over the time, the
  app's icon at the edge. In the preview, **click the title once to rename it** (Return saves, Esc cancels, a click
  elsewhere saves); ⌘R does the same. **Rename** in a card's menu and ⌘R on a selected card edit the card's title in
  place too.
- The Clipboard page is a list with a detail pane: the clip, Copy (⇧⌘C), and its kind, source app, time, size and
  pinboards. **+ − ⋯** at the bottom: New Text Item, Delete (with Undo in the toast), New Pinboard…, Open Shelf, Erase
  History…. Rows drag out to other apps.
- Messages in the shelf stay long enough to read (3.5–8 s) and are read out by VoiceOver.

## Automation

- **+ − ⋯** under the list: New, Delete, Duplicate, Pin, Import/Export Preset…, Activation Groups…. Delete no longer
  asks; the toast's **Undo** puts the automation back where it was.
- New Automation: the input type is a segmented control, gestures are a list (Return or a double-click adds), and a
  disabled Add says why. Recording a shortcut offers **Stop Recording** and **Record Again**.

## Other pages and panels

- Audio: a section for the microphone mute HUD (from the Tools & Audio branch), menus on the Output, Input and Sound
  effects rows (Sound Settings…), and **Reset Effects** can be undone.
- Window Tiling: a failed tile says why instead of claiming success; moving keyboard focus over a layout previews it.
- Insights: click or drag over the chart to read a day's count; Most used rows have Show in Automation and Copy
  Input Name.
- Annotation editor: visible Undo and Redo, Zoom In ⌘= and Zoom Out ⌘-, a status line that clears itself and offers
  Show in Finder after a save, a canvas menu, and an eraser that stays visible on any picture.
- Recording editor: the preview stays in view while the form scrolls, Esc closes, and it won't close in the middle of
  an export. Playback uses the system player view (the SwiftUI player crashed on macOS 27.2).
- Pinned screenshots, Quick Access (Copy and Save first in its menu), the Capture Text HUD (stays up long enough to
  read), the history overlay, the floating menus editor (a list of menus with + − ⋯, Save ⌘S, a warning before
  unsaved changes are left) and the BetterTouchTool import report got the same treatment.
- Settings › General has a new **Input sources** group (docs/input-sources-3.4.0.md).
- Counts read "1 line", "1 file", "1 capture", "1 step" instead of "1 lines" or "1 file(s)".
