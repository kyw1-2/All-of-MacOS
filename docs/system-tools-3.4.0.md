# System Tools, microphone mute and the mixer in 3.4.0

What's new on the System Tools page, the microphone helpers on the Audio page, and the App Audio mixer panel.
Everything here starts with a click (or a setting you turn on); nothing polls in the background while you
aren't looking.

## System Tools page

The page now has 22 more tools (126 in all). The header counts only what this Mac can run: the Homebrew group
appears only when `brew` is installed, the Tailscale tile only with the Tailscale app, OpenVPN Connect only when it
is installed. On this MacBook Air that is 125 tools in 15 groups (OpenVPN Connect isn't installed).

Results show as a toast at the bottom of the window: green when something worked, orange for a note while
something runs, red with the reason when it didn't. The header's second line keeps the last result (hover it for
the whole text). The ⋯ button in the toolbar has Floating Menus & Widgets…, Homebrew…, VPN Connections… and
Show Weather….

### Homebrew (Raycast's Brew extension)

The Homebrew group (Outdated Packages, Upgrade All…, Installed Packages, Update Homebrew, Clean Up…, Brew Doctor,
Services, Search & Install…) opens one sheet with four tabs:

- **Outdated**: what has a newer version (`brew outdated --json=v2`, without updating Homebrew first, so it takes
  seconds). Each row shows "1.2.0 → 1.2.1" with Upgrade; Upgrade All… asks first and lists what will change.
  Pinned packages are marked and Upgrade All skips them.
- **Installed**: every formula and cask with its version and description; dependencies are dimmed. Uninstall…
  asks first.
- **Services**: `brew services` with their state and Start, Stop or Restart.
- **Search**: type a name, press Search; Install… asks first. Already installed results say so.

The header has Check Now, Update (`brew update`), Clean Up… (first measures what `brew cleanup -s` would free,
then asks with the size, then says how much it freed) and Doctor (`brew doctor`, with the number of warnings).

Only one brew job runs at a time. While it runs you see its name, the time so far and **Cancel**, and its live
output under the list (Copy Output copies it). Finished jobs are listed under Activity. A job that needs an
administrator password (some casks) says so: run that command in Terminal, where brew can ask for it.

AOM runs `/opt/homebrew/bin/brew` (or `/usr/local/bin/brew`) itself with `HOMEBREW_NO_AUTO_UPDATE=1` and its own
PATH, never through a shell, and with a time limit (3 hours for upgrades and installs, minutes for lists).

### VPN

- **VPN Connections…** lists the VPNs set up in System Settings › VPN with their live state, and connects or
  disconnects them (`scutil --nc start|stop`). The tile shows what is connected.
- **Tailscale** (when the Tailscale app is installed): its state, this Mac's Tailscale address, the exit node in use,
  Connect or Disconnect (`tailscale up` / `down`, which keep your saved settings) and Copy address. If Tailscale isn't
  logged in, AOM opens the Tailscale app to log in. macOS can report Tailscale's tunnel as connected while Tailscale
  itself is logged out; the VPN sheet says so on that row.
- **OpenVPN Connect** keeps its profiles to itself, so AOM can only open it (shown when it is installed).

### PDF tools (PDFgear's page tools)

The new PDF group: Merge PDFs and Compress PDF moved here, plus Split PDF…, Extract Pages…, Remove Pages…,
Rotate Pages…, Reorder Pages…, Images to PDF…, PDF to Images…, Add PDF Password…, Remove PDF Password… and
Add Page Numbers…. **Every tool saves a new file; the original PDF is never changed** and an existing file is
never overwritten.

Pages are typed the way viewers number them: `1-3, 5, 8-` (8 to the end), `-4` (1 to 4), `5-1` (backwards).

- Split: every page as its own PDF, or one PDF per range ("1-3, 4-6, 7-") into a folder you choose.
- Extract keeps the pages you type, in that order. Remove leaves them out. Rotate turns the pages you type (or
  all) 90° left, 90° right or 180°.
- Reorder: type the new order ("3, 1-2"); pages you leave out follow in their old order. A page typed twice is
  refused.
- Images to PDF: one page per image, in name order, at each image's own size or on A4 / US Letter pages (wide
  images get landscape pages). JPEGs go in unchanged; phone photos keep their orientation.
- PDF to Images: PNG or JPEG at 72, 150 or 300 dpi, one file per page, rotated pages upright.
- Add PDF Password asks for it twice; Remove PDF Password needs the password that opens the file. AOM never keeps
  either.
