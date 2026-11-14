# System Tools in 3.5.0

3.5.0 cuts the System Tools page from 127 tiles to 62 tools in nine sections. It also moves the file tools to the Files page.

## Page map

| Order | Section | What is in it |
|---|---|---|
| 1 | This Mac | Live strip: battery, startup disk, memory, network and uptime. Each item opens its detail sheet. |
| 2 | Favorites | Tools you pinned with a right-click. |
| 3 | Quick Toggles | Dark Mode, Keep Awake, Hide Menu Bar, Dock Auto-Hide, Hidden Files, Desktop Icons, Wi-Fi, Bluetooth Device, Low Power Mode, Lock Keyboard. |
| 4 | Display | Resolution, Brightness, Metal HUD. |
| 5 | Power & Session | Lock Screen, Sleep, Sleep Displays, Sleep Timer, Awake While App Runs, Battery Details, Restart, Shut Down, Log Out, Quit All Apps. |
| 6 | Apps | Activity (top CPU and memory, with quit), Force Quit, Relaunch, Uninstall, Login Items, What's Keeping Awake, Reset Window State. |
| 7 | Storage | Free Up Space (cache, Trash, large files, old downloads, developer junk, duplicates, folder sizes), Eject, Time Machine, Local Snapshots, Verify Startup Disk, Install Disk Image. |
| 8 | Network | Network Info (IP, public IP, Wi-Fi, DNS), Speed Test, Ping, Ports, VPN (Tailscale and OpenVPN), Flush DNS, Renew DHCP. |
| 9 | Homebrew | One tile that opens the Homebrew sheet. It appears only when Homebrew is installed. |
| 10 | Fix It | Restart Finder, Dock or Menu Bar, Rebuild Open With, Reindex Spotlight, Clear Font Caches. |
| 11 | Tweaks | Finder, Dock, screenshot and startup-sound preferences, shown as rows. |
| — | Battery & Hardware | Charging limit, fan presets and SMC sensors. Not shown while you search. |

## Merged ids

Saved favorites, automations and MCP calls that use an old id still work. `SystemToolMigration.map` maps each old id to its new tool.

| Old ids | Now |
|---|---|
| `topCPU`, `topMemory` | `activity` |
| `ejectAll`, `ejectDisk` | `eject` |
| `backupNow`, `backupStatus` | `timeMachine` |
| `portLookup`, `listeningPorts` | `ports` |
| `copyIP`, `publicIP`, `wifiDetails`, `dnsServers` | `networkInfo` |
| `brewOutdated`, `brewUpgradeAll`, `brewInstalled`, `brewUpdate`, `brewCleanup`, `brewDoctor`, `brewServices`, `brewSearch` | `homebrew` |
| `cache`, `trash`, `largeFiles`, `oldDownloads`, `devJunk`, `duplicates`, `folderSizes` | `freeUpSpace` |
| `tailscale`, `openVPN` | `vpn` |

## Moved to the Files page (Tools menu)

PDF: merge, compress, split, extract, remove pages, rotate, reorder, images to PDF, PDF to images, protect, unlock, page numbers. Media: image and video conversion, QR code. Files: rename, who locks a file, file hash.

## Removed

- **Duplicates of the Sound page:** mute sound or mic, alert volume, output or input device, volume.
- **Already one click away in macOS:** Reduce Transparency, Reduce Motion, screen saver, Hide Others, About This Mac, copy serial number, settings panes, AirDrop and Bluetooth settings, boot reasons.
- **Dropped features:** Focus, wallpaper, `.DS_Store` cleanup, lock and hide files, copy Finder path, new text file, Terminal here, free memory, weather.

`SystemToolMigration.removed` lists these ids. A favorite that uses one of them no longer appears.

## Automation

- The Automation page lists automations by name only. There are no counts, banners or info buttons.
- The ⋯ menu holds Floating Menus & Widgets… and Browse Actions….
- Browse Actions replaces both All Actions and the Add Action sheet.
