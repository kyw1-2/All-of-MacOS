## 3.3.3 (2026-10-30)

Fixes for the three 3.3.2 audit reports of 2026-10-29 (the main report, the Swish REA comparison, and the Swish deep report with its CleanShot X, BetterTouchTool and Paste appendix), and a redesign of the main window. docs/release-3.3.3-audit-resolution.md maps every audit ID to its fix or says why it is open; docs/window-snap-3.3.3.md has the gesture details. Backups cover every new setting; the audio diagnostics reset request and the recording camera and microphone stay out on purpose. Nothing below was tried on a real trackpad, MIDI controller, HomePod or in a real recording; the last section lists what still needs that.

### UI redesign

- One token file (`AOMTokens.swift`, 4 pt grid) and one opaque card, section, row, page header, notice and status pill for every page. Liquid Glass only on the toolbar, sidebar, ⌘K palette and floating chrome (macOS 26+, material before), following Reduce Transparency, Increase Contrast and Reduce Motion.
- Workspace: a hero with running, paused, blocked and setup states, Needs attention, module tiles with their main switch, quick actions, recent activity and a first-run checklist.
- Sidebar: search at the top, no footer switch; new Controls › Pause AOM / Resume AOM and Window › Diagnostics Console / Touch Visualizer commands.
- Window Tiling: the Trackpad Gestures card is now six sections (Title-bar snap, Gestures, Grid & layout, Keyboard, Dock & menu bar, Advanced) with captions moved into ⓘ; every setting is kept.
- Automation shows a notice when Accessibility or Input Monitoring is missing or AOM is paused, and a new empty state. Audio has the App Audio switch in its header. Settings has section titles above cards and groups General's ten loose rows. System Tools has a page header with the tool count. What's New uses the same sections, badges and pills.

### Swish title bar

