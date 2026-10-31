# ⌘K palette and window switcher (AOM 3.4.0)

The ⌘K palette is the one search field for AOM: commands, automations, clipboard items, captures, pages and
apps, and in 3.4 also a calculator, quicklinks, the menus of the app you were using, browser bookmarks, links to
the current item and recent files. The window switcher shows every window with a picture, like AltTab.

Nothing here runs in the background. The palette reads menus, bookmarks and recent files when it opens and
stops when it closes; the switcher reads windows when it opens. The only always-on part is the optional
hold-⌘ shortcut sheet, and its event monitor exists only while its switch is on.

## Opening the palette

Press **⌘K** in the All of MacOS window (View › Search…, or the Search field at the top of the sidebar). If an
automation or a global shortcut already uses ⌘K, the menu shows the free alternative (⇧⌘K, ⌥⌘K or ⇧⌘P).

| Keys | What they do |
|---|---|
| Type | Search everything. |
| ↑ ↓ | Move through the results. |
| ↩ | The row's main action (shown first in the bar at the bottom). |
| ⌘↩ | The row's second action. |
| ⌘K | Every action of the row (the Actions panel); ↑ ↓ and ↩ choose one. Right-click a row for the same list. |
| esc | Close the Actions panel, then clear the search, then close the palette. |

With an empty search the palette lists Commands, Automations, Clipboard, Recent captures, Recent files and Go to.
While you type, it is one list ranked by how well each title matches (a prefix first, then anywhere, then the
detail, then a fuzzy match such as "pms" for "Paste and Match Style"). Korean initial consonants work too:
"ㅋㅋㅇㅌ" finds "카카오톡". The calculator's answer and a matched quicklink are always on top; "Search Google",
"Search Naver" and "Search Files" are always at the bottom.

## Calculator

Type a sum or a conversion. The answer is the first row; **↩ copies the answer**, ⌘↩ copies the whole
equation ("10 km in mi = 6.21371 mi"). The same calculator gives Text Actions its Calculate button.

| Type | Answer |
|---|---|
| `12 × 11`, `2^10`, `(1 + 2)(3 + 4)`, `-2^2` | 132, 1024, 21, -4 (power before minus; 2^3^2 is 2^9) |
| `20% of 150`, `150 + 10%`, `150 - 10%`, `25% off 80` | 30, 165, 135, 60 |
| `10 % 3`, `10 mod 3` | 1 (a percent sign before a number is the remainder) |
| `sqrt 16`, `abs(-3.5)`, `round(2.5)`, `floor`, `ceil`, `sin(30°)`, `cos`, `tan`, `log(1000)`, `ln(e)`, `5!` | 4, 3.5, 3, …, 0.5, …, 3, 1, 120 (trigonometry in radians unless you add ° or deg) |
| `pi * 2`, `2pi`, `e^2` | 6.28318530718, 6.28318530718, 7.38905609893 |
| `3,5 + 1,25` | 4,75 (a decimal comma is answered with a comma) |
| `1,000 + 1` | 1001 in English, 2 where a comma is the decimal separator |
| `0xff`, `0b1010 + 1`, `255 in hex`, `10 in bin`, `0x1F in dec` | 255, 11, 0xFF, 0b1010, 31 |
| `10 km in mi`, `5 ft 11 in in cm`, `5'11" in cm` | 6.21371 mi, 180.34 cm, 180.34 cm |
| `70 kg in lb`, `10 돈 in g`, `1 근 in g` | 154.324 lb, 37.5 g, 600 g |
| `100 °F in °C`, `0 C to F`, `37.5 ℃` | 37.7778 °C, 32 °F, 99.5 °F |
| `30평`, `100 m² in 평`, `84 m^2 in pyeong`, `1 acre in m2` | 99.1736 m², 30.25 평, 25.41 평, 4046.86 m² |
| `1 gal in L`, `500 mL in fl oz`, `2 cups in ml` | 3.78541 L, 16.907 fl oz, 473.176 mL |
| `100 km/h in mph`, `10 m/s in km/h`, `100 km / 2 h` | 62.1371 mph, 36 km/h, 50 km/h |
| `1 KiB in KB`, `1 GB in GiB`, `8 Mb in MB`, `500 Mbps in MB/s` | 1.024 KB, 0.931323 GiB, 1 MB, 62.5 MB/s |
| `90 min in h`, `1 h 30 min in min`, `2시간 in 분` | 1.5 h, 90 min, 120 min |
| `100 px in pt`, `44 pt` | 50 pt, 88 px (one point is two pixels on a 2× Retina display) |

