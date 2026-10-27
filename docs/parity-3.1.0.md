# 3.1.0 parity with Paste, CleanShot X and BetterTouchTool

Scope: features that run locally. Cloud sync and sharing, Magic Mouse and
Stream Deck are excluded by request. The gap list came from a code audit of
3.0.14 against the earlier parity documents.

## Closed in 3.1.0

### BetterTouchTool

| Gap | 3.1.0 |
|---|---|
| Key remapping and Hyper key | Settings › Automation › Keyboard & Mouse. Remaps are applied with `hidutil` (Apple TN2450), so they work at the HID level; AOM adds and removes only the pairs it owns and removes them when it quits. Hyper maps the chosen key to F18 and adds ⌃⌥⇧⌘ while held; tapping it alone can send Escape. |
| Reverse the mouse wheel only | Event tap on non-continuous scroll events; trackpads keep natural scrolling and AOM's own synthetic scrolls are untouched. |
| Selected-text actions | Save to variable, transform and paste back, web search, speak. Accessibility first; ⌘C with the clipboard restored otherwise. |
| Clipboard automation | Paste history item N or from a pinboard, transform clipboard text, save / restore / clear the clipboard. |
| On-screen text | Find Text on Screen (OCR): stores the text, or true/false with _x/_y, and can click the match. Branch with If / Else. |
| Menus and context menus | Choose Menu Bar Item by path (File > Export > PDF…, wildcards), Show Context Menu (AXShowMenu, secondary click fallback). |
| App switching | Activate Previous App (activation history), Quit / Hide App Under Cursor. |
| Bulk window actions | Activate Window by Title, Minimize All Windows of Front App, Gather Windows to Pointer Display, Tile Two Front Windows Side by Side (one undo step). |
| System actions | Switch Keyboard Input Source, Set Sound Input, Toggle Display Mirroring, Eject All Disks, Toggle Dock Auto-Hide, Bluetooth connect/disconnect, Wi-Fi on/off, Emoji & Symbols. |
| Utility actions | Send MIDI (virtual source "All of MacOS"), Send OSC (UDP), Pick Color from Screen (hex), Haptic Feedback, Post Distributed Notification. |
| Do Not Disturb | Toggle Do Not Disturb runs a named Shortcut (no shell); the description no longer says "not implemented". |
| More waits | Wait For an app to quit, a file to disappear, the focused window to change, or its title to contain text. |
| Launcher search | The command palette also finds installed apps and hands a query to Spotlight in Finder. |

### CleanShot X

| Gap | 3.1.0 |
|---|---|
| Restart recording | Button in the recording bar, a menu item and an action; same area and options. |
| Do Not Disturb while recording | Runs your "Set Focus" Shortcuts at start and end (macOS has no public Focus API). |
| Live webcam bubble | Round, draggable, mirrored preview while recording. It is kept out of the video; the editable camera layer starts where the bubble was left. |
| Word-level Smart Highlighter | Highlights each matched word using Vision's per-range boxes. |
| What's New after an update | Shown once per new version in a non-activating panel; first installs stay quiet. |

### Paste

| Gap | 3.1.0 |
|---|---|
| Drag between pinboards | Moves the item; ⌥ copies; dragging from History adds. |
| Merging HTML- or RTFD-only items | Multi-paste keeps HTML (joined as fragments) and RTFD attachments alongside RTF and plain text. |

## Still open

| Gap | Why it is not in 3.1.0 |
|---|---|
| Continuous, pressure-based and 2-finger edge trackpad gestures (BTT) | Needs a new per-frame gesture family in the multitouch pipeline; large and risky to ship untested. |
| Move window to Desktop N | No public API; repeated Space moves are unreliable across display layouts. |
| Video backgrounds, text background styles, annotation eraser (CleanShot) | Studio and annotation renderer changes, planned separately. |
| Link cards and OCR match boxes in clipboard previews (Paste) | Need opt-in network fetches and stored Vision boxes. |
| Floating menu submenus, searchable lists, focus-follows-mouse, Stage Manager toggle | Lower value; not started. |

## Verification

- Unit tests cover every pure part: text transforms, search URLs, menu paths,
  activation history, window geometry, input-source and mirroring plans, OCR
  location, MIDI bytes and UMP words, OSC encoding (with a loopback UDP
  delivery test), key-mapping merge and hidutil parsing, Hyper and wheel
  decisions, camera-bubble geometry, clipboard merges, waits and palette search.
- Read-only probes on this Mac listed the enabled input sources (ABC, 2-Set
  Korean), input devices and on-screen windows, and sent a MIDI message from
  the virtual source.
- `hidutil` set/get was checked with an inert F20 → F19 pair and restored to
  empty.
- Not exercised live, to avoid disturbing the machine in use: toggling Wi-Fi,
  Bluetooth, mirroring and the Dock, ejecting disks, quitting apps, recording
  with the camera bubble, and applying real key remaps.
