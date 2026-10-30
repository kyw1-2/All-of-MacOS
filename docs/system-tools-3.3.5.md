# AOM 3.3.5 System Tools

The page went from 12 tools in 3 groups to **69 tools in 9 groups** (57 new), plus a live status strip,
Favorites, Recent and a last-result line.

The Workspace tile reads `SystemToolsInventory.count` (69, derived from `SystemToolCatalog`, so it can't drift)
and `SystemToolsInventory.subtitle` ("Toggles, cleanup, dev and more").

## Benchmark

Sources checked on 2026-10-30. Content was rephrased for compliance with licensing restrictions.

| App | Feature | AOM 3.3.5 | Why |
|---|---|---|---|
| One Switch ([fireball.studio/oneswitch](https://fireball.studio/oneswitch)) | Hide desktop icons | Adopted (state pill) | existed; now shows On/Off |
| One Switch | Dark Mode toggle | Adopted | reuses action `toggleDarkMode` (System Events) |
| One Switch | Keep Awake with durations | Adopted | reuses `KeepAwakeService`; menu 15 min … 8 h / until off, Mac-only or Mac + display |
| One Switch | Screen Saver | Adopted | action `startScreenSaver` |
| One Switch | Connect AirPods / Bluetooth headphones | Adopted | action `bluetoothDevice` (IOBluetooth, paired devices menu) |
| One Switch | Hidden files | Adopted (state pill) | existed |
| One Switch / KeyboardCleanTool ([switchingtomac.com](https://www.switchingtomac.com/lock-mac-keyboard-and-trackpad-for-cleaning/)) | Keyboard lock for cleaning | Adopted | session event tap (Accessibility), 30 s / 1 / 2 min, pointer unlocks, always ends by itself |
| One Switch | Do Not Disturb / Focus | Partial | macOS has no public Focus API; runs the user's "Toggle Focus" shortcut (existing action); tile says the state can't be read |
| One Switch | Night Shift | Skipped | needs private CoreBrightness |
| One Switch | Screen resolution | Skipped here | already in AOM's display controls (`DisplayControlService`); not duplicated |
| Raycast System Commands ([manual.raycast.com/system-commands](https://manual.raycast.com/system-commands)) | Lock Screen, Sleep, Sleep Displays, Log Out | Adopted | existing actions |
| Raycast | Restart, Shut Down | Adopted | AOM confirm, then System Events `restart` / `shut down` (apps can still ask to save) |
| Raycast | Quit All Apps (confirm, Finder excluded) | Adopted | `NSRunningApplication.terminate`, reports apps still open after 4 s |
| Raycast | Hide All Apps Except Frontmost | Adopted | action `hideOtherApps` |
| Raycast | Eject All Disks, Empty Trash, Toggle Hidden Files, Toggle Mute, Toggle Mic Mute, Toggle Wi-Fi | Adopted | existing actions / service |
| Raycast | Toggle Bluetooth power, Airplane Mode, Camera mute, Hibernate | Skipped | private frameworks / admin pmset / no public API |
| OnyX ([titanium-software.fr](https://titanium-software.fr/en/), [softpedia](https://mac.softpedia.com/get/System-Utilities/OnyX.shtml)) | Rebuild Launch Services | Adopted | `lsregister -r -f -apps system,local,user` then `-gc` (`-kill` no longer exists on 27.2; checked `lsregister -h`) |
| OnyX | Reindex Spotlight | Adopted (admin) | `mdutil -E /` via the administrator prompt |
| OnyX | Font caches | Adopted (user part) | `atsutil databases -removeUser` (the system part needs root; `atsutil server` verbs are gone on 27.2) |
| OnyX | Restart Dock / SystemUIServer / Control Center | Adopted | `killall Dock`, `killall SystemUIServer ControlCenter` (user processes, relaunch by themselves) |
| OnyX | Purge memory | Adopted (admin) | `/usr/sbin/purge`; wording says it empties the disk cache, not app memory |
| OnyX | Periodic scripts, verify disk, rebuild mail | Skipped | periodic is deprecated; disk verify is Disk Utility's; Mail is out of scope |
| TinkerTool ([bresink.com](https://www.bresink.com/osx/TinkerTool.html)) | Finder: show all extensions, path bar, status bar, full path in title | Adopted (state pills) | user-domain preferences only, like TinkerTool; Finder restarts |
| TinkerTool | Dock: only open apps, no auto-hide delay, recent apps | Adopted (state pills) | `static-only`, `autohide-delay`, `show-recents`; Dock restarts |
| TinkerTool | Screenshot format, location, window shadow | Adopted (current value shown) | `com.apple.screencapture type/location/disable-shadow`; applies to the next screenshot |
| Stats ([github.com/exelban/stats](https://github.com/exelban/stats)) / iStat Menus | CPU, memory, disk, battery, network | Adopted as a status strip | host_statistics, vm stats + pressure sysctl, volume capacity, IOKit AppleSmartBattery (charge, health, cycles), uptime from kern.boottime, thermal state, local IPv4 |
| Stats | Fans, sensors (SMC) | Skipped | needs SMC access / privileged helper |
| AppCleaner / Pearcleaner ([github.com/alienator88/Pearcleaner](https://github.com/alienator88/pearcleaner), [pearcleaner.com](https://www.pearcleaner.com/)) | Uninstall with leftovers | Adopted | preview list with checkboxes and sizes; only `FileManager.trashItem` (Put Back works); refuses Apple apps, AOM and running apps |
| Pearcleaner | Orphan finder, Sentinel auto-clean, lipo | Skipped | orphan matching is guesswork without the app present; background deletion conflicts with "preview first" |
| CleanMyMac-style cleaners ([MacCleaner](https://github.com/dheerajbatra/MacCleaner)) | Large files, old Downloads, Xcode junk | Adopted | preview first, Trash only; Xcode Archives are never listed |
| DevUtils ([devutils.com/docs](https://devutils.com/docs/)) | JSON format/minify, Base64, URL encode, UUID, Unix time, hash | Adopted | on the clipboard text; pure functions in `DevTextTools` |
| Boop ([github.com/IvanMathy/Boop](https://github.com/ivanmathy/Boop)) | Case changes, trim, sort, dedupe, word count, strip formatting | Adopted | reuses AOM's `TextTransform` plus `DevTextTools.stats` |
| Raycast / DevUtils | Colour picker → hex | Adopted | action `pickScreenColor` (NSColorSampler) |
| DevUtils | JWT, regex tester, diff | Skipped | need a text editor surface; not one-click tools |
| macOS `networkQuality` | Speed test | Adopted | `networkQuality -c -M 20`, JSON parsed (keys verified on this Mac) |
| `lsof` | What is using port N, what has a file open | Adopted | `lsof -nP -i :N -F pcPnT` and the existing `findProcessesLockingFile`; Quit sends SIGTERM after a confirm |
| Battery charge limit (AlDente) | Charge limit | Skipped | SMC write / privileged helper |

## Tools by group (69)

Legend: **T** toggle with live state pill · **C** confirms first · **A** administrator prompt · **P** preview list
before Trash · **⟳** long job (spinner, can't double-run).

### Quick Toggles (11)
| Tool | Runs |
|---|---|
| Dark Mode T | action `toggleDarkMode` (System Events); state `AppleInterfaceStyle` |
| Keep Awake T | `KeepAwakeService.start/stop` (power assertion); durations menu; state "Until hh:mm" |
| Hidden Files T | `MacMagicSystemToolService.toggleHiddenFiles` (AppleShowAllFiles + Finder restart) |
| Desktop Icons T | `toggleDesktopIcons` (CreateDesktop + Finder restart) |
| Dock Auto-Hide T | action `toggleDockAutoHide` (System Events); state `com.apple.dock autohide` |
| Wi-Fi T | action `setWiFiPower` toggle (CoreWLAN); state `CWInterface.powerOn()` |
| Mute Sound T | action `muteVolume`; state `AudioOutputService.isOutputMuted()` |
| Mute Microphone T | action `toggleMuteMicrophone`; state `isInputMuted()` |
| Bluetooth Device | menu of paired devices → action `bluetoothDevice` connect/disconnect (state not polled, so no Bluetooth prompt on page open) |
| Focus | action `toggleDoNotDisturb` (user's "Toggle Focus" shortcut); no state, said in tooltip |
| Lock Keyboard T | `KeyboardCleaningLock` (CGEventTap on key/flags/NX_SYSDEFINED, 10–120 s, panel with Done Cleaning) |

### Power & Session (10)
Lock Screen (`lockScreen`), Sleep (`sleepComputer`), Sleep Displays (`sleepDisplay`), Screen Saver (`startScreenSaver`),
Restart… C (`osascript -e 'tell application "System Events" to restart'`), Shut Down… C (`… to shut down`),
Log Out… C (action `logOut`, which confirms), Quit All Apps… C (terminate regular apps except Finder/AOM, reports
leftovers), Hide Other Apps (`hideOtherApps`), Eject All Disks (`ejectAllDisks`).

### Finder & Dock (9)
Restart Finder (existing), File Extensions T (`NSGlobalDomain AppleShowAllExtensions`), Path Bar T (`ShowPathbar`),
Status Bar T (`ShowStatusBar`), Full Path in Title T (`_FXShowPosixPathInTitle`), Open Apps Only T
(`static-only`), Instant Dock T (`autohide-delay` 0 / key removed), Dock Recents T (`show-recents`, default on),
Restart Dock ⟳ (`killall Dock`). Writes go through `CFPreferencesSetAppValue` + synchronize; failure is reported.

### Screenshots (3)
Window Shadows T (`disable-shadow`, inverted), File Format (menu PNG/JPG/HEIC/PDF/TIFF, current value pill),
Save Folder (folder panel, current folder pill).

### Maintenance (5)
Restart Menu Bar ⟳ (`killall SystemUIServer ControlCenter`), Rebuild Open With C ⟳ (`lsregister -r -f -apps
system,local,user`, then `lsregister -gc`), Reindex Spotlight C A (`mdutil -E /`), Clear Font Caches ⟳
(`atsutil databases -removeUser`), Purge Disk Cache C A (`purge`).

### Cleanup (7)
Clear Caches C (existing engine; now asks first), Erase .DS_Store (existing), Empty Trash C (existing),
Uninstall App… P ⟳ (app + `~/Library` leftovers matched by bundle ID at dot boundaries, app name only in
Application Support/Caches/Logs), Large Files… P ⟳ (100 MB / 500 MB / 1 GB / 5 GB in a chosen folder, skips
~/Library, hidden items and package contents), Old Downloads… P ⟳ (30/90/180/365 days since added, changed or
opened), Xcode Junk… P ⟳ (DerivedData, simulator caches, device support, Xcode caches; never Archives).

### Files, PDF & Media (10)
Merge PDFs, Compress PDF ⟳, Convert Image, Convert Video ⟳, QR Code (existing), Batch Rename (existing
`batchRename`, find/replace with `{n}`), Lock Files (`setFileLocked`, uchg), Hide Files (`setFileHidden`), What's
Using a File (`findProcessesLockingFile` → list with Quit…), File SHA-256 ⟳ (CryptoKit, 1 MB chunks; if the
clipboard holds a SHA-256 it is compared instead of overwritten).

### Text & Developer (10) — all on the clipboard text
Format JSON (pretty with sorted keys / minify), Base64 (encode / lenient decode), URL Encode (encode / decode),
Change Case (UPPER, lower, Title, Sentence, camel, snake, kebab), Clean Up Text (plain text, trim, collapse spaces,
join lines, sort, reverse, remove duplicates), Count Words (characters, words, lines, bytes), New UUID, Unix Time
(clipboard 9–11 digits = seconds, 12–14 = ms → ISO 8601 copied; otherwise current Unix time), Pick Color
(`pickScreenColor`), Hash Text (SHA-256).

### Network (4)
Flush DNS (existing, admin fallback), Speed Test ⟳ (`networkQuality -c -M 20`), What's Using a Port (`lsof -nP -i
:N -F pcPnT` → list with Quit…), Copy IP Address (getifaddrs, en* first, link-local skipped).

## Page
Status strip (CPU, memory + pressure, disk free, battery % + health + cycles, uptime, thermal, local IP; 2 s
refresh while visible) → Favorites (right-click a tile › Add to Favorites; `AOMSystemToolsFavorites`) and Recent
(`AOMSystemToolsRecent`, 6 newest) → one card with the 9 groups. Header subtitle is the last result
("✓ Speed Test: ↓ 147 Mbps … · 21:40"). Toggle pills refresh on appear, every 4 s, and 0.6 s / 2 s after a run.
Tooltips (`.help`) carry each tool's one-line description. Toolbar keeps All Actions and Floating Menus & Widgets.

## Files
- `AllOfMacOS/Services/SystemTools/SystemToolsCommand.swift` — Process runner (both streams), admin script, session, killall
- `AllOfMacOS/Services/SystemTools/SystemToolsText.swift` — `DevTextTools`
- `AllOfMacOS/Services/SystemTools/SystemToolsTweaks.swift` — `SystemTweak`, `CFPreferenceStore`, `MemoryPreferenceStore`
- `AllOfMacOS/Services/SystemTools/SystemToolsStatus.swift` — `SystemStatus`, `SystemStatusMonitor`
- `AllOfMacOS/Services/SystemTools/SystemToolsNetwork.swift` — `NetworkTools` (lsof, networkQuality)
- `AllOfMacOS/Services/SystemTools/SystemToolsCleanup.swift` — `CleanupTools` (uninstaller, scans, Trash)
- `AllOfMacOS/Services/SystemTools/KeyboardCleaningLock.swift`
- `AllOfMacOS/Views/SystemToolsCatalog.swift`, `SystemToolsModel.swift`, `SystemToolsTiles.swift`, `SystemToolsView.swift`, `SystemToolsInventory.swift`
- `AllOfMacOS/Services/MacMagic/MacMagicSystemToolService.swift` — two `SystemToolError` cases added
- `AllOfMacOSTests/SystemTools335Tests.swift`

## Verification
- Tests: `AllOfMacOSTests/SystemTools335Tests.swift`, 29 tests, 0 failures (`aom-335-kit/tools-tests-2.log`). They
  use an in-memory preference store, a temp folder and a fake Trash; no real defaults, killall or Trash moves.
  No existing test asserted the old count, so none had to change.
- Screenshots (preview tag `tools`, 1320×820): `shots/tools/T-light-v4-0.png`, `T-dark-v4-0.png` (top),
  `T-light-favorites-0.png` (Favorites + Recent seeded through launch arguments of the preview's own domain),
  `T-light-bottom-0.png`, `T-dark-bottom2-0.png` (bottom). Fixed after looking: three truncated titles
  (renamed to Open Apps Only, File Format, Save Folder) and the battery cell (health/cycles were missing because
  macOS 27.2 keeps the mAh figures inside `BatteryData`; the parser now reads the nested dictionary).
- Read-only checks run on this Mac: `lsof -F pcPnT` field order, `networkQuality -c` JSON keys (full and `-u`),
  `ioreg AppleSmartBattery` keys, `lsregister -h`, `atsutil databases` usage, `kern.memorystatus_vm_pressure_level`.
- Not exercised (they change the real system, so they were not clicked in the preview): every toggle and
  power/maintenance/cleanup action, the administrator prompts, the keyboard lock's event tap, Bluetooth, the
  uninstaller's Trash move. Their engines are covered by the pure tests above; the action-backed tools reuse
  existing AOM actions.