A quantity alone converts to its usual counterpart (km → mi, kg → lb, °C → °F, m² → 평, GB → GiB, Mbps → MB/s,
px → pt). "Mb" and "Mbit" are megabits; "MB" and lower-case "mb" are megabytes; KiB, MiB and GiB are powers of
1,024. A lone number or constant ("42", "pi") is not a calculation, so typing "e" to search shows no 2.718.

Answers have up to 12 significant digits (conversions 6), whole numbers up to 2^53 in full, larger ones as
"1.2e+18". Division by zero, overflow and anything that isn't a sum give no row. The calculator is a small
parser of its own: it never runs or looks up anything in the text, so text such as `system("ls")` simply isn't
a sum.

## Quicklinks

Type a keyword, a space and a search: **`g swift tips`** searches Google, **`n 서울 날씨`** Naver. The keyword
shows as a blue token in the field and the row says where it goes; ↩ opens it, ⌘↩ copies the URL. Typing the
keyword alone (or two letters of the name, "Git") suggests the quicklink; ↩ puts "gh " in the field for you.

| Keyword | Site |
|---|---|
| g | Google |
| n | Naver |
| gh | GitHub |
| yt | YouTube |
| r | Reddit |
| w | Wikipedia (English) |
| p | Papago (into Korean) |
| maps | Apple Maps |
| so | Stack Overflow |
| brew | Homebrew formula page (formulae.brew.sh/formula/name: the site has no search URL, so type the formula's name) |

**Edit them:** ⌘K › **Edit Quicklinks…**. Each row has a switch, the keyword, the name and the URL with
`{query}` where the search goes (`%s` works too). Add Quicklink, Restore Defaults, Done. A keyword can't have
spaces or repeat another; local files and script URLs (file:, javascript:, data:) are refused. The search is
percent-encoded (Korean as UTF-8), so "a&b" can't add a parameter and "../" can't climb a path. The list is
stored under `AOMPaletteQuicklinks`; Settings › Data › Reset Preferences brings back the defaults.

## Menu search

The palette searches the menus of the app that was in front before you opened it (shown as "Safari menus").
Type part of a menu item: "export pdf", "show sidebar", "새 탭". The row shows the menu path
("File › Export") and the item's shortcut; ↩ switches to that app and chooses the item, as if you had clicked
it. Unavailable items are dimmed and sorted last.

AOM reads the menu bar through Accessibility (the Apple menu is left out), off the main thread with a time limit,
and keeps the result for 60 seconds for up to four apps. Without Accessibility the palette shows **Allow
Accessibility to Search Menus**, which opens the right Settings pane. If the app changed its menus since they
were read, AOM reads them again before choosing.

## Bookmarks

Type two or more letters to search your bookmarks (like Fastmarks): every Chrome profile (and Chrome Beta,
Canary, Naver Whale, Brave, Edge, Vivaldi, Arc and Chromium when installed) and Safari's Favorites, bookmarks
and Reading List. The row shows the site and folder, and the profile when Chrome has more than one. ↩ opens the
bookmark in the browser it came from, a Chrome bookmark in its own profile; ⌘↩ copies the URL; the Actions panel
also has Copy as Markdown. Only web pages are listed (no bookmarklets or browser pages).

Safari keeps bookmarks in a folder only **Full Disk Access** can read. Until All of MacOS has it, searching shows
one row, **Allow Full Disk Access to Search Safari Bookmarks**, which opens Privacy & Security › Full Disk Access.
Bookmark files are read when the palette opens and only again when they change.

## Copy Link to Current Item

⌘K › **Copy Link to Current Item** copies a link to what you were looking at:

| Front app | The link |
|---|---|
| Safari, Chrome and other Chromium browsers | The current tab's title and URL |
| Finder | The selected files and folders (or the front window's folder), as file links |
| Mail | The selected messages, as message:// links that open them in Mail |
| Any app with a document window | The window's document (Pages, TextEdit, Preview, Xcode …) |
| Anything else | The app itself |

One copy holds Markdown `[title](url)` as text, a clickable title as rich text (HTML and RTF) and the URL, so
Notes, Mail and Pages paste a link and a plain-text editor pastes Markdown. The Actions panel has **Copy as
Markdown** (text only) and **Copy URL**. A HUD confirms what was copied. The first time for each browser, Finder or
Mail, macOS asks whether All of MacOS may control it (Privacy & Security › Automation); if you decline, AOM falls
back to the document or the app and says why.

## Recent files

With an empty search the palette lists **Latest Download** (the newest file in Downloads), **Latest Screenshot**
(the newest picture macOS marks as a screen capture) and the files you used in the last 7 days. While you type,
recent files whose names match are listed. ↩ opens; the Actions panel has Show in Finder and Copy Path. These come
from Spotlight, asked once when the palette opens; Library folders, hidden files, folders and apps are left out.

## Window switcher

Open it with its shortcut (Settings › Shortcuts › Window Switcher; ⌥Tab is suggested), the Window Switcher
command in ⌘K, the Workspace quick action, the status menu or a gesture.

| Keys | What they do |
|---|---|
| Tab, ⇧Tab (with the trigger held), ← → | Next and previous window |
| ↑ ↓ | Move a row in the grid |
| Release the trigger | Switch to the selected window (when the switcher opened with a held key) |
| ↩, click | Switch |
| Type | Search app names and window titles (fuzzy, Korean initials too); then ↩ switches |
| ⌘W | Close the selected window (its close button, so unsaved documents still ask) |
| ⌘M | Minimize, or bring back a minimized window |
| ⌘H | Hide the app |
| ⌘Q | Quit the app (as ⌘Q in the app: it asks about unsaved work) |
| ⌘G | Group windows by app (remembered) |
| esc | Clear the search, then cancel |

It lists the windows on screen front to back, then hidden apps' windows, windows in other Spaces and minimized
windows, each marked. Choosing a minimized window brings it back; a hidden app is shown again; a window in
another Space is chosen through its app's Window menu, which makes macOS switch to that Space. The first card
selected is the window behind the front one, as ⌘Tab starts with the previous app.

While the trigger key is still held, typed letters search as plain letters (⌥A types "a", not "å"). Once a search
is typed, letting go of the trigger doesn't switch; press ↩. For Korean, let go of the trigger and type in the
field.

Pictures and the titles of other apps' windows need **Screen Recording**; without it the switcher shows app icons
and Accessibility titles and says so in its footer. Pictures are small (twice the card size) and kept for the next
opening, then refreshed one window at a time.

Limits: macOS lets apps see windows in other Spaces only through public lists that also contain closed-but-kept
windows, so AOM lists a window from another Space only when its app's Window menu has it. Apps without a Window
menu list (some games and cross-platform apps) show only their windows in the current Space and the Dock.

## Hold ⌘ for an app's shortcuts

Like KeyClu: hold ⌘ alone for 1.2 seconds in any app and its menu shortcuts appear in the middle of the screen,
one column per menu (File, Edit, View …). Let go of ⌘ and it disappears. Pressing a key (⌘C), clicking or adding
another modifier cancels it, so normal shortcuts never show it.

**Turn it on:** ⌘K › **Turn On Hold ⌘ for Shortcuts** (or the switch in Settings › Shortcuts once it is placed
there; the hold time is adjustable from 0.8 to 2 seconds). ⌘K › **Show Keyboard Shortcuts for <app>** shows the
same sheet without holding; any key or click closes it. It never appears in games, in password fields (secure
input), while AOM is paused or while a mouse button is held. Menus are read off the main thread and kept 10
minutes per app version. AOM's own gesture Cheat Sheet is separate.

## Link rules (Velja and Choosy)

⌘K › **Link Rules…** opens the settings (they belong in Settings › Links). When All of MacOS is your default
browser, a link you click anywhere first loses its tracking parameters (utm_*, fbclid, gclid, si, igshid and
your own list), Figma, Zoom and Notion links open in their apps when installed, then the first matching rule picks
the browser ("Host contains uos.ac.kr → Safari"), and anything else goes to the browser you choose for other
links. Hold ⌥ while clicking a link to pick a browser from a menu at the pointer. Only the rule that matched is
logged.

**Make All of MacOS the default browser** with the button in Link Rules; macOS asks you to confirm. Routing stays
off until you turn on "Route links by these rules". This needs the http and https URL types in AOM's Info.plist
and the hand-off in AppDelegate; until the integrator adds them (see the 3.4.0 report), the button can't
succeed and links keep opening in your browser directly.
