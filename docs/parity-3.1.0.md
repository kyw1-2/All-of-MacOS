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

Updated for 3.3.3 (checked against the code and the 3.3.3 stream notes). Done in 3.3.3:
continuous value bindings (MIDI CC, Pitch Bend and pressure, Force Touch pressure and a
scroll with a modifier, driving the system volume, an app's volume or the display
brightness) and Force Touch stage triggers (BTT); Magic Boost presets, an EQ curve per
output with AutoEQ import, and one Audio Unit effect on the output (SoundSource); opt-in
link cards and OCR regions in image previews (Paste); text background styles, video
backgrounds, click display options and the annotation eraser (CleanShot). The commits are
in docs/release-3.3.3-audit-resolution.md. Done before: two-finger edge swipes and Force
Click triggers (BTT), per-app balance (SoundSource) and the Swish gesture set (3.3.2).

| Gap | Why it is still open |
|---|---|
| Continuous values from trackpad pinch, rotate and swipe travel, per-finger pressure, gamepad axes and mouse drags (BTT) | The 3.3.3 bindings read MIDI, Force Touch pressure and scrolling only; the other sources would need per-frame values from their recognizers. |
| Keyboard backlight as a binding target (BTT) | AOM has no keyboard-backlight API. |
| Audio Unit chains, AUv3 units and per-output or per-app effects (SoundSource) | 3.3.3 hosts one v2 effect for every output, in-process, without latency compensation. |
| Move window to Desktop N | No public API; repeated Space moves are unreliable across display layouts. |
| Floating menu submenus, searchable lists, focus-follows-mouse, Stage Manager toggle | Need a menu-model and a window/Spaces design; not started (3.3.3 added slider widgets only). |

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