- Add Page Numbers: "1, 2, 3" or "Page 1 of 9", at the bottom centre, bottom right or top right. The numbers are
  added as text on top of each page, so links and forms keep working.

### Metal HUD

Display & Sound › **Metal HUD** shows Apple's Metal Performance HUD (frame rate, GPU time) in games and Metal apps.
It applies only to apps you open after turning it on (it sets `MTL_HUD_ENABLED` for your login session with
`launchctl setenv`); apps already open don't change, and it ends when you log out.

### Weather card (opt-in)

This Mac › **Show Weather** asks for a city and adds a weather card: now (temperature, conditions, feels-like,
humidity, wind) and the next three days. Data comes from Open-Meteo (open-meteo.com), which needs no key. AOM asks
for the forecast when the card is shown and every 30 minutes while the System Tools page shows it; nothing is
fetched while it is off or the page is closed. The ⋯ on the card has Refresh, Change Place… and Turn Off Weather.

### Uninstall App… (AppCleaner)

Moved to Apps & Processes. Choose an app or drop it on the tile. If the app is open, AOM asks to quit it the
normal way first. The review lists the app and what it left in ~/Library by folder (Application Support,
Caches, Preferences, Containers, Logs…). Files named with the app's bundle ID are checked; files that only share
the app's name are listed unchecked, because another app may own them. Return means Cancel here; Move to Trash is
the button you click. Everything goes to the Trash, so Finder's Put Back works. Apple's apps and AOM itself can't be
removed.

## Microphone mute (Audio page)

- **Shortcut**: Settings › Shortcuts › Productivity › Mute or Unmute Microphone (no default key). It mutes the
  default microphone in every app at once, like SoundSource's cough button, and works from any app.
- **HUD**: a small panel near the bottom of the screen says Microphone Muted or Microphone On for about a second.
  Turn it off with "Show a HUD when the microphone changes".
- **Menu bar icon**: "Show a menu bar icon while muted" adds a crossed-out microphone to the menu bar only while
  muted; its menu has Unmute Microphone.
- **Push to talk**: while muted, hold the chosen key (Right Option by default; also Right Command, Right Control,
  Right Shift or Fn) to talk; let go to mute again. AOM reads only whether that key is down, never what you type.
  It needs Accessibility, which AOM already has for gestures. Pause AOM stops push-to-talk from opening the
  microphone.
- **Mute when these apps open**: add Zoom, Teams or FaceTime; when one opens, the microphone is muted.
- The status menu has **Mute Microphone**, checked while muted. When the default microphone changes (AirPods
  connect) while muted, the new one is muted too. AOM never opens a microphone by itself.

Microphones without a mute switch are muted by setting their input volume to 0 (and restored after). One that has
neither can't be muted by any app; AOM says so instead of pretending.

## App Audio mixer panel (SoundSource-style)

- Applications are listed the way SoundSource lists them: favourites first, then apps playing now or in the last
  minute (an outlined meter when silent) and apps you adjusted; **Show All** lists every open app; **+** adds an app
  that isn't open so you can set it up first; the field filters by name.
- Each row: level meter, mute, volume, Magic Boost, the **output** it plays to (System Output follows the Mac; or a
  device of its own) and a chevron for its effects: Volume Overdrive up to 400 %, balance, Magic Boost preset,
  equalizer, Timed Mute, Favorite and Reset. Right-click has the same.
- AirPlay outputs can be chosen for one app only while **HomePod / AirPlay effects** is on (Output effects), because
  only then does AOM's buffered HomePod sender carry the app; otherwise those entries are dimmed.
- The output's own effects (HomePod / AirPlay effects, Magic Boost, equalizer, Headphone EQ, Audio Unit) are folded
  under **Output effects** so the applications get the room.
- If SoundSource is running, the panel says so and offers to quit it; two per-app mixers fight over the same audio.

What SoundSource 6 has that AOM's engine doesn't (so the panel doesn't offer it): output groups (one app to
several outputs), per-app Headphone EQ, pan, device max volume and channel settings, Quick Configs.

## Privacy and cost

Network: only Open-Meteo for the weather card (after you turn it on) and whatever brew itself fetches when you
click Update, Upgrade, Install or Check Now. Background cost: none while a feature is off. The push-to-talk key
monitor, the auto-mute launch observer and the microphone listeners exist only while their setting is on. The VPN
tiles read `scutil --nc list` (and Tailscale at most every 20 s) only while the System Tools page is on screen.
