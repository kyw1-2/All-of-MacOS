# Folder Rules (AOM 3.4.0)

Folder Rules tidies folders for you, the way Hazel does. You pick folders, give each one rules, and every new or
changed item goes to the first rule that matches it. That rule's actions then run in order. Folder Rules can also
make images smaller (like Clop) and install apps from disk images (like Rapidmg).

Everything starts off. Nothing in your folders changes until you turn on a rule, and turning one on first shows
what it would do.

## Turning it on

1. Open **Folder Rules** in the sidebar (Productivity, ⌘9).
2. Downloads and Desktop are already listed. Add another folder with **Add Folder…**, or drop a folder from
   Finder onto the list.
3. Click **+ New Rule**, or open its menu and pick a template. Templates are added switched off.
4. Edit the rule, then flip its switch. Folder Rules shows the items the rule would act on right now.
   **Turn On and Run** starts it.
5. The switch in the page header (also on the Workspace tile) turns all of Folder Rules on or off.

The first time a rule reads Downloads, Desktop or Documents, macOS asks whether All of MacOS may access that
folder. If you said no, the page shows a notice with **Open Privacy Settings**.

## Rules

A rule reads like a sentence: "If **all** of the following are true … do the following …".

**Conditions** (match all, any or none):

| Attribute | Operators | Notes |
|---|---|---|
| Name | contains, does not contain, is, is not, starts with, ends with, matches pattern | Without the extension. Upper and lower case don't matter, and Korean names match however the file was saved. Several words mean "any of them". |
| Extension | is, is not | Write `dmg` or `.dmg`; several mean "any of them". |
| Kind | is, is not | Image, Screenshot, Movie, Audio, PDF, Archive, Disk Image, Installer Package, Document, Folder, Application |
| Date Added, Created, Modified, Last Opened | is more than N ago, is within the last N | Minutes, hours or days. A file that was never opened counts as opened when it arrived. |
| Size | is greater than, is less than | KB, MB, GB, as Finder counts them (1 MB = 1,000,000 bytes) |
| Downloaded From | contains, does not contain | The site the file came from, such as `github.com`. A pasted link counts as its site. |
| Tags | include, do not include | Finder tags |

**Actions** run in order on the matching item:

| Action | What it does |
|---|---|
| Move to Folder | Moves it into a folder, optionally sorted into subfolders: `{year}` `{month}` `{day}` `{kind}` `{ext}`, with `/` for deeper levels (for example `Screenshots/{year}-{month}`). The chosen folder must exist; the subfolders are created. |
| Copy to Folder | The same, as a copy. Later actions work on the copy. |
| Rename | A new name from `{name}` `{ext}` `{date:yyyy-MM-dd}` `{counter}` (or `{counter:3}` for 001). Without `{ext}` the file keeps its extension. |
| Add Tags, Set Color Label | Finder tags and the colour label. |
| Move to Trash | Never deletes. Undo puts it back. Must be the last action. |
| Compress to ZIP | `ditto -c -k --sequesterRsrc --keepParent`, like Finder's Compress. Optionally moves the original to the Trash. Later actions work on the ZIP. |
| Extract ZIP | Extracts beside the archive (one item, or a folder named after the archive). Optionally moves the archive to the Trash. Later actions work on what came out. |
| Optimize Image | Resizes images whose longest side is above a limit, re-encodes JPEG and HEIC at a quality you choose, removes the location, and can turn PNG screenshots into JPEG or HEIC (transparent parts become white in JPEG). The original goes to the Trash, or is overwritten if you choose that; a format change always keeps it in the Trash. Only JPEG, HEIC and PNG are optimized. An image AOM already optimized is left alone. |
| Install App | See below. |
| Open | Opens the item, with an app you choose or the default one. |
| Show Notification | One notification per rule and check, never one per file. While AOM is in front, a short HUD instead. |
| Run Automation | Runs one of your AOM automations. It can read the file's path as `{{var:FolderRuleFile}}` and its name as `{{var:FolderRuleFileName}}`. |
| Run Shortcut | Runs a Shortcut with the file as its input (`shortcuts run <name> --input-path <file>`). |

Name conflicts become "name 2", "name 3", as in Finder.

**Options:** *Look inside subfolders* (top level only by default; never inside apps or other packages) and
*Run without asking*.

## Preview, test and history

**Preview** in the rule's header lists the items the rule would act on right now and what it would do to each,
without changing anything. It opens the inspector on the right (**Show Inspector** in the toolbar, ⌥⌘I), which
also has **Test a File** (drop a file or choose one to see whether the rule matches it and why) and the rule's
**History** with Undo. When the window is too narrow for the inspector, the preview opens inside the rule
instead.