- Multi-motion (F01, X01–X03): rest 0.25 s on a swipe or pinch (a haptic marks the lock), then move again to start the next gesture in the same touch. Lifting commits as before, a 2 s rest cancels only the locked gesture, and up to 4 motions queue and apply in order to the same window (`AOMTitleBarSnapMotionPause`; 0 turns it off).
- Tabs (F02, G11, G12): pinch in on a tab to close it (its close button, Chromium's close action, else ⌘W to that app while the tab is selected; never the window). Tap and hold a native or Safari tab, then lift, to move it to a new window, which is then chained. Close and detach in AppKit window tabs and Safari; close only in Chrome, Brave, Vivaldi, Arc, Dia, Orion, Xcode, VS Code and UPDF; nothing in Edge, Figma and Craft. Firefox exposes no tabs, so a pinch there still closes the window (`AOMTitleBarSnapTabs`, on).
- Start areas (F04, X05): the hit-test reaches tab bars under toolbars; with Super anywhere on (`AOMTitleBarSnapSuperAnywhere`, off), holding the Super key starts a gesture anywhere on a window.
- Modifier roles (F05, X20–X22): Super, General, Screen, Secondary and Tertiary can be reassigned; clashes are refused and Restore Modifiers puts back fn, ⌥, ⌘, ⇧, ⌃. ⇧ swipes use the 3 × 2 grid (up: almost maximize), ⌃ swipes the 3 × 3 grid.
- Keyboard (F05, X13, X24–X26): ⌃⌥⌘ + a direction moves to the display that way, ⌃⌥⇧ uses the 3 × 2 grid, a center key (Esc, ⌫ or ↩; `AOMTitleBarSnapHotkeyCenter`) centres or restores, and ,AOE (Dvorak) joins the key schemes. Esc cancels a gesture on show while AOM's keyboard tap is installed. The hotkeys stay off in secure text fields.
- Native tiling (F06, X31, X32): optional macOS tiling for halves, quarters and Fill where the app has Window › Move & Resize (macOS 15+); the system's tiling options are read, never written (`AOMTitleBarSnapNativeTiling`, off).
- External display timeout 0.5–10 s, 0 = no re-snap (X38, `AOMTitleBarSnapResnapDelay`). Hold ⇧ while dragging to keep a snapped window's size (X35). A tooltip by the pointer names where the window goes (X43, `AOMTitleBarSnapTooltip`, on).
- `TitleBarWindowSnap.beginChain(window:pid:reason:)`: a chained window takes title-bar gestures wherever the pointer is, for the rest of the touch and 3 s after it lifts.
- Fixed (S03, B04): re-snapping, resizing neighbours and drag to unsnap skip windows of apps paused in AOM, and stop when AOM is paused mid-way.
- Fixed (S05): delayed full-screen steps check the pause, the screen lock and the app again before they run.

### Dock & menu bar

- Fixed (S01, B01): the Dock pinch to quit checks the target app's pause, the global pause and the screen lock right before the quit request, and never targets AOM. The shared quit request (`politeQuit`) refuses AOM and paused apps for every caller.
- Fixed (S02, B02): a third or fourth finger spends the touch until every finger lifts. A 2→3→2 touch no longer pinches, swipes, taps or holds, and a pinch still waiting is taken back; a regression test replays the audit probe's frames.
- Fixed (S04): menu-bar swipe up checks each window's app pause right before each Accessibility write.
- Fixed (S05): delayed Dock and menu-bar work (the wait for a second pinch, ⌘N after the activation, scroll to top, the app-switcher watchdog, each window move) re-checks the pause, the lock and the target when it runs.
- Fixed (S06): menu-bar swipe up restores every window minimized on that display, not only the ones AOM minimized (twice or ⇧: every display), AOM's newest first. Skipped and failed windows stay remembered, and the HUD reports partial results.
- Fixed (B03, B06): Dock ⇧ double tap no longer hides apps AOM is paused for, and Dock and menu-bar HUD lines follow the On-screen HUD setting.
- Dock double pinch (F03, G25, G26): pinch in twice on an icon to minimize all the app's windows, out twice to bring them back (`AOMDockDoublePinch`, on). A single pinch then waits 0.35 s for a second one and acts when the fingers lift. A window a Dock gesture brings forward is chained to the title-bar snap (G29, G30).
- Menu bar (F04, X08, X09): the empty area, the app's own menu, other menu titles and status items are told apart, and menu titles and status items keep their clicks. Options: Dock gestures on the app's menu (`AOMAppMenuGestures`), a two-finger tap that scrolls the front window to the top (`AOMMenuBarScrollToTop`, G02), and the macOS ⌘-Tab switcher for tap, hold and scroll (`AOMMenuBarSwitcher`, G03; the default stays AOM's window switcher).
- Mission Control and App Exposé (X07): optional gestures on a thumbnail, pinch in to close the window (twice: quit its app) and swipe down to minimize it (`AOMMissionControlGestures`, off). The ✕ buttons and W/⇧W/M/H read thumbnails from WindowManager on macOS 27 (from the Dock before) and act only on the matching window; ⇧W closes the app's windows and no longer asks the process that draws Mission Control to quit. `AOMMissionControlHotkeys` is read live.
- A second trackpad takes over cleanly from one that went quiet with spent fingers.

### Clipboard privacy & Paste

- Fixed (PA-01, PASTE-32): excluded apps are never read through Accessibility, the optional screen model or its OCR for suggestions. They get no suggestions, and their items and paste history never feed the ranker (shelf, MCP `get_suggestions`, paste log). Capture uses the same trimmed, case-insensitive test.
- Fixed (PA-02, PASTE-33): password fields and secure keyboard entry get no suggestions, no model look and no paste-log entries, and a secret is never suggested.
- Fixed (PA-03, PASTE-35): MCP secret blocking scans every representation (UTF-8 and UTF-16 text, RTF, RTFD, HTML, URLs, file URLs, titles, image text, legacy types) at any length, after decoding percent-encoding, HTML character references, zero-width and full-width characters. `read_item` re-checks its whole reply, content searches never match hidden items, and Automation MCP hides credentials in trigger and menu definitions.
- Fixed (PA-04, PASTE-36): the classification cache key hashes the whole content, so a same-length edit in the middle reclassifies the item.
- Link cards (PASTE-16): opt-in page title, site name and image, under private web previews (`AOMClipboardLinkCards`, off). An ephemeral session with byte caps, one request per page per session, and never for secret-looking, local-network or numeric-host links.
- Image text (PASTE-11): OCR keeps its line boxes, matches are highlighted in cards and previews, and a region dragged in a preview can be read or copied as text or image.
- Paste semantics (PASTE-13, PASTE-22, PASTE-23): a pinboard can be deleted with its items (undoable); an optional one-pinboard-per-item mode, where ⌥-drag copies; searching from a pinboard covers every list (on; optional); new search operators `pinboard:`, `is:pinned`/`is:unpinned`, `on:`, relative dates (7d, 2w, 3m, 1y) and plural type names; MCP `delete_pinboard` gains `delete_items`. Keep History offers 1 Year and Forever; shortening retention or storage asks first, and Undo restores only that limit.

### BTT import

- Import Preset reads plain `.bttpreset` files and copied triggers, one or many (BTT-이식, BTT-50, BTT-51): all 152 trackpad catalog IDs (95 mapped, 6 of them approximately), keyboard shortcuts with left/right modifiers, key phases and hold times, key sequences, normal-mouse buttons, clicks, scrolls and drags, named triggers and 38 Other triggers, with about 180 documented action IDs. Compressed presets are refused with an export hint. Limits: 8 MB, 2,000 triggers, 64 actions per trigger.
- Imported triggers keep their BTT names, notes, app scope and enabled state. Approximate matches arrive disabled with their reasons in the notes, dropped steps stay as disabled placeholders in place, and IF/ELSE/Repeat skip the whole trigger.
- A report in three groups (Imported, Mapped Approximately, Skipped) names each trigger's BTT name, class and ID, what it became, and why.
- Security: AppleScript, JavaScript, shell commands, Shortcuts, runnable files and custom URL schemes arrive disabled and flagged for review. Every value is type- and range-checked, and malformed JSON is rejected without crashing (seeded mutation tests).
- The Import Preset panel offers `.bttpreset` files.

### MIDI & value bindings

- Fixed (BTT-입력, BTT-21): MIDI input decoded only 0x80/0x90/0xB0. It now decodes every channel-voice message, keeps running status across packets, skips SysEx and system-common data, and ignores realtime bytes inside a message.
- MIDI trigger types Pitch Bend (14-bit), Program Change, Channel Pressure and Poly Pressure, with "any" note, controller or program.
- Continuous value bindings (BTT-07): MIDI CC, Pitch Bend, Channel and Poly Pressure, Force Touch pressure and Scroll Up/Down with a modifier set the system volume, an app's volume (macOS 14.2+) or the display brightness through an input range, inversion, curve and output range, with an optional hold-peak. At most 30 writes per second per target, on their own queue; app scope, activation groups, the master switch and pauses apply.
- Force Touch stage 1 and stage 2 triggers with hysteresis (BTT-06; `AOMForceTouchStageHysteresis`, 0.1).
- Slider widgets in floating menus, bound to a continuous target.

### Recording

- Video backgrounds (CS-45): a colour, 8 gradients, a picture or the desktop picture, with padding, rounded corners and a shadow, laid out on the output canvas so 16:9, 4:3 (new), 1:1 and 9:16 fill with the background. Live preview; MP4 and GIF exports render it. Older projects keep their backdrop until edited.
- Click marks (CS-39): ring, filled circle or double ring, separate left- and right-click colours (a ⌃-click counts as right), size, and 0.2–2 s duration. Old projects keep the blue ring.
- Fixed (CS-38): once set, Show Cursor for recordings no longer depends on Show Mouse Clicks. New: editable pointer size and a cursor highlight, also over a pointer already in the video (`pointerInVideo` in the input track).
- Keystroke overlay: choose which modifiers make a shortcut (⌘ ⌃ ⌥ by default; ⇧ optional). Presentation renders, trims and the first Edit Recording session use the recording's click, pointer, highlight and keystroke options.
- Optional "Hide desktop icons while recording" (Finder's CreateDesktop), journaled and restored on stop, cancel, a failed start or restart, and at the next launch after a crash.
- Do Not Disturb (part of CS-37): the end Shortcut is journaled and runs at the next launch if AOM quit mid-recording.
- GIF (part of CS-49): frames of 480–1280 px (960 by default), loop or play once. Also "Scale Retina videos to 1x", and a camera and microphone choice that falls back to the default when the device is missing (the microphone still needs macOS 15).

### Annotation

- Text styles (CS-22): weight, any installed font family, alignment, a box, rounded box, pill or speech bubble behind the text, text, background and outline colours, outline width and shadow; presets Classic, Plain, Outline, Shadow, Label, Light Label, Pill and Speech Bubble. Saved in projects; text without the new fields renders exactly as in 3.3.2.
- Eraser (CS-23): X, with Object and Stroke modes and a size (`AOMAnnotationEraserMode`, `AOMAnnotationEraserSize`); one undo per drag.
- Image layers (CS-21): insert from a file (⌥⌘I, or Add as Layer in the ⌘I chooser), the clipboard (⌘V with an image, ⌥⌘V) or ⌥-drop; move, resize (⇧ keeps the ratio) and rotate (⇧ snaps to 15°); Arrange with ⇧⌘] ⌘] ⌘[ ⇧⌘[. Stored as PNG in the project; blur, pixelate and secure blur over a layer hide its pixels.
- Fixed: arrows and lines follow the drag (they were always drawn from top left to bottom right); objects saved before 3.3.3 keep their course. Several spotlights share one dimmed layer instead of dimming each other.
- Crop ratios add Original, 3:2, 21:9, 9:16, 3:4, 2:3 and 4:5, with the largest centred area. Text boxes grow with their lines, and ⌥↩ adds a line.

### Audio

- HomePod / AirPlay at 128-frame IO (A01): after a skipped HAL cycle the bridge fades back in over 5 ms instead of resuming mid-waveform. coreaudiod reports those gaps as HAL safety violations; AOM's own callback measured about 20 µs of the 2.7 ms cycle. Callback cost, the device's overload notices and its IO cycle usage are now in diagnostics, and the drift loop no longer aliases the mix-block rhythm at 128-frame IO.
- Output moves (A02): one consumer at a time. The old output fades out, the new one continues with the next sample and fades in, nothing is pulled twice, and the DSP state passes over intact.
- Diagnostics (A03): audio-health.json keeps the last 200 events with wall-clock times (cycle gaps, trims, underruns, limiter, late wakes, reconfigurations, device and route changes, taps, moves), recorded through lock-free realtime rings, and counters since the last reset that survive output and session re-creation (`AOMAudioDiagnosticsResetAt` requests a reset).
- Magic Boost presets (G01): Music (the 3.3.2 boost, sample for sample), Speech, Movie and Night, for the output and per app.
- Headphone EQ (G01): named curves assigned per output and run as a second 10-band stage that follows the output; AutoEQ ParametricEQ.txt files are fitted to the 10 bands.
- Audio Unit effect (G01): one installed v2 effect on every output's master chain, before Magic Boost and the limiter, made off the render thread and swapped with a 10 ms crossfade, with the generic editor.

### Not done / needs hardware check

Not done:
- Swish: moving a window or a Space from Mission Control (G01 of the deep report; macOS 27 ignores synthetic drags), minimized-window Dock tiles as an origin (X10), Super required for all gestures (X06) and on Dock icons, Include Screen Edges (X30), the portrait 3 × 2 axis swap (X28), live Resize Adjacent (X36), going back to the original display after a reconnect (X37), per-gesture switches (X19), the Active Event Listener (X18), Magic Mouse (X12, X47), Spaces hotkeys and key hold-and-release (X27), and Swish's double vertical swipe. Reset Preferences still misses the Swish settings (B05), and Dock/menu-bar gestures still do not coordinate with user two-finger triggers (B07).
- Clipboard: iCloud and other devices, shared pinboards, a device filter, iOS (PASTE-12, PASTE-38–40), Paste import (PASTE-41), file contents (PASTE-03), image bytes over MCP (PASTE-37), Quick Paste modifiers (PASTE-27); Forever is still bounded by the item and storage limits (PASTE-06); Base64 or split secrets are not decoded, and link cards have no DNS-rebinding guard.
- BTT: Magic Mouse, drawings, Touch Bar, Stream Deck, Notch Bar, MIDI and other device classes in imports, compressed presets, text-selection and power-mode triggers (BTT-34, BTT-35), Move Window to Desktop N (BTT-47), floating-menu submenus and search (BTT-29), continuous mouse-drag and gamepad values (BTT-16, BTT-23), keyboard backlight.
- Recording: following one window (CS-32), the microphone on macOS 14 (CS-33), mono and a level meter (CS-35), restoring the previous Focus (CS-37), a full-frame camera (CS-42), motion blur options (CS-46), GIF palette and length (CS-49).
- Audio: AUv3, per-output or chained effects and latency compensation; the HAL's 128-frame safety violations themselves; a reset button for the counters.

Needs a hardware check:
- Trackpad: the multi-motion lock, tab gestures per app (and detach with Korean and Japanese menus), Dock 2→3→2 and pinch-twice timing, a Dock gesture chained into a title-bar gesture, menu-bar parts on macOS 27, scroll to top, the held ⌘-Tab switcher, Mission Control on macOS 27 and 14–26, native tiling on macOS 15 and 26, the hotkeys in a password field.
- Clipboard: a Safari password field and Secure Keyboard Entry, an excluded app, link cards, image regions, pinboard delete and Undo, a real MCP client.
- A MIDI controller, Force Touch stages, and value bindings on built-in, USB and Bluetooth outputs and an external display.
- Recording: hidden desktop icons across a force quit, Focus recovery, backgrounds in MP4 and GIF exports, click colours, Retina 1x, camera and microphone choice, GIF play-once.
- HomePod: 20 minutes per state with diagnostics on, output switches during music, the Boost presets, an AutoEQ curve on real headphones, an Audio Unit on the HomePod.

## 3.3.2 (2026-10-29)

Swish parity for the trackpad title-bar snap, the HomePod / AirPlay crackle fixes, per-app balance, and the fixes from the release review of 2026-10-29. docs/window-snap-3.3.2.md and docs/airplay-crackle-3.3.2.md have the details. Not run on hardware: a real trackpad, and listening on a HomePod.

### N01: the AirPlay clock tests on throttled hosts

- The 3.3.1 host check classed a host with priority ceiling 63, timeshare priority 4 and ~200 ms wake-ups as normal, so the realtime-only checks ran and failed. `AirPlayHostDiagnosis` now reads darwin background, the priority ceiling, ordinary threads' priority and 2 ms timed-wait lateness on an ordinary thread; `AirPlayMixVerdict` passes a realtime mix thread anywhere, skips the realtime-only checks on a throttled host with its reasons, and fails a refused promotion on a host that allows realtime. Supply checks run everywhere.
- `scripts/run-tests.sh` runs the suite under `taskpolicy -a`, the policy the installed app runs under.

### HomePod / AirPlay crackle

- Both PCM queues resample with a Kaiser-windowed sinc and follow clock drift with a PI loop (±0.2 %), and every discontinuity is shaped: starts fade in, underruns and clears fade out, backlog trims crossfade, a full queue now clears instead of splicing, and the app chain runs its delay lines empty when a stream stops.
- The AirPlay output asks for 1024-frame IO (the device default of 128 frames overloaded the HAL), re-asks only while the device runs AOM smaller (backing off from 30 s to 10 minutes), applies format changes in place, and no longer restarts at all for a format notice that leaves its rate unchanged (a new rate is confirmed 250 ms later first).
  - Measured after installing 3.3.2: the HomePod used here accepts the request (status 0) but keeps 128-frame IO. Neither AOM nor a separate test process, through the device or the audio unit, gets more than 128. On that device the larger IO buffer does not apply; AOM logs it once and asks less and less often.
- The network bus limits at −1 dBTP (true peak, 4× oversampled detection) with a 150 ms release, for the receiver's lossy decoder; an app's Volume Overdrive switches to the same release on AirPlay in place, without a second limiter.
- App Nap guard on the mix clock (`.userInitiatedAllowingIdleSystemSleep` + `.latencyCritical`); tap membership changes wait for two syncs (browser helper processes came and went every second); one device list without the HomePod no longer stops its output (it goes only once the device is dead or missing for 1.5 s).
- AirPlay app queues start at their 80 ms target; removed sources fade out and are released off the render thread; adding a source allocates before taking the mix thread's lock; an output is not released while a source still fades.
- Diagnostics: `deviceCycleGaps`/`deviceGapFrames`, `deviceBufferFrames`, `reconfigurations`, `ignoredFormatNotices`, `tapRewrites`, trims, underruns and the mix clock's scheduling in audio-health.json; the host diagnosis and verdict in the test logs.

### Swish parity (title bar, Dock, menu bar)

- Y-axis fix: TouchPoint's y grows toward the top of the pad and 3.3.1 read it the other way, so vertical swipes ran backwards and a window at the top never reached a bottom quarter.
- Faster: the window under the pointer is looked up as two fingers land, a quick flick that engaged commits (it was taken for a tap), the immediate commit path applies writes at once, and a swipe that engages while the previous commit lands is applied when it lands.
- Chaining on the grid: halves, quarters, edges that grow a cell, an L or a diagonal for a quarter from anywhere, and (new) a longer swipe down from maximize to the bottom half. Grids 2 × 2 (default, no thirds), 3 × 2 (thirds and sixths) or 3 × 3 (ninths); almost maximize.
- Sensitivity (Quick by default, engaging after 4 % of the pad), Swish's 2 s hold-still cancel before or after a swipe engages (the preview fades over the last second), a still radius of 0.018.
- Pinch in closes the window (twice or after tap and hold: quits the app politely), pinch out toggles full screen (twice or ⌘: on the other display); two-finger double tap unsnaps or centres; tap and hold, then swipe: full screen, minimize, a Space; ⌥ swipe: a Space or close (twice: quit), ⌥/⇧ double tap: hide the app or the others, ⌘ swipe: the display that way.
- Swipe down on a free window minimizes (Swish), or centres as in 3.3.1.
- Dock: tap and hold, swipe through an app's windows, swipe down/up to minimize/unminimize (⇧ all), double tap to hide (⇧ the others), pinch out for ⌘N. Menu bar: hold and swipe for the previous/next app or lift for the window switcher, double tap to unsnap (⇧ every display), swipe down/up to minimize/unminimize every window (twice or ⇧ every display), ⌘ swipe to move snapped windows to the next display. The top-bar Space swipe now switches on lift.
- ⌃⌥ + arrows / WASD / IJKL / HJKL; drag a snapped window to unsnap it; re-snap after display changes; resize windows sharing an edge together; margin, preview animation and Stage Manager offset settings.
- New defaults for everyone: swipe-down minimize, pinches, tap and hold, modifiers, Dock and menu-bar gestures are on. Turn them off in Window Tiling › Trackpad Gestures (Swipe down on a free window › Center, Pinch gestures, Tap and hold gestures, Modifier gestures, Dock gestures, Menu-bar gestures). What's New says so.

### Per-app balance

- A balance slider for every app in Audio (the far side is attenuated, the near side stays at full level; ramped over 5 ms and lock-free on the render thread), saved per app (`AOMAudioBalance_<bundle id>`), included in backups and reported by `list_audio_apps`.

### Release review fixes (2026-10-29)

- The Dock hit-test set the system-wide element's Accessibility timeout, which is AOM's process-wide timeout: it now asks the Dock's own element with per-element limits, and nothing sets the process-wide timeout (a source test checks).
- The title-bar hit-test runs against the window's owner app (PID from the window server), each request bounded to 0.25 s and the walk to 0.3 s; the frame and full-screen reads and the Space-move grab-point test are bounded too.
- An engaged swipe counts as a tap only below `min(tapTravel, 0.6 × engage)`; a 5.5 % flick commits.
- The top-band Space swipe leaves an ordinary window's title bar under the band to the snap, and switches on lift so a 2 s rest cancels it after the swipe as well.
- A two-finger touch on a title bar no longer also runs BTT-style triggers on two-finger swipes, pinches, taps, double taps or long touches; the snap owns it.
- A longer swipe down from maximize (or almost maximize) goes to the bottom half; a short one still puts the window back.
- The menu-bar and Dock window lists use per-element timeouts and a 1 s budget; gestures skip apps AOM is paused for even when they are in the background.
- The Hold still and Sensitivity pickers show every value the Settings Hub writes (0.5 s and 2.5 s, and Custom).
- Audio: no allocation under the mix lock in `add`, Overdrive keeps one limiter across routes, fading sources keep their output, AirPlay app queues start at the target, the IO re-request only while smaller, and the nap guard no longer blocks idle sleep.
- Tests: 1,376 run, 0 failures, 3 skipped (1,358 before the review fixes; `ReviewFixes332Tests` is new, and the tests that encoded the old tap rule, 40 ms start, mid-swipe Space switch, IO re-request and nap-guard options were updated).

## 3.3.1 (2026-10-28)

Stability fixes for the 2026-10-28 audit of 3.3.0 (findings F01–F12). docs/audit-3.3.1-stability-20261028.md lists causes, tests and what still needs a person to check. The stability audit is not fully passed: the hardware checks (real trackpad, AirPlay listening, a 65-minute recording) have not been run.

- Pausing (F04): Automation paused (or a timed, per-app or modifier pause) now also stops the top-bar Space swipe, Dock pinch to quit and the title-bar snap, including a gesture already under way, and releases the trackpad stream. All input layers share one pause check.
- Dock pinch to quit (F01) only asks the app to quit, like its own Quit command. It no longer force-quits an app 1.5 s later, so an app asking to save keeps its work; the HUD says when an app is still open.
- AI tools over MCP (F02, F03): large replies arrive whole on the app's non-blocking sockets (a 1 MB reply used to stop after 4 KB). Each connection queues a reply and sends it as the socket accepts data; up to 64 MiB can wait per connection, and a client that reads nothing for 30 s while a reply waits is disconnected on its own. An AI tool closing its connection can no longer terminate AOM through SIGPIPE. Unreadable or method-less requests get a JSON-RPC error instead of no answer, and when the app closes a connection the stdio bridge answers the requests still waiting with an error before it exits.
- Title-bar snap (F05): lifting applies the preview however long it was held (3.3.0 hid a held preview after 1.2 s and the lift then did nothing); a third finger, sleep or a break in the trackpad stream cancels instead of moving the window; frames from a second trackpad no longer interfere; granting Accessibility after launch turns the snap on without a relaunch.
- Recording (F06): the editable pointer track no longer stops at 50 minutes. Past 60,000 points it keeps covering the take by thinning its samples, within a 24 MB sidecar; disk space and the sidecar size still bound a take. Sidecar limits and errors are accurate; sidecar saves run off the main thread; a take that macOS or the writer cut short reports "Recording Stopped Early"; warnings no longer overwrite each other; recordings refuse to start with less than 2 GB free; outcomes are logged to Diagnostics/recording-events.jsonl.
- Backups (F07): backups cover AOM's automations and settings. They do not hold clipboard history, captures and recordings, or Keychain items. Only AOM's own backup files are listed, restored or pruned (other JSON files in a custom backup folder used to be deleted past the limit); gestures and their timing, title-bar snap, key remapping, pausing rules, shortcuts, capture, text capture, recording, clipboard, audio and appearance settings are backed up, and every other setting is left out for a stated reason (this Mac's folders, the backup options, the pause switch, AI tool and screen-reading access, runtime state); each backup keeps the settings of its own moment, including which were still at their defaults, so a restore puts them back exactly; Settings › Backups says what a backup holds and previews what a restore would change; a restore reads everything first, keeps the current automations and settings as a snapshot (and changes nothing if it cannot), never deletes the backup it restores, and never pauses or resumes automation; imports and restores report success or failure.
- Clipboard (F08): a locked Keychain or an unreadable history file is shown as such, with Try Again or Recover Storage on the same screen, instead of "Your Clipboard Is Empty".
- System Tools (F09, F10): Flush DNS checks every step and offers the administrator prompt when macOS refuses, including the "No matching processes belonging to you" answer `killall` gives a non-root caller (it used to say "flushed" regardless); Empty Trash reports what it could not delete and asks for Full Disk Access when it cannot read the Trash; on a Mac with the default Finder setting the first Desktop Icons click now hides the icons (it used to write "show"); Hidden Files and Desktop Icons report a setting that could not be written.
- AirPlay mix clock (F12): the mix thread records its start-up and every wake-up and reads back how macOS really schedules it (audio diagnostics and the log show both). The cause of the failing test was a host that demotes the realtime thread (timeshare, priority 4, wake-ups ~200 ms late) combined with a catch-up of at most four blocks per wake-up. Now a late wake-up renders every overdue block; the 4 ms time budget applies only while the thread really runs realtime. Steady supply measured 48,000 frames/s within ±0.21 % in release and debug builds, application and clamped policies, idle and loaded. The realtime test keeps its thresholds, fails on a refused promotion and is skipped only when the host clamps the test process; a new test checks start-up and steady 48 kHz ±5 % everywhere. (These default-environment passes were measured where the host's priority ceiling was 4; a throttled host with ceiling 63 still failed — see 3.3.2, N01.)
- Review fixes before release: outcome messages with a reason or an instruction are shown in full (a larger HUD for up to 8 s; a restore that needs a relaunch uses an alert); the clipboard's locked-Keychain texts say when to choose Try Again, and the ⇧⌘V shelf no longer says "History is empty" while loading.
- Updates (F11): AOM does not check for updates itself (GitHub Releases, installed by hand). The unused update checker no longer claims "up to date" and understands the published tag format.
- Layout and accessibility (F11): Window Tiling puts the trackpad and drag-to-snap switches before the preview and gallery; System Tools fits the Finder and network tools in one section; a few fixed tiny font sizes now follow text styles, the hover-only Run button has a VoiceOver action, and the Settings search field has a visible edge with Increase Contrast.
- Beyond the audit list: actions that send keys, clicks or scrolls report failure when AOM may not post events, and Screen Recording, Dark Mode, input device, force quit, window batch and copy actions report what actually happened (a multi-step automation without "Continue on Failure" now stops at such a step); an unreadable Capture History manifest or recovery journal is kept under a new name instead of being overwritten, and Capture History is rebuilt from its saved images (shown pinned, so no retention pass can delete them).

## 3.3.0 (2026-10-28)

- Window snap (Swish port, round 2): applies the DeepSeek Harness Ghidra pass of Swish 1.13.3.
  - The title-bar snap now commits like Swish: AXEnhancedUserInterface is suspended, and size → position → size is written and read back.
  - Windows with a fixed or minimum size stay flush with the edge they were snapped to, instead of failing the move. This also applies to the halves, thirds, quarters, sixths, maximize and next-display maximize actions.
  - The preview settles on the frame the window really took.
  - A swipe down on a window AOM snapped restores its pre-snap frame (unsnap).
  - Quarters snap from a swipe along both axes, in either order.
  - A haptic plays as the preview moves to a new zone.
  - New option to bring the window forward after snapping (on by default).
  - New option to keep the pointer on the title bar (off by default).
  - A readiness checklist covers Accessibility, haptic feedback and the Mission Control shortcuts.
  - The Trackpad Gestures card now groups the title-bar snap, top-bar Space swipe and Dock pinch to quit.
  - See docs/window-snap-3.3.0-swish-dsh.md.
- UI/UX finishing pass, informed by 86 new references (see docs/ux-reference-review-3.3.0.md):
  - One window minimum. The diagnostics drawer floats over the page when the window is narrow.
  - One canvas, owned by the shell.
  - Animations across the app respect Reduce Motion, and the looping gesture previews stop.
  - Increase Contrast and Differentiate Without Color outline chips, badges, notices, key caps and layout diagrams.
  - Accessible names for the remaining icon-only buttons.
  - Compact mode buttons no longer shrink their text below about 10 pt.
  - Glyph-only icons replace the decorative gradient tiles.
  - System Tools can be searched from the toolbar.
  - ⌘N and ⌘F work on Automation and from Workspace.
  - The engine is called "Automation" everywhere, and the Help menu reads Show Welcome Again.
  - The developer HUD test now appears only while ⌥ Option is held.
  - Settings sheets can be resized.
  - The Tiling side column adapts to the window width.
  - Insights says when the day or week figures are cut short by the bounded event log.
  - Removed the dead 1.x tour copy.
- Fixes:
  - The title-bar snap now keeps the trackpad stream running on its own, so it keeps working with no trackpad triggers and the Space swipe and Dock pinch both off.
  - Turning those gestures on or off takes effect without relaunching.
- What's New is updated for 3.3.0.
- Tests: 1,144 run, 0 failures, 3 skipped. TitleBarSnapTests grows from 9 to 22.

## 3.2.0 (2026-10-27)

- UI/UX: push the Liquid Glass redesign through the app. The content canvas is now a behind-window material on macOS 26, so the desktop shows through the gaps between frosted cards (the window stays non-opaque but the system toolbar/sidebar glass is preserved); the spacing scale is one notch tighter; and the Workspace, Capture, Tiling and Insights pages fill the window instead of leaving the lower half empty. Reduce Transparency keeps the opaque surfaces.
- System Tools: curated to the genuinely useful, regrouped into Finder / Network / PDF & Media / Cleanup. Removed Wi-Fi Off, Lock/Hide Flags, "Who's Using It?", Batch Rename (Finder does it) and Force Delete.
- Menu bar: leaner. A new Windows section (Left/Right Half, Maximize, Center, Window Switcher); App Audio Engine, Drag to Snap, window pinning, front-app shortcuts, displays and the HUD controls moved into a tidy More submenu; Paste Next in Stack dropped from the menu bar.
- Window snap: a Swish-style two-finger title-bar snap with a live translucent preview and a haptic on commit (off by default, in Window Tiling › Trackpad Snap). Behaviour recovered by REA/Ghidra of Swish 1.13.3; AOM's own implementation. See docs/window-snap-3.2.0-swish.md.
- Tests: 1,131 run, 0 failures, 3 skipped. Made the top-bar Space-swipe test independent of the session's screen-lock state.

## 3.1.0 (2026-10-27)

- Interface: adopt the macOS 26 design system. System window chrome and sidebar, Liquid Glass only on floating chrome, one content width and radius set, System Settings–style Settings with sidebar search, and a SoundSource-style Audio page. See docs/ui-liquid-glass-3.1.0.md.
- Audio: fix HomePod/AirPlay crackle with a realtime mix thread, a transparent lookahead limiter (ceiling 0.977), block EQ (2.95 % → 0.62 % of a core) and bounded reconnects. No core audio services are touched. See docs/audio-3.1.0-soundsource-boost.md.
- Audio: Magic Boost now follows SoundSource 6 behaviour (512-frame lookahead, one switch for the output and per app); Volume Overdrive raises an app to 400 % through its own limiter. Stored gains above 100 % migrate to Overdrive.
- Automation: 33 new actions — selected text, clipboard items and transforms, menu paths, context menus, previous app, window title and bulk window actions, input source, sound input, mirroring, eject, Dock, Bluetooth, Wi-Fi, emoji viewer, on-screen text (OCR) with click, MIDI, OSC, color picker, haptics, distributed notifications and Restart Recording. Wait For gains app quit, file gone and focused-window conditions; Toggle Do Not Disturb runs a named Shortcut.
- Keyboard and mouse: key remapping and a Hyper key (⌃⌥⇧⌘, tap for Escape) through hidutil, applied only while AOM runs; reverse a wheel mouse without changing the trackpad.
- Capture: restart a recording, Do Not Disturb while recording, a live mirrored camera bubble that stays out of the video, and a word-level Smart Highlighter.
- Clipboard: dragging between pinboards moves an item (⌥ copies); merged pastes keep HTML and RTFD formatting.
- App: a new menu bar mark with paused and off states, What's New once after an update, and app/file search in the command palette.
- Still open: continuous and pressure trackpad gestures, video backgrounds, link cards. See docs/parity-3.1.0.md.

## 3.0.11 — AirPlay playback continuity (2026-10-27)

## 3.0.14 (2026-10-27)

- Reorganize Audio into a compact mixer, devices, and effects; keep per-app volume and mute visible and reveal routing and EQ in context.
- Align the window titlebar with the content canvas, bring Audio closer on Workspace, and reduce the height of capture launchers and EQ.
- Prevent audio capture from starting in isolated UI preview mode.


## 3.0.13 (2026-10-27)

- Add an Audio entry and effect status to Workspace; improve mixer navigation, app filtering, reset actions, and accessible names.
- Process app boost per stream and output boost after mixing on each managed output, followed by the output limiter. Both can increase loudness.
- AOM's compressor has no lookahead and is not claimed to reproduce SoundSource's proprietary processing.


- Prevent zero-frame capture callbacks and paused video transitions from being interpreted as active output stalls; preserve the native route while playback switches streams.
- Keep large AirPlay output slices fully primed before rendering to avoid repeated partial-block silence at 44.1/48 kHz.
- Isolate remote-output lifecycle queues by device while preserving same-device teardown/start ordering, so one slow receiver cannot block other speakers.
- Ramp volume and mute changes over 5 ms; crossfade live EQ updates instead of applying abrupt filter state changes.
- Scope manual remote reconnection to apps sharing the chosen receiver; leave unrelated local video players and receiver sessions undisturbed.
- Clarify native/direct playback and connection errors in audio workspace; improve reconnect, mute and volume accessibility.
- Add regressions for callback transitions, large output slices, independent receiver teardown, ramp continuity, EQ changes and PCM stability. Physical-device AirPlay testing is still recommended.

## 3.0.10 — Continuous audio delivery (2026-10-26)

- Replace mutex-protected capture and AirPlay queues with bounded single-producer/single-consumer stereo queues. A busy control or producer lock no longer turns an entire IO block into silence.
- Use acquire/release atomic cursors, consumer-owned resampling state and coordinated clear requests; never overwrite frames still in use.
- The dedicated AirPlay mixing worker waits for short source-list/handoff operations instead of dropping its mix block. HAL callbacks remain non-blocking.
- Request a 1,024-frame quantum on AOM's private AirPlay capture aggregates where supported, reducing unnecessary 128-frame wakeups without changing the system output device.
- Add opt-in local queue/dropout counters without recording audio, plus wraparound, clear and concurrent ordering regressions.
- Skip EQ and compressor work while an app is idle or its capture queue is still priming, keeping spare CPU for realtime delivery.
- Retain the 3.0.9 EQ headroom, linked stereo limiter and full-session native mute protections.

## 3.0.9 — EQ distortion and audio recovery (2026-10-26)

- Hold native audio mute for the full capture session, and resolve returning helpers by verified ownership instead of shared helper bundle IDs to prevent overlapping tap membership.
- Reserve headroom from the combined app/master EQ response, avoiding hard clipping on loud material and boosted presets.
- Sum applications before linked stereo peak limiting; preserve waveform shape instead of flattening each app's peaks.
- Recover outputs whose device UID survives a changed CoreAudio object ID; restore native audio if recovery fails.
- Detect stalled capture and render callbacks, and base processing status on recent rendering rather than historical counters.
- Exclude AOM's raw audio PID before helper ownership resolution to prevent accidental self-capture.
- Mute All uses a current app snapshot. Automation rejects malformed PIDs, Boolean volume values and disconnected route UIDs, and exposes recent capture/render and EQ state.
- Reject malformed database ordering and shortcut values without crashing; leave the database intact for recovery.
- Add production PCM-path and distortion regressions, and replace an obsolete simulated boost test with the actual compressor.
- See docs/audit-3.0.9.md for measurements, verification and limits.

## 3.0.8 — Automation, audio and capture follow-up audit (2026-10-26)

- Mouse positioning uses converted Quartz display coordinates, including vertically arranged displays and Dock/menu-bar insets.
- Mouse actions and scrolling-capture events carry AOM's self-event tag to avoid recursive input triggers.
- Small smooth-scroll amounts span the requested duration. Integer extremes in imported scroll actions are rejected without overflow; function-key lookup handles extreme indices.
- EQ filters recover from NaN, infinity and arithmetic overflow instead of poisoning persistent channel state.
- Clipboard preview statistics stream through text without word/line arrays and count CRLF as one line break.
- Script client requests enter on main so its active-call dictionary and completion lifecycle share one queue. Removed unreachable legacy in-process script implementations.
- Trimming preserves click-only overlays and camera-only sidecars even without a cursor track.
- Added behavioral regressions; scope and interactive-test limitations are in docs/audit-3.0.8.md.

## 3.0.7 — File utilities and export reliability (2026-10-26)

- Recursive .DS_Store cleanup now visits hidden files and folders.
- Lock/unlock and hide/show preserve unrelated file flags and operate on the selected symlink itself.
- Batch renaming validates names and collisions before moving files, keeps literal replacement text and extensionless names, and reports filesystem failures.
- System Tools WebP conversion uses the bundled codec and refuses to overwrite an existing output.
- Cache cleanup counts only successful removals, includes top-level files, and preserves AOM caches regardless of name casing. Tests use disposable cache roots.
- Cancelling GIF export cancels its background worker and removes temporary output.
- Automation URL aliases accept mixed-case host names consistently.
- Adds regressions for these behaviors. See docs/audit-3.0.7.md for scope and verification limits.

# All of MacOS — Changelog

A concise, English-language overview of user-facing changes. Release assets, build identifiers, checksums, signing information and version-specific verification notes remain authoritative in [GitHub Releases](https://github.com/kyw1-2/All-of-MacOS/releases).

## 3.0.0 — Design overhaul
- **Native on macOS 26/27:** AOM now ships with the SDK it is built with, so the system draws Liquid Glass sidebars, toolbars and controls instead of the compatibility look. The minimum system stays macOS 14.
- **Workspace:** one card per tool with its live state and everyday action — capture modes and the latest shots, the newest clipboard items, pinned or recent automations, and your snap zones as miniature layouts. Problems and a running recording appear on top only while they exist.
- **Every page, one grammar:** a calm canvas with cards, the page title in the toolbar, and filters as chips with counts (Automation inputs, capture kinds, pinboards). Capture gets a mode bar in CleanShot's order and S/M/L thumbnails; Window Tiling previews a layout before you use it.
- **Settings:** a System Settings–style sidebar with search, titled groups, side-by-side choices for short options, labels that flip their switch, and new Shortcuts and Permissions panes with live status.
- **Command palette, first run, menu bar:** a glass palette with clearer results; a three-step welcome (the four tools, the access they need, the shortcuts) instead of the old tour; and a menu bar menu grouped into Capture, Clipboard and Automation with the everyday capture modes at the top.
- **Floating surfaces:** Quick Access, Capture History, Paste Stack, the recording bar, the capture toolbars and the text-capture HUD share one material.
- Shortcuts, automations, clipboard data and settings are unchanged. References and decisions: `docs/design-overhaul-20261024.md`.

## 2.3.0 — Natural capture behaviour and competitive parity
- **Quick Access:** a Trash button sits beside More on the hover curtain (⌘⌫ too) — one click deletes a fresh capture; only recordings ask first. Cards auto-close after 5 minutes for people who never chose a setting (they stay in Capture History); a stored choice is never changed.
- **One close rule:** Copy, Save, Pin and Annotate close the surface they were used from — Quick Access card, expanded preview, Capture History — and ⌥ keeps it open; a failure never closes it. Capture History selects on the first click, and its menu offers the same core actions as the card. The clipboard shelf's Copy stays open on purpose and now says so.
- **After Capture = Copy/Save** no longer shows a second card (Capture > "Also Show After Copy/Save" brings it back; a failed copy/save still shows it).
- **No drag stall:** unsaved captures get their drag file encoded off the main thread on hover; dragging does not save the capture.
- **Clipboard:** Erase History (pinboards kept, undoable) in Settings, the shelf and the library — the library's old "Clear All History" no longer deletes pinned items. Lowering the item limit asks before deleting. Kind, date and app filter chips under the search field, synced with typed type:/from:/board: tokens. Remove Background for images (new item; original kept), also in Quick Access and the editor.
- **Capture:** area selections snap to window and screen edges (hold ⌃ to place freely; Capture > Snap Selection to Windows). Recording keystrokes: Shortcuts Only / All Keys, position, size and light/dark style.
- **Automation:** activation groups can require days and times, power source, display count or an app's window, edited in Automation › scope menu › Edit Activation Groups…. `{{var:name}}` places workflow variables (for example a script's output) into Type Text, Open URL, HUD and notification text. AppleScript: `run trigger`, `capture`, `restore quick access`, `open aom url`.

## 2.2.0 — Glass window, compact rhythm
- **The window is glass now:** the chrome (sidebar, toolbar) sits on a real behind-window blur that shows your desktop through it — the System Settings / Things arrangement — while the page floats as an inset rounded card with a soft shadow and a hairline edge. Reduce Transparency and Increase Contrast restore the plain opaque window. The command palette keeps its material and gains the same lit rim.
- **Compact rhythm:** rows tightened (30 pt single-line, 44 pt two-line), page padding 24→20, section spacing 24→18, sidebar search field and footer trimmed — noticeably more of your content per screen at the same readability.
- **Depth with restraint:** filled buttons gained a vertical accent gradient with a lit top edge, and shortcut key caps read as tiny glass chips. Content surfaces stay opaque — glass belongs to chrome and floating layers, never to lists you read.
- Everything from 2.1.0 (selection contrast, all-input statistics, palette actions, searchable settings) is unchanged.

## 2.1.0 — Readability and honest numbers
- **Selected rows read again:** list rows (Automations, Clipboard library) used fixed label colours that macOS selection does not invert, so a selected row showed dark text on the accent fill. Rows, icons, pins and shortcut key caps now use hierarchical styles that invert with selection — key caps turn white-on-translucent inside a selected row. The command palette's keyboard selection, previously a 6% wash, is a clear accent fill; its no-results state gained a "Clear Search" button.
- **Empty states never clip:** every empty state's actions now wrap to a column when they do not fit (ViewThatFits), fixing the Automation input-filter empty state where both buttons were cut off by the list column; its primary button is "New Automation" instead of "New Trackpad Automation".
- **The editor gets its width back:** the trackpad preview in the When section shrank from a 180×140 block (plus padding) to 120×92 with proportional animation — about a third less height over the trigger summary.
- **Every automation counts:** keyboard, mouse-button, drawing and system triggers now record their runs, so Insights' figures and the Workspace's last-run times cover all inputs instead of only trackpad gestures (runs are counted once at dispatch; the trackpad keeps its own detect/fire statistics and is not double-counted).
- **Clipboard:** selected shelf filter chips and library pinboard chips use the accent fill with a luminance-derived label (yellow/orange/cyan accents get a dark label instead of unreadable white); the same rule protects every filled button. The shelf's empty state offers Resume / Open Clipboard Settings when recording is paused or storage failed; the Paste Stack panel gained the standard empty state with "Open Clipboard Library", a semantic status dot, caption-sized status text and a 22 pt remove hit target; gallery card previews end on a whole line (line limit instead of a mid-line clip) and card headers match the list-row tokens.
- **Command palette:** all capture commands show their real bound key caps (Window, Full Screen, Text, Record — previously only Area and the shelf did); secondary actions became a list — ⌘↩ keeps running the first, the rest live on the row's right-click menu.
- **Settings:** rows show their category colour icon again; menus size to their content so long labels ("Microphone + System Audio") stop truncating; the selected category is an accent-tinted chip instead of a faint grey; the permission row shows a live "All granted / n of m" badge beside Review; searching "shortcut/hotkey/단축키" now reaches Clipboard Storage, where the shelf shortcut recorder lives.
- **Consistency:** recording banners and permission/capture status colours use the app's warning/danger/positive tokens (respecting accent and high-contrast settings); the sidebar footer switch matches the app control size; capture overlay capsule labels shrink instead of clipping; the Window Tiling stage tops out at 280 pt so the layout grid leads.
- **Cleanup:** removed three dead view files' worth of unused code (the pre-2.0 sidebars, an unmounted inspector panel, a never-used shared search field — about 1,500 lines); the tiling editors moved to SnapEditors.swift. Palette search/Esc logic is extracted and unit-tested (10 new tests); automation statistics recording gained 3 tests. Known limitation (unchanged): Insights' 24-hour and 7-day figures derive from the recent-event ring buffer, so very heavy use can trim a day.

## 2.0.0 — A Mac window, built around your work
- **Navigation:** the capsule tab bar is gone. A labelled, collapsible system sidebar holds the six places (⌘1–⌘6, View ▸ Hide Sidebar) with Search at the top and the automation switch, Settings and Help at the bottom. Each page owns its toolbar: title and status, view switch, search and its primary action in the same places on every page.
- **Workspace:** problems first and only when they exist (permissions, paused automation, a shortcut conflict, clipboard storage), then Capture Area / Clipboard Shelf / Search with their real shortcuts, your pinned and recently used automations (with last-run time and a hover Run button — never for Type Text), recent captures you can copy, edit or drag, and recent clipboard items you copy with a click. The five-figure strip is one quiet line that links to Insights.
- **Automation:** list → wide editor. Rows show each automation once (no repeated input name), what it does with its key value (⌘W, Bedroom, …), its keys, pin and switch. The editor reads Name · Applies to · Enabled, then When, Do, Options; Test sits next to its result (running, ran, failed). The sortable table is a view switch. Scope moved to the toolbar; narrow windows switch between list and editor.
- **Command palette:** opens focused, ↑↓ to move, ↩ primary, ⌘↩ secondary (Run Now, Copy as Plain Text, Copy capture), Esc clears then closes; grouped when empty, one ranked list while searching. Its shortcut is ⌘K unless an automation or capture/clipboard hotkey owns it, then ⇧⌘K. Available as View ▸ Search….
- **Clipboard library:** list with a preview built for each kind (full text, image, link with Open in Browser, files), Copy and More next to it, Return copies the selected row; pinboards and type filter head the list. The ⇧⌘V shelf is unchanged.
- **Capture:** the tool column became the toolbar's Capture menu (with your shortcuts); cards offer Copy, Edit, Show in Finder and Pin on hover and drag straight into other apps.
- **Insights:** a period switch (24 hours, 7 days, all time) scopes every figure; labels say what each number is.
- **Design system:** system semantic colours and the user's accent, a 13 pt desktop type scale, spacing/size/motion tokens, glyphs without coloured squircles, hairline separators, no press-scaling. Shared row, heading, notice, run-status and key-cap components.

## 1.9.2 — No password typing at the lock screen
- Type Text refuses to run while the screen is locked, and stops if the screen locks mid-way. The lock screen also turns on Secure Event Input, so 1.9.0 and 1.9.1 registered their secure-input shortcuts (including the ⌃ alias) there as well; nothing is registered while locked now.
- Documented the one-time Keychain prompt each new build triggers for clipboard history.

## 1.9.1 — Sheet polish
- The Automation editor fits shorter windows: its header shows the scope and holds pin, duplicate and delete in a ⋯ menu, and the input type moved into the Trigger section, replacing the separate Details box.
- Capture Library thumbnails use the sheet's light inset grey instead of a dark backdrop; cards are wider so the kind, size and time caption is never cut off, and the kind is omitted when the title already states it.
- Insights' most-used rows use the 1.9 type scale (14.5 pt titles, 12 pt details).

## 1.9.0 — Unified sheets and password-field typing
- Redesigned every page as one flat sheet on a neutral canvas: sections are separated by hairlines rather than separate cards, shadows are nearly invisible and colour is limited to small icons, state and one primary blue. Glass and ambient gradients are gone.
- Rebuilt the Workspace to fit on one screen: a five-figure summary strip, the automation list with inline switches, and a This Mac column with permissions, Drag to Snap, clipboard history, password-field status and quick actions.
- Moved the Automation editor inside the page sheet with a draggable divider, so it no longer covers the navigation row; dropped the redundant Type column.
- Window Tiling, Capture, Clipboard and Insights now share the same sheet layout and fill the window height; Insights shows inputs and configuration side by side on wide windows.
- Raised the type scale (14 pt body, 26 pt titles) and verified light and dark appearance.
- Fixed Type Text in macOS password dialogs: ⌥ and ⌥⇧ hot keys are withheld by macOS during Secure Event Input, so AOM registers a ⌃-added alias (for example ⌃⌥P for ⌥P) only while Secure Input is active and never over an existing binding. Typing uses a private event source so modifiers cannot latch; the 1.8.0 pasteboard round-trip was removed.

## 1.6.0 — Unified visual design
- Introduced a consistent app-wide design system with a light-gray canvas, borderless elevated cards, clearer typography and a single blue accent.
- Refined navigation, page headers, controls and the Home dashboard for denser, more coherent presentation.
- Applied shared visual components across Gestures, Window Tiling, Capture, Clipboard, Insights and Settings.
- Multiple archived development builds share the 1.6.0 version; inspect each release's build number to distinguish artifacts.

## 1.5.0 — Navigation and Home
- Rebuilt the main window around one persistent navigation rail and a shared page header.
- Reorganized the Home screen with primary actions, automation status, metrics and responsive activity panels.
- Consolidated search, capture access and diagnostics into consistent navigation controls.

## 1.4.0 — Searchable Settings
- Replaced separate settings pages with a unified, searchable settings hub.
- Added category chips, persistent search controls and grouped settings cards.
- Applied preference changes immediately and moved advanced controls into contextual sheets.

## 1.3.1 — Capture visibility
- Extended the screen-capture visibility preference to annotation, recording export, expanded previews and floating windows.
- Centralized visibility handling across AOM-managed windows. Actual capture exclusion remains dependent on macOS and the capturing application.

## 1.3.0 — Local workflow expansion
- Added multi-file drag support, reorderable clipboard collections, expanded search and configurable clipboard interaction.
- Extended recording editing with ordered ranges, zoom suggestions, editable camera/shortcut layers and export presets.
- Added floating action menus, more local input/trigger options, scoped automation commands and Finder integrations.
- Introduced privacy-conscious, opt-in link previews. Some hardware and operating-system combinations remain unverified.

## 1.2.8 — Responsive workspace and text automation
- Refined the native main window, gesture editor, sidebar and appearance handling.
- Reduced unnecessary UI-thread work in clipboard and navigation paths.
- Updated Type Text to emit per-character key events with configurable intervals without replacing clipboard contents.
- This release reported 873 passing tests; protected input fields may still reject synthetic typing.

## 1.2.7 — Clipboard responsiveness
- Improved focus handoff before direct insertion into destination applications.
- Moved clipboard payload processing, rich-text preparation, searching and previews off the primary UI thread.
- Prevented stale background results from overwriting newer edits, selections or copied content.

## 1.2.6 — Reliable automation and editing
- Made capture-dependent workflows wait for actual output completion and report failures.
- Improved OCR option handling, encrypted clipboard activity-log persistence and legacy-data preservation.
- Reduced UI-thread work for gesture history, preset saving, image decoding and preview transforms.
- Added revision checks to reject outdated asynchronous results.

## 1.2.5 — Clipboard, capture and automation fixes
- Improved clipboard polling and support for additional rich-text and image formats.
- Reduced synchronous processing in direct insertion, screenshot encoding and file saving.
- Fixed action ordering, cancellation behavior and stale capture reuse.
- A separate 1.2.5 hotfix strengthened archive recovery, encrypted activity logging, local automation access and capture-history memory management. Distinct tags identify the two 1.2.5 source revisions.
- The initial 1.2.5 release explicitly did not run functional or regression tests; this is not a claim of verified runtime performance.

## 1.2.4 — Dynamic clipboard filters
- Populated application filters from recorded clipboard sources instead of a fixed list.
- Improved filtering for historical entries and aligned the main-window header boundary.

## 1.2.3 — Faster text capture
- Added a faster single-pass OCR path for interactive text selection, retaining configurable recognition settings.
- Reduced clipboard-shelf startup and long-item rendering work.
- Fixed cancellation-related stalls in text capture.

## 1.2.2 — Native main window
- Introduced a source-list layout, sortable gesture table and optional inspector.
- Refined the keyboard-accessible clipboard shelf and shortcut conflict handling.
- Fixed interactions across capture, navigation and gesture management.

## 1.2.1 — Design and performance
- Unified native UI components and accessibility-aware appearance.
- Improved gesture filters, scope management, window-tiling layouts and Capture Studio entry points.
- Refined clipboard history and instant text capture. An earlier build was superseded by a later 1.2.1 build.

## 1.2.0 — Native UI foundation
- Added a native navigation split view, unified toolbar and keyboard-oriented gesture controls.
- Refined the capture, clipboard, tiling and settings sections.
- Preserved document scrolling while reducing unnecessary visual chrome.

## 1.1.5 — System actions and annotation
- Improved system appearance, Focus and lock-screen actions, plus named-trigger deep links.
- Enhanced annotation controls, previews and interaction behavior.
- Refined local clipboard, screenshot and automation workflows.

## 1.1.4 — Trigger organization
- Expanded trigger and action catalogs, workflow variables and activation controls.
- Improved gesture organization, pause settings and global configuration.
- Published a verified development source snapshot.

## 1.1.3 — Local intelligence and integrations
- Expanded local clipboard intelligence, permission-scoped automation interfaces and responsive interactions.
- Refined capture, annotation and on-device text extraction.
- The supplied build record noted one failing codec-resource test; no clean-test claim is made here.

## 1.1.2 — Interaction refinements
- Improved clipboard selection, editing and preview interactions.
- Refined screenshot quick access and annotation interfaces.
- The supplied build record noted one codec-resource test failure.

## 1.1.1 — Clipboard selection fixes
- Made single-click card selection immediate and improved keyboard focus handoff.
- Consolidated multi-item text copying and corrected clipboard-stack ordering after deletion.
- Polished capture-history card interaction and related settings.

## 1.1.0 — Expanded local creative workflows
- Added scrolling capture sessions, OCR-enabled clipboard search, encrypted clipboard history and richer recording controls.
- Expanded annotations, editable projects, export formats and Finder integration.
- Included pause/recovery controls for recording and capture workflows.

## 1.0.14 — Preview and keyboard interaction
- Improved clipboard previews, keyboard shortcuts, selection after deletion and focus restoration.
- Refined capture preview controls, annotation manipulation and undo/redo.

## 1.0.13 — Preview and scrolling polish
- Refined the clipboard-preview and scrolling experience in the archived development build.

## 1.0.12 — Clipboard and capture editing
- Improved clipboard cards, searching, selection and interaction feedback.
- Expanded screenshot annotation, mosaic/blur, resizing, pinning and export controls.

## 1.0.11 — Development build
- Archived an AOM development artifact. Consult its release page for build and signing details; no additional functional changes are asserted here.

## 1.0.10 — History performance
- Made clipboard-card selection immediate and reduced forced scrolling.
- Generated image previews and metadata in the background.
- Reorganized capture history into a compact horizontal panel.

## 1.0.9 — Clipboard and capture UI
- Expanded clipboard search, filters, multi-selection and ordered copy workflows.
- Refined capture annotation, preview controls and quick actions.

## 1.0.7 — Annotation improvements
- Refined the contextual annotation toolbar and screenshot combining.
- Added reversible image merging and associated undo/redo restoration.

## 1.0.2–1.0.6 — Early development archives
- Preserved early local development artifacts with separate build identifiers, signing metadata and checksums.
- See their individual release pages for verified provenance; no additional feature or test claims are made here.

---

**Distribution notice:** These are private development builds. Self-signed or ad-hoc signatures are not Apple Developer ID notarization. Changes listed above describe documented implementation work, not guaranteed compatibility with every application, device or macOS release. Cloud synchronization and other excluded integrations are not represented as delivered features.
