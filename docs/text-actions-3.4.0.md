# Text Actions 3.4.0: a bar of actions over the text you select

Select text in any app and a small pill-shaped bar appears above it, like the iOS edit menu or
PopClip: copy, search, translate, look up, calculate and more. The bar never takes the keyboard
or the focus, and it stays out of password fields and the apps you exclude.

Code: `AllOfMacOS/Services/TextActions/` (engine), `AllOfMacOS/Views/TextActions/` (bar and page).
Tests: `TextActionsClassifierTests`, `TextActionsURLTests`, `TextActionsApplicabilityTests`,
`TextActionsTransformTests`, `TextActionsDismissalTests`, `TextActionsPlacementTests`,
`TextActionsGateTests`, `TextActionsSettingsTests`.

## Turning it on

Text Actions is off until you turn it on, in any of these places:

- **Text Actions page** (sidebar › Productivity): the switch in the header of Selection Bar.
- **Workspace**: the switch on the Text Actions tile.
- **Status menu** (menu bar icon) › Productivity › Text Actions.

All of MacOS needs **Accessibility** (System Settings › Privacy & Security › Accessibility) to read
the selection. Without it the page shows a notice with an Allow… button and the Workspace tile asks
for it.

The **Show Text Actions** shortcut (Settings › Shortcuts › Productivity, no default keys) shows the
bar for the current selection even while the switch is off.

## When the bar appears

| You… | Setting (Selection Bar › Show the bar when) | Default |
|---|---|---|
| drag across text | Dragging across text | on |
| double-click a word, triple-click a line | Double- or triple-clicking text | on |
| ⇧-click to extend a selection | (with dragging) | on |
| select with ⇧ and the arrow keys, then pause | Selecting with ⇧ and the arrow keys | off |

It waits **Show after** (0–1.5 s, default 0.2 s) and appears **above** the selection, centred on the
pointer (or **below**; it flips when there is no room and never covers the menu bar or leaves the
pointer's display).

It does not appear for a plain click, a ⌘-click or ⌃-click, a file or text drag and drop, a window,
scroll-bar or slider drag (the selection did not change), or when no actions apply.

## When it goes away

Esc or any other key, a click anywhere else, scrolling, switching apps, running an action, or
**Hide after** (1.5–30 s, default 4 s) once the pointer is away from the bar. The pointer over the bar
keeps it. ⌥ alone does not hide it (it is the alternate click). With Reduce Motion the bar appears
and leaves without fading.

## The actions

Each action has a switch and a place in the order (drag the rows, or Move Up and Move Down under the
list, or the row's context menu; Edit › Undo undoes it). Contextual actions appear only when they
apply.

| Action | Default | Appears | What it does |
|---|---|---|---|
| Copy | on | always | Presses ⌘C in the app (keeps formatting); plain text if the app does not respond |
| Cut | on | text you can edit | ⌘X in the app |
| Paste | on | text you can edit, clipboard not empty | ⌘V in the app |
| Search | on | up to 1,000 characters | Google, Naver, Bing, DuckDuckGo, Perplexity or a custom address with `{query}` |
| Search GitHub | off | same | github.com/search |
| Open Link | on | a web address: `https://…`, `naver.com`, `localhost:3000` | Opens it (http and https only) |
| New Email | on | an email address | A new message in the mail app |
| Look Up | on | a word or short phrase | Dictionary (`dict://`) |
| Translate | on | text with letters | Papago or Google Translate, From (Detect Language) and To |
| Calculate | on | a sum or a conversion the calculator answers | Shows `= 132`; click copies, ⌥-click replaces the selection |
| Count | off | always | A chip: characters and words |
| Speak | off | text | Reads it in its language; Stop while speaking |
| Pin to Clipboard | on | always | A Clipboard item on the Text Actions pinboard (or the one you choose) |
| Ask ChatGPT | off | the ChatGPT app is installed | Copies the text and opens ChatGPT |
| Change Case | off | text with upper and lower case | UPPER, lower, Title, camelCase, snake_case, kebab-case |
| Format JSON | off | valid JSON | Indents it, keeping key order and number formats |
| URL Encode or Decode | off | always (Decode when the text has %-escapes) | Percent-encoding |
| Base64 Encode or Decode | off | always (Decode when the text is Base64 text) | Base64 |
| Markdown | off | always | Bold, Italic, Code, Link (the link address comes from the clipboard) |

Transforms replace the selection in text you can edit (through Accessibility, or by pasting with the
clipboard put back), and copy the result in text you can't edit; ⌥-click copies instead of replacing.

Defaults for people who read Korean: Translate uses Papago with Korean as the target. With Detect
Language, text already in the target language goes to English instead (Korean text → English).
A long selection is cut to fit the translator's link (about 2,000 characters, fewer for Korean);
a HUD says how much was sent.

## Privacy

- Never in **password fields** (Accessibility's secure text field) or while **secure keyboard entry**
  is on; nothing is read there, not even the selection's length.
- Never in **excluded apps**: 1Password, Bitwarden, Keychain Access and Passwords to start with
  (Excluded Apps in the list: remove any, add with Add App… or Add Running App).
- Never while **AOM is paused** (the menu bar Automation switch, a timed pause, or a pause for the
  front app), and never in All of MacOS itself.
- **Use Copy to read the selection** (off by default): for apps that don't share their selection
  with Accessibility (some web views and Electron apps), AOM presses ⌘C, reads the text and puts your
  clipboard back. AOM's clipboard history is held meanwhile, so neither the copy nor the restore is
  recorded. Other clipboard managers may still see the copy. Finder file selections are ignored.
  The shortcut may use this even when the option is off, because you asked for the bar.
- **Pin to Clipboard** respects Clipboard's own excluded apps.
- Nothing goes to the network unless you click an action that opens a web page.

## Performance

While the switch is off nothing is installed. While it is on, one global monitor watches left mouse
down and up (no drag events), plus key presses only with the keyboard trigger on. Accessibility reads
run off the main thread with a 0.25 s timeout per request (0.1 s at mouse down). The bar's own
monitors exist only while it is visible; its timeout is one timer, not a polling loop.

## Needs a hands-on check

These depend on other apps and were not exercised on a real selection in this build:

- Reading and placing the bar in Safari, Chrome, Notes, TextEdit, Pages, Terminal, Xcode, Slack and
  KakaoTalk; Electron apps (VS Code) with Use Copy to read the selection.
- Replacing text through Accessibility in web editors that report success but change nothing (AOM
  reads the selection back and pastes instead).
- Calculate shows results only once the shared calculator (`AOMCalculator.evaluate`, from the ⌘K
  palette work) is merged; until then it never appears.
