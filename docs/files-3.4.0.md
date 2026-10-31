# Files (AOM 3.4.0)

Files is a page in the sidebar's Productivity section. It has three tools:

- **Open and Save dialog helper** (like Default Folder X): a small panel beside every Open and Save dialog with
  the folders you are likely to want. One click goes there in the dialog.
- **Drop Shelf** (like Dropover and Yoink): a floating shelf that holds files while you switch apps or desktops.
- **Recent downloads and screenshots**: the newest items in Downloads and the screenshot folder, live, plus
  Recent Downloads in the menu bar menu.

Everything is off until you turn it on, except the shelf itself, which you can open at any time.

## Open and Save dialogs

**Turn it on:** Files › Open and Save dialogs › Show folders beside Open and Save dialogs. The switch on the
Workspace Files tile turns the helper and the shake shelf on or off together.

macOS has to allow All of MacOS in **Privacy & Security › Accessibility** (the page says so when it isn't).

When an Open or Save dialog is in front, a panel appears beside it (right of the dialog, or left when there is
no room). It moves with the dialog and hides when the dialog closes or another app comes forward. It lists:

| Section | What it shows |
|---|---|
| Finder windows | The folders open in Finder windows, front to back. The first time, click **Allow Finder Access…** in the panel or on the page; macOS asks once whether All of MacOS may control Finder (Privacy & Security › Automation). |
| Favorites | Your folders, in your order. The defaults are Desktop, Documents, Downloads and iCloud Drive (when iCloud Drive is set up). Edit them on the Files page: Add Folder…, drop Finder folders on the list, Move Up/Move Down in a row's menu, the − button, Restore Defaults. |
| Recent | Folders you went to with the panel, and the folders of the newest files in Downloads and on the Desktop ("Has report.pdf"). A folder already listed above isn't repeated. |
| Clipboard | When the clipboard holds a file, or one line of text that is a path to something that exists ("/Users/…", "~/…", "file:///…", quoted or with `\ ` escapes), its folder. The clipboard is read only while the panel is up, only when macOS already allows All of MacOS to read it, and nothing is kept. |

**Go there:** click a folder. The helper presses ⌘⇧G in the dialog, puts the path into Go to Folder (or types it
when the field doesn't accept it), presses Return, and checks that Go to Folder closed. The panel then says
"Went to Downloads", or why it couldn't ("Couldn't go to “Archive” because the dialog didn't accept the folder").
A file's path goes to the folder it is in.

**Shortcuts:** with "⌘⌥1 to ⌘⌥9 go to favorites" on, ⌘⌥1 goes to the first favorite, ⌘⌥2 to the second and so
on, while a dialog is in front. The keys are registered only while a dialog is attached.

**Not in some apps:** Files › Excluded apps › Add App…, or the panel's ⋯ menu › Never Show in "App". The ⋯ menu
also has Hide for This Dialog. Pause AOM and per-app pauses hide the panel too, and nothing is read while
secure input is on (a password field is active).

## Drop Shelf

**Open it:**

- Shake the pointer left and right while you drag files (Files › Drop Shelf › Shake while dragging opens the
  shelf; Shake sensitivity Low, Medium or High). Medium needs three quick direction changes within half a second.
- Or press ⇧ while dragging files (Shift while dragging opens it too).
- Or the status menu's **Show Drop Shelf**, Workspace's Drop Shelf quick action, the Files page's
  **Show Drop Shelf** button, or a keyboard shortcut you set in Settings › Shortcuts › Productivity › Show Drop Shelf.

The shelf appears beside the pointer without taking focus. Drop files on it, then drag them out: drag one row,
select several (click, ⌘-click, ⇧-click) and drag one of them, or drag the stack at the top to take them all.
Dragging out always copies, and items stay on the shelf.

**Actions** (on the selected items, or all items when nothing is selected): AirDrop, Share…, Compress to ZIP,
Quick Look (also Space), and in ⋯: Copy Paths, Move To…, Copy To…, Show in Finder, Remove from Shelf, Clear
Shelf. Keys while the shelf is focused: Space, Delete, ⌘A, ⌘C (copies the files), ⌘Z, ⌘W, Escape.

- Files never move unless you choose **Move To…**; Move To shows "Moved 3 items to Invoices" with Undo.
- Copy To and Compress never overwrite: a taken name becomes "Report 2.pdf". The ZIP goes next to the first item
  ("Report.pdf.zip" for one item, "Archive.zip" for several, made with `ditto` like the Finder's Compress).
- Remove and Clear take items off the shelf only, with Undo. Files the shelf received from apps that promise
  files (an image dragged out of Safari) live in All of MacOS's Files folder; removing those moves them to the
  Trash, and Undo brings them back.
- The shelf keeps its items when All of MacOS quits (Application Support/AllOfMacOS/Files/shelf.json stores their
  paths). A file that was moved or deleted shows "Not found".

## Recent downloads and screenshots

The Files page lists the newest downloads (by the date they arrived) and the newest screenshots, and updates
while it is open. Screenshots come from the folder the Screenshot app saves to (Options › Save to), else the
Desktop, and are recognised by the screenshot mark macOS puts on them (by their "Screenshot …" name when
Spotlight has no information). Downloads still in progress are left out.

Click to select, Space for Quick Look, double-click or Return to open, ↑ ↓ to move, drag to another app. Each
row's menu has Open, Quick Look, Show in Finder, Copy, Copy Path and Move to Trash (with Undo).

The status menu's **Recent Downloads ›** lists the ten newest downloads (click to open), Show Downloads in
Finder and Open Files…. Downloads is read only when that submenu opens, not when the status menu opens.

## Workspace

The Files tile is on when the dialog helper or the shake shelf is on. Its number is the items on the shelf, or,
with an empty shelf, the downloads that arrived in the last 24 hours. It shows "Needs Accessibility" when the
helper is on without that permission.

## Settings and data

Settings are stored under keys that start with `AOMFiles` (Settings › Data › Reset Preferences resets them).
Data lives in Application Support/AllOfMacOS/Files: `shelf.json`, `recent-folders.json` and `Received/`.

## How the dialog helper works (for maintainers)

- An AXObserver on the frontmost app watches focused-window, window and sheet creation, move and resize
  notifications, plus destruction of the attached dialog; a once-a-second check runs only while a dialog is
  attached. All Accessibility work runs on one serial queue with a 0.25 s timeout per element.
- A window is a dialog by its identifier ("open-panel", "save-panel"), else by its controls ("OKButton",
  "CancelButton", "where popup", "saveAsNameTextField"), else by the open-and-save panel service
  (com.apple.appkit.xpc.openAndSavePanelService) owning it or its content, with a Cancel button.
- Measured on macOS 27.2 with probe apps (kit folder f-340-evidence): the Open panel is AXWindow/AXStandardWindow
  "open-panel"; Save is "save-panel", an AXSheet when attached to a document; a sandboxed app's panel has the same
  identifiers, and both kinds show content from the panel service. ⌘⇧G works only through the session event
  tap (posted to the app's process it does nothing). Go to Folder is the sheet "GoToWindow" with the field
  "PathTextField"; setting its value through Accessibility and pressing Return goes there in about one second,
  `~` and spaces work, a file's path selects the file, and a folder that doesn't exist keeps the sheet open (the
  helper then presses Escape and reports it).
- The dialog panel and the shelf are non-activating panels; clicks don't make All of MacOS the active app, so
  the keys reach the dialog.