## What asks first

Moving to the Trash, optimizing, compressing or extracting with the original going to the Trash, and installing
apps ask before they run, unless the rule is set to **Run without asking**. A small card appears in the top-right
corner without taking focus: the approve button runs the rule on those items, **Skip** leaves them alone for
good, **Review…** opens the page. The same questions wait at the top of the Folder Rules page and in the status
menu ("Review Waiting Actions…"). Items you saw in the preview when you turned a rule on don't ask again.

Replacing an app that is already in Applications always asks (Replace, Keep Both, Cancel); the old copy goes to
the Trash.

## Installing apps from disk images

- **Install Disk Image…** (in the status menu, in the toolbar's New Rule menu, and in System Tools) asks for a
  .dmg and installs its app.
- The **Install Apps from Disk Images** template offers to install each new disk image that lands in Downloads.

The image is mounted read-only and hidden (`hdiutil attach -readonly -nobrowse -noautoopen`), its one app is
copied to Applications with `ditto` (signatures and the download's quarantine are kept, so Gatekeeper still checks
the app), the image is ejected (the normal way first, `-force` only if that fails), and then it goes to the
Trash if you kept that box checked. A disk image with a license agreement or a password, or without exactly one
app, is left for you to open in Finder; the activity says why. An app that is open is never replaced: quit it
first.

## Safety

- Rules only act on items inside the folders you picked, never follow links and never work inside apps or other
  packages.
- Hidden items and unfinished downloads (`.crdownload`, `.download`, `.part`, `.partial`) are skipped, and a file
  that is still growing waits until its size stops changing.
- Like Hazel, a rule that handled an item leaves it alone afterwards, unless the rule's conditions change or the
  item stops matching and later matches again. **Check Them Again** in a rule's options lets it look at
  everything once more.
- A failed action stops that rule for that item; the next check retries, three times at most.
- A rule acts on at most 120 items a minute; the rest wait. A rule that keeps acting on files Folder Rules itself
  just made (20 times in 10 minutes) is turned off as a loop, and the page and Workspace say so.
- Pause AOM (the menu bar switch or a timed pause) pauses Folder Rules too; it catches up when AOM resumes.
- Folders are checked when they change (FSEvents), every five minutes for time-based conditions, and after the Mac
  wakes. With Folder Rules off, nothing is watched and no timer runs.

## Activity and Undo

**Activity** (top of the list) shows every run by day with a count per day: the rule, the file, each step and
whether it worked. Moves, renames, the Trash and optimized images have **Undo**, which moves the item back
(putting a Trashed item back is a move too). If the old name is taken, the item comes back as "name 2". **Clear**
empties the list without touching any file; Undo in the message that appears (or Edit › Undo) brings it back.

## Templates

| Template | Folder | What it does |
|---|---|---|
| Clear Out Old Installers | Downloads | `.dmg`, `.pkg` and `.mpkg` added more than 3 days ago → Trash |
| File Screenshots by Month | Desktop | Screenshots → Pictures › Screenshots › year-month |
| File Receipts and Invoices | Downloads | PDFs named invoice, receipt, 영수증 or 청구서 → Documents › Receipts, tagged Receipt |
| Archive Old Downloads | Downloads | Items added more than 30 days ago (except the Archive folder) → Downloads › Archive › year-month |
| Optimize New Screenshots | Where macOS saves screenshots | Screenshots from the last day → smaller JPEGs; the PNG goes to the Trash |
| Install Apps from Disk Images | Downloads | Disk images from the last day → offer to install the app |

Rules run top to bottom, so if a folder has both screenshot templates, put **Optimize New Screenshots** first
(⋯ › Move Rule Up): the optimized copy is then filed by the other rule.

## Status menu

The menu bar menu's Productivity section has:

- **Set Up Folder Rules…** while there are no rules, which opens the page.
- **Run Folder Rules Now** and **Pause Folder Rules** (or **Resume Folder Rules**) once there are rules.
- **Review Waiting Actions (n)…** when actions wait for your answer.
- **Install Disk Image…**

## Where things are stored

`~/Library/Application Support/AllOfMacOS/FolderRules/`: `rules.json` (folders, rules, the switch),
`activity.json` (the last 1,000 lines from 30 days) and `state.json` (what each rule already handled). An
unreadable `rules.json` is kept beside the new one, never deleted. Settings › Data › Reset Preferences doesn't
remove rules: they are your data, like presets.
