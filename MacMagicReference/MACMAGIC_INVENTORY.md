# MacMagic 2.0 Reverse Engineering & Porting Inventory

- Target Bundle: `com.koingosw.MacMagic` (v2.0, SKU: MacMagic)
- Extracted Date: 2026-10-25
- Location in Repo: `MacMagicReference/`

---

## 1. Feature Catalog & Implementation Mechanics

MacMagic is a comprehensive collection of macOS system maintenance, file attribute, Finder, and network tools:

| Feature Identifier | Description | Native Implementation / Shell Command |
|---|---|---|
| `togglehiddenfiles` | Show / Hide hidden files in Finder | `defaults write com.apple.finder AppleShowAllFiles -bool <true/false>; killall Finder` |
| `togglededesktopicons` | Show / Hide all icons on Desktop | `defaults write com.apple.finder CreateDesktop -bool <true/false>; killall Finder` |
| `resetdnscache` | Flush DNS cache & refresh mDNS | `dscacheutil -flushcache; killall -HUP mDNSResponder` |
| `restartfinder` | Clean restart of Finder process | `killall Finder` |
| `erasedsstore` | Recursively erase `.DS_Store` files | Traverses specified folder, removes all `.DS_Store` items |
| `fileinuse` | Identify processes locking a file | Executes `/usr/sbin/lsof` with the file path to inspect open file descriptors |
| `lockfiles` / `unlockfiles` | Set / Clear system immutable flag | `/usr/bin/chflags uchg <path>` / `/usr/bin/chflags nouchg <path>` |
| `makeinvisible` / `makevisible` | Toggle file hidden BSD flag | `/usr/bin/chflags hidden <path>` / `/usr/bin/chflags nohidden <path>` |
| `forcedelete` | Force delete locked or stubborn files | Unlinks with permission override |
| `forceemptytrash` | Force empty user Trash | Clears `~/.Trash` avoiding locked-file prompts |
| `disconnectwifi` | Turn off / cycle Wi-Fi interface | `networksetup -setairportpower en0 off` or CoreWLAN framework |

---

## 2. AOM Architecture Integration

AOM can integrate these capabilities natively without relying on external helpers:
- File flag modifications via Darwin `chflags()` system call (zero process overhead).
- Finder preferences via `UserDefaults(suiteName: "com.apple.finder")`.
- Process lock inspection via `lsof` or POSIX file descriptor probes.
- Exposing these actions to AOM's `ActionType`, Command Palette, and `AutomationMCP`.
