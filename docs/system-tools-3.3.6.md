# AOM 3.3.6 — System Tools

Branch `tools/336`. The page goes from 69 tools in 9 groups to **104 tools in 13 groups**: the 10 Text & Developer
tools are removed and 45 system tools are added. The page is redesigned to the 3.3.6 design spec
(`docs/design-3.3.6.md`, UI-A).

Workspace tile: `SystemToolsInventory.count` is **104** (derived from `SystemToolCatalog`), and
`SystemToolsInventory.subtitle` is **"Toggles, power and disk"** (23 characters; "…disk and more" was cut off in
the 1320 pt Workspace tile, checked in `shots/t6/v3-W-light.png`).

## Removed

Text & Developer (all clipboard tools): Format JSON, Base64, URL Encode, Change Case, Clean Up Text, Count Words,
New UUID, Unix Time, Pick Color, Hash Text. `SystemToolsText.swift` (`DevTextTools`) is deleted. File SHA-256 stays
(Files group); its streaming hasher and clipboard-hash check moved to `FileTools`. `TextTransform` and the
`pickScreenColor` action are untouched (other pages use them).

Saved favorites and recents that name a removed tool: `SystemToolsModel.storedTools` drops unknown ids and
duplicates, and the model rewrites `AOMSystemToolsFavorites` / `AOMSystemToolsRecent` once without them. No alert,
no crash (tested with the 10 removed ids).

## Benchmark

Sources checked on 30 Oct 2026. Content was rephrased for compliance with licensing restrictions.

| App | Feature | AOM 3.3.6 | Why |
|---|---|---|---|
| One Switch ([fireball.studio/oneswitch](https://fireball.studio/oneswitch), [onmymenubar.app](https://onmymenubar.app/one-switch/)) | Resolution switching, keep awake, toggles | Adopted: Resolution (with refresh rate), Low Power Mode, Hide Menu Bar | resolution reuses `DisplayControlService` |
| One Switch | Night Shift | Skipped | private CoreBrightness |
| Raycast System Commands ([manual.raycast.com/system-commands](https://manual.raycast.com/system-commands)) | System toggles and commands | Adopted: Force Quit App, Relaunch App, Open Settings Pane | public AppKit / URL scheme |
| Raycast Sleep Timer extension ([raycast.com/dtmzr/sleep-timer](https://www.raycast.com/dtmzr/sleep-timer)) | Sleep in N minutes | Adopted: Sleep Timer (15 min–2 h) | in-app timer, then `pmset sleepnow`; fires only while AOM runs (tooltip says so) |
| Raycast Power Management extension ([raycast.com/sasivarnan/power-management](https://www.raycast.com/sasivarnan/power-management)) | pmset settings need an administrator | Adopted: Low Power Mode via the administrator prompt | same admin pattern as Flush DNS |
| Raycast Kill Process ([raycast.com/rolandleth/kill-process](https://www.raycast.com/rolandleth/kill-process)) | Process list with kill | Adopted: Top CPU, Top Memory (`ps`), with Quit (SIGTERM, confirms) | |
| Amphetamine / Lungo ([App Store](https://apps.apple.com/us/app/lungo/id1263070803)) | Keep awake; "while app runs" trigger | Adopted: Awake While App Runs; Keep Awake (3.3.5) | one IOPM assertion released when the app quits |
| `pmset -g assertions` (Amphetamine-style diagnostics) | What prevents sleep | Adopted: What's Keeping Awake | parser keeps sleep-preventing types only |
| coconutBattery ([coconutbattery.net](https://www.coconutbattery.net/)) | Design vs full-charge capacity, cycles, temperature | Adopted: Battery Details | IOKit AppleSmartBattery (BatteryData on 27.2) + `system_profiler SPPowerDataType -json` condition |
| AlDente ([apphousekitchen.com](https://apphousekitchen.com/)) | Charge limit, sailing, discharge | Skipped | SMC writes / privileged helper |
| Stats ([github.com/exelban/stats](https://github.com/exelban/stats)) / iStat Menus ([App Store](https://apps.apple.com/de/app/istat-menus-7/id6499559693?mt=12)) | CPU, memory, disk, battery; public IP | Adopted: "This Mac" gauges per volume; Public IP on click | fans/SMC skipped |
| BetterDisplay ([github.com/waydabber/BetterDisplay](https://github.com/waydabber/BetterDisplay/)) / MonitorControl ([github](https://github.com/MonitorControl/MonitorControl)) | Resolution, refresh rate, brightness and software dim | Adopted: Resolution, Brightness | reuses `DisplayControlService` (DisplayServices where the panel allows, else gamma dim); DDC skipped |
| SoundSource ([rogueamoeba.com/soundsource](https://rogueamoeba.com/soundsource/)) | Output, input and alert devices and volumes | Adopted: Sound Output, Sound Input, Volume presets, Alert Volume | reuses `AudioOutputService`; per-app audio skipped |
| macOS Startup Sound (System Settings › Sound) | Startup chime | Adopted: Startup Sound (admin) | `nvram StartupMute=%01/%00`; state read with `nvram StartupMute` |
| Ice ([github.com/jordanbaird/Ice](https://github.com/jordanbaird/Ice)) / Bartender | Menu bar hiding | Partial: Hide Menu Bar (auto-hide the whole bar) | per-item hiding needs private window APIs |
| TinkerTool ([bresink.com](https://www.bresink.com/osx/TinkerToolSys8.html), [TidBITS](https://tidbits.com/2026/01/29/make-finder-window-columns-resize-to-fit-filenames/)) | Show Library folder | Adopted: Library Folder (T) | `chflags nohidden/hidden ~/Library` |
| OnyX ([titanium-software.fr](https://www.titanium-software.fr/en/applications.html)) | Verify the startup disk; snapshots | Adopted: Verify Startup Disk, Local Snapshots (Thin = admin) | `diskutil verifyVolume /`, `tmutil listlocalsnapshots /`, `tmutil thinlocalsnapshots / 20000000000 4` |
| Apple, Time Machine local snapshots ([support.apple.com/102154](https://support.apple.com/en-us/102154)) | Hourly local snapshots | Adopted in Local Snapshots wording | update snapshots are left to macOS |
| Time Machine (`tmutil`) | Back up now, status | Adopted: Back Up Now (state pill), Time Machine Status | `tmutil startbackup`, `status`, `destinationinfo`, `latestbackup` |
| Gemini 2 ([macpaw.com/gemini](https://macpaw.com/gemini)) | Duplicate finder | Adopted: Find Duplicates… | size first, then SHA-256; oldest copy unchecked; Trash only |
| DaisyDisk | Folder sizes | Adopted: Folder Sizes… (read-only list with Show in Finder) | no sunburst chart |
| Pearcleaner ([github](https://github.com/alienator88/Pearcleaner)) | App leftovers (3.3.5) | Extended: Reset Window State… (Saved Application State → Trash) | |
| Hand Mirror ([handmirror.app](https://handmirror.app/)) | Camera check | Skipped | camera preview is not a system tool, and AOM has no camera permission today |
| Finder services | Copy path, New file, Terminal here | Adopted: Copy Finder Path, New Text File Here, Terminal Here | Apple Events to Finder (Automation permission) |
| Wireless Diagnostics / iStat | Wi-Fi RSSI, noise, channel | Adopted: Wi-Fi Details | CoreWLAN; SSID only with Location permission (said in the alert) |
| macOS `ping`, `scutil --dns`, `lsof`, `ipconfig` | Latency, DNS, listeners, DHCP | Adopted: Ping, DNS Servers, Listening Ports, Renew DHCP (admin) | |
| Reduce Transparency / Reduce Motion | Toggle | Partial: state shown, click opens Accessibility settings | macOS gives apps read-only accessors; writing `com.apple.universalaccess` is protected |

## Tools by group (104)

Legend: **T** live state pill · **C** confirms first · **A** administrator prompt · **P** preview before Trash ·
**⟳** long job (spinner, can't double-run) · **new** added in 3.3.6.

### Quick Toggles (13) — Control Center tiles
Dark Mode T, Keep Awake T, Hidden Files T, Desktop Icons T, Dock Auto-Hide T, Wi-Fi T, Mute Sound T, Mute
Microphone T, Bluetooth Device, Focus, Lock Keyboard T (all 3.3.5), plus:
| Tool | Runs |
|---|---|
| Low Power Mode T A new | reads `pmset -g` for `lowpowermode` support, then `pmset -a lowpowermode 1/0` as admin; state `ProcessInfo.isLowPowerModeEnabled` |
| Hide Menu Bar T new | `osascript` System Events `dock preferences` › `autohide menu bar` true/false; state `_HIHideMenuBar` |

### Display & Sound (10, new)
| Tool | Runs |
|---|---|
| Resolution T | menu per display from `DisplayControlService.resolutionOptions`, Refresh Rate submenu; `setMode` then reads the mode back; pill = main display size |
| Brightness T | presets 10–100 % via `DisplayControlService.setBrightness` (hardware or gamma dim), Undo Software Dim |
| Wallpaper T | image panel → `NSWorkspace.setDesktopImageURL` on every screen; pill = current picture |
| Reduce Transparency T, Reduce Motion T | partial: `NSWorkspace.accessibilityDisplayShouldReduce…`; click opens Accessibility settings |
| Sound Output T | `AudioOutputService.devices()` menu, `select(name:uid:)` (verifies the default device) |
| Sound Input T | `inputDevices()` menu, `selectInput(uid:)`, then checks the default input |
| Volume T | presets 0–100 % via `AudioOutputService.setVolume` (read back) |
| Alert Volume T | `set volume alert volume N`; state `osascript … alert volume of (get volume settings)` |
| Startup Sound T A | `nvram StartupMute=%01` / `%00` as admin; state `nvram StartupMute` |

### Power & Session (9)
Lock Screen, Sleep, Sleep Displays, Screen Saver, Restart… C, Shut Down… C, Log Out… C, Quit All Apps… C, Hide Other
Apps (3.3.5). Eject All Disks moved to Disk & Storage.

### Battery & Energy (4, new)
| Tool | Runs |
|---|---|
| Battery Details ⟳ | IOKit AppleSmartBattery (charge, cycles of rated, mAh full/design/now, temperature from BatteryData, voltage) + `system_profiler SPPowerDataType -json` condition; alert with Copy and Battery Settings… |
| Sleep Timer T | 15 min – 2 h, Cancel; `SleepTimerService` → `pmset sleepnow`; partial: only while AOM runs |
| Awake While App Runs T | app menu → `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` released on the app's termination notification |
| What's Keeping Awake ⟳ | `pmset -g assertions` → list (process, kind, reason) with Quit… |

### Apps & Processes (6, new)
| Tool | Runs |
|---|---|
| Force Quit App… C | regular apps menu → confirm → `NSRunningApplication.forceTerminate`, checks it ended |
| Top CPU ⟳, Top Memory ⟳ | `ps -Aceo pid=,pcpu=,rss=,uid=,comm=` → top 15 with Quit… (SIGTERM; root/other users marked can't quit) |
| Relaunch App | `terminate`, waits up to 10 s, then `NSWorkspace.openApplication`; reopens nothing if the app stayed open |
| Login Items ⟳ | read-only: System Events login items, ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons; button opens Login Items settings; partial (SMAppService items are only in Settings) |
| Reset Window State… P ⟳ | `~/Library/Saved Application State/*.savedState` with app names and "open now" notes → Trash |

### Finder & Dock (13)
3.3.5's nine, plus: Library Folder T (`chflags nohidden|hidden ~/Library`, verified by `isHidden`), Copy Finder Path
(osascript: Finder selection → POSIX paths), New Text File Here (front Finder folder or Desktop → `untitled.txt`,
`untitled 2.txt` …, selected in Finder), Terminal Here (front Finder folder → `NSWorkspace.open` with Terminal).

### Screenshots (3)
Window Shadows T, File Format T, Save Folder T (3.3.5).

### Disk & Storage (6)
| Tool | Runs |
|---|---|
| Eject All Disks | existing action (moved) |
| Eject a Disk new | ejectable volumes with free/total → `NSWorkspace.unmountAndEjectDevice` |
| Verify Startup Disk C ⟳ new | `diskutil verifyVolume /` (read-only) → "appears to be OK" or the error line, First Aid hint |
| Back Up Now T new | `tmutil destinationinfo` (refuses without a backup disk), `tmutil startbackup`; pill from `tmutil status` |
| Time Machine Status new | `tmutil status`, `destinationinfo`, `latestbackup`; Time Machine Settings… |
| Local Snapshots new | `tmutil listlocalsnapshots /`; Thin Time Machine Snapshots… A (`tmutil thinlocalsnapshots / 20000000000 4`) only when TM snapshots exist |

### Maintenance (5), Cleanup (7)
Unchanged from 3.3.5.

### Files, PDF & Media (12)
3.3.5's ten, plus Find Duplicates… P ⟳ (100 KB / 1 MB / 10 MB minimum; size groups then SHA-256; oldest copy kept)
and Folder Sizes… ⟳ (allocated size per top-level item, read-only list, Show in Finder).

### Network (12)
3.3.5's four, plus Wi-Fi Details (CoreWLAN: interface, RSSI/noise/SNR, channel band/width, rate; SSID needs Location),
Public IP (one HTTPS GET to `https://api64.ipify.org`, literal IP check, copied), Ping (5 × `ping -c 5 -t 8 -q`,
host validated), DNS Servers (`scutil --dns`, copied), Renew DHCP A (`ipconfig set <if> DHCP`), Listening Ports (`lsof
-nP -iTCP -sTCP:LISTEN -F pcPnT`, with Quit…), AirDrop Settings, Bluetooth Settings (Settings URLs).

### System Info (4, new)
About This Mac ⟳ (`system_profiler SPHardwareDataType -json` name, `hw.model`, `machdep.cpu.brand_string`, memory,
version, `kern.osversion`), Copy Serial Number (IOPlatformExpertDevice), Last Restart & Wake (`kern.boottime`,
`kern.shutdownreason`, `kern.wakereason`, known tokens explained, raw codes shown), Open Settings Pane (25 panes).

Settings pane ids (`x-apple.systempreferences:<id>`) are the CFBundleIdentifiers of the Settings extensions in
`/System/Library/ExtensionKit/Extensions` on 27.2 (listed with PlistBuddy). Opening them was not clicked through,
because System Settings was already open with the user's window.

## Page (design-3.3.6)

Header (`AOMPageHeader`, 15 pt status) → **This Mac** gauges (Activity Monitor / Battery settings / Disk Utility
style): CPU, Memory (orange under pressure), one card per browsable volume (up to 3, orange under 10 % free),
Battery (health, cycles), a facts card (uptime, thermal, IP, macOS); 22 pt figures, 6 pt capacity bars → **Quick
Toggles** as Control Center tiles (32 pt round glyph filled with the accent while on, 13 pt bold name, 12 pt state) →
Favorites, Recent → one titled section per group (13 pt bold title + count, 24 pt apart) with 36 pt one-row tiles
(13 pt names, hover and press fills, state pills). No card inside a card; regular control size; tooltips carry the
descriptions and the "partial" notes.

## Verification

- Tests: `AllOfMacOSTests/SystemTools336Tests.swift` (new, 24 tests) and the edited
  `SystemTools335Tests.swift` (text cases removed, 23 tests): logs `aom-335-kit/tools336-tests-3.log` and
  `tools336-tests-4.log`. Command output is fed in as text; files live in a temp folder; no system state changes.
- Read-only checks on this Mac (27.2, MacBookAir10,1): `pmset -g`, `pmset -g batt`, `pmset -g assertions`, `tmutil
  status`, `tmutil destinationinfo` (no destination here), `tmutil listlocalsnapshots /`, `diskutil info -plist /`,
  `ps -Aceo …`, `scutil --dns`, `networksetup -listallhardwareports`, `ipconfig getsummary en0`, `lsof … LISTEN`,
  `ping -c 3 1.1.1.1`, `sysctl hw.model machdep.cpu.brand_string kern.osversion kern.shutdownreason kern.wakereason`,
  `ioreg AppleSmartBattery` (Temperature is inside BatteryData), `system_profiler SPPowerDataType/SPHardwareDataType
  -json`, `nvram StartupMute`, `ls -ldO ~/Library`, System Events sdef (`autohide menu bar` exists), Settings
  extension bundle ids.
- Not run (they change the system): every toggle, admin prompt, eject, Time Machine backup/thin, `diskutil
  verifyVolume /` (heavy), force quit/relaunch, DHCP renew, Public IP request, the Finder Apple Events.
