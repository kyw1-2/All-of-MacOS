# All of MacOS

All of MacOS (AOM) is a native macOS productivity application for gestures, keyboard shortcuts, window management, clipboard history, screen capture, recording, and local automation.

## Version 2.2.0

The window itself is the redesign: the sidebar and toolbar now sit on a real behind-window
blur (your desktop shows through the chrome, the System Settings / Things arrangement) and
every page floats as an inset rounded card with a soft shadow. Reduce Transparency and
Increase Contrast fall back to the opaque window. The rhythm is compact — tighter rows
and page padding at the same readability — and filled buttons and shortcut key caps gained
a vertical accent gradient with a lit top edge. Glass stays on chrome and floating layers;
content you read remains opaque. Shortcuts, data formats and permissions are unchanged.

## Version 2.1.0

Readability and honest numbers on top of the 2.0.0 window. Selected list rows invert their
text (and key caps) like macOS expects, the palette's keyboard selection is clearly visible,
and empty-state buttons wrap instead of clipping in narrow columns. Every input type —
keyboard, mouse buttons, drawing, system triggers — now counts toward Insights and the
Workspace's last-run times, not just trackpad gestures. Clipboard chips and filled buttons
pick a readable label for any accent colour (including yellow, orange and cyan), the shelf's
empty state offers Resume / Open Settings, and the Paste Stack panel uses the standard empty
state. Settings rows regained their category-coloured icons, menus stop truncating long
labels, permissions show a live badge, and "shortcut" searches reach the clipboard shortcut
recorder. The Automation editor's trackpad preview is a third smaller. Shortcuts, data
formats and permissions are unchanged.

## Version 2.0.0

A redesign around the three things you do every day — find and edit an automation, find and
paste something you copied, capture and use it. The window now follows macOS structure: a
collapsible sidebar for navigation, each page's tools in its own toolbar, and content panes.
The Workspace puts problems (only when there are any), quick actions, pinned and recent
automations, recent captures and clipboard items first; the figures moved to Insights. The
Automation editor takes the width and reads Name · Applies to · Enabled, When, Do, Options.
The command palette has primary and secondary actions with their keys and avoids your own
shortcuts. Data formats, shortcuts and permissions are unchanged.

## Version 1.9.2

Password typing never reaches the lock screen. The lock screen turns on Secure Input too, so
AOM no longer registers its password-field shortcuts while the screen is locked, and Type Text
refuses to run (or stops) until you unlock.

After installing a new build, macOS asks once for your login keychain password: "All of
MacOS wants to access key 'All of MacOS Clipboard History'". AOM is signed with its own
certificate rather than an Apple Developer ID, so every build is a new identity to the
keychain. Choose Always Allow; clipboard history stays empty, but intact, until you do. A
Type Text shortcut works in that dialog like in any other password field (⌥P answers as ⌃⌥P).

## Version 1.9.1

Polish from checking 1.9.0 on a real setup: the Automation editor fits a 734 pt window
(pin, duplicate and delete moved into its ⋯ menu), capture thumbnails sit on the same quiet
grey as the rest of the sheet with captions that no longer truncate, and Insights' most-used
list uses the larger type scale.

## Version 1.9.0

A flat, unified redesign in the Apple and Toss manner. One neutral canvas, and each page is
one white sheet whose sections are divided by hairlines instead of a scatter of cards. The
Workspace fits on one screen: a summary strip across the top, your automations on the left,
this Mac's switches, health and quick actions on the right. Larger type (14 pt body, 26 pt
titles), one primary blue, and the Automation editor now lives inside the page sheet.

Type Text now works in macOS password dialogs. Synthetic keystrokes do reach them; what
failed was the shortcut: macOS withholds ⌥ and ⌥⇧ hot keys while a password field has focus.
AOM now also listens for the same shortcut with ⌃ added (⌥P becomes ⌃⌥P) only while Secure
Input is on, types with a private event source so no modifier stays latched, and no longer
round-trips the text through the pasteboard.

## Version 1.8.2

The window itself is opaque, so the top bar's material refracts the app surface instead of
the desktop wallpaper.

## Version 1.8.1

Opaque canvas under the ambient field, so window chrome stays calm over a colourful
wallpaper instead of picking it up.

## Version 1.8.0

Glass surfaces over an ambient gradient window, one language across the app (English),
and a real fix for text expansion in password fields: macOS Secure Event Input drops
synthetic keystrokes, so AOM now delivers through a concealed pasteboard round-trip.

## Version 1.7.0

Navigation moved from a left rail to one compact top bar with pill tabs, and the home
screen became a bento grid: a gradient hero, a live summary card, four quick actions,
three metrics and the activity groups below. Warm neutral palette, 22–26 pt corners,
softer borders and hover lift throughout.

## Version 1.6.0

- **1.6.0 — Unified design:** A consistent visual language with compact navigation, elevated cards, improved page hierarchy, and a streamlined dashboard.
- **1.5.0 — Navigation and Home:** A persistent navigation rail, shared page header, responsive workspace, and quick access to common actions.
- **1.4.0 — Settings:** A searchable, single-surface settings hub with instantly applied preferences.
- **1.3.1 — Capture visibility:** A unified visibility preference for AOM-managed windows during screen capture.
- **1.3.0 — Expanded local workflows:** More capable clipboard collections, editable recording workflows, floating controls, local automation inputs, and Finder integration.

**[Read the full English changelog](CHANGELOG.md)** for version-by-version changes. Individual [GitHub Releases](https://github.com/kyw1-2/All-of-MacOS/releases) retain their build numbers, source references, signing information, checksums, and verification limitations.

## Features

- Trackpad, keyboard, window-management and automation controls
- Clipboard history, pinboards, configurable double-click insertion and copying
- Screen capture, OCR, QR recognition, annotation, scrolling screenshots
- MP4 screen recording with optional audio, trimming and animated GIF export

## Identity

- App name: **All of MacOS**
- App identifier: `com.kyw.allofmacos`
- Helper identifier: `com.kyw.allofmacos.ScriptRunner`
- Separate Application Support folder: `AllOfMacOS`
- Output: `build/All of MacOS.app`
- Uses the local **self-signed Code Signing** identity `AOM Dev`. No paid Apple Developer membership is required for private local development. CI can request an ad-hoc build with `ALLOFMACOS_SIGN_ID=-`, which does not establish the same stable identity.

## Build

On macOS with Xcode:

```bash
brew list webp >/dev/null 2>&1 || brew install webp
swift test --scratch-path "$HOME/.cache/aom-build"
ALLOFMACOS_SCRATCH_PATH="$HOME/.cache/aom-build" ALLOFMACOS_SKIP_AUTO_RELEASE=1 ./build-and-sign.sh
codesign --verify --deep --strict "build/All of MacOS.app"
```

Create a local Keychain Access **Self Signed Root / Code Signing** identity named `AOM Dev` before a local release build. CI can use `ALLOFMACOS_SIGN_ID=-` to build an ad-hoc signed artifact for private testing only; it must never be confused with the local stable-signed DMG.

## Repository

Private repository: https://github.com/kyw1-2/All-of-MacOS . The independent source tree is tracked on `main`.

## Distribution

This repository is private. Distribution of any third-party code or bundled assets is subject to the necessary licenses and permissions.


## Private development DMG releases

**Headless build option:** GitHub Actions can now test, sign and publish a DMG from a trusted `main` push or Oracle dispatch, without leaving the MacBook on. One-time signing setup is required before activation. See [Oracle → GitHub Actions deployment guide](docs/oracle-actions-release.md). The existing local Mac build-and-sign workflow remains supported.

All of MacOS uses the **local AOM Dev self-signed signing identity** for private development builds. This is not an Apple Developer ID or notarized distribution certificate. GitHub CI creates an **ad-hoc signed test artifact**; it does not publish that artifact as a stable AOM Dev release.

On the Mac, install and authenticate GitHub CLI (gh) once with access to this private repository, and pull the latest source from main. Every successful local build-and-sign.sh run using AOM Dev then:

1. Verifies the app signature and bundle identifier.
2. Creates a unique DMG under build/releases/.
3. Verifies the DMG and its mounted app/XPC signatures, computes SHA-256 internally, and uploads **only the DMG**. Fresh local AOM Dev builds become GitHub **Latest** releases; older imported DMGs remain prereleases.
4. On the first successful release, scans recognizable All of MacOS/AOM DMGs in Downloads, Desktop and the repository build directory. Each archive is validated before uploading, and originals are never modified. Failed imports can be retried. Retired version **1.0.1** is excluded permanently from this import.

To import previously created DMGs without rebuilding: bash scripts/publish-dmg.sh --import-existing

To publish one eligible DMG from elsewhere: bash scripts/publish-dmg.sh --file "/path/to/All-of-MacOS.dmg"

To build without a release, set ALLOFMACOS_SKIP_AUTO_RELEASE=1. If GitHub authentication or network access is unavailable, the local build stays intact and the upload failure is logged rather than being mistaken for a compilation failure. CI uses ALLOFMACOS_SIGN_ID=- and does not publish this development release channel.

Standalone `.sha256` assets are not generated; a DMG digest remains in release metadata and GitHub also publishes its own asset digest for independent verification. Version 1.0.1 was intentionally removed from GitHub Releases.

**Important:** GitHub releases remain private while the repository is private. The self-signed certificate does not remove macOS Gatekeeper warnings or notarize the build. A tag identifies an archived binary by checksum; it does not assert that GitHub's current source reproduces that historical binary.

### 1.1.0 local workflows

See [the local workflow release notes](docs/1.1.0-local-workflows.md) for interactive scrolling, clipboard stack/OCR/encrypted storage, recording controls, editable annotation projects and Finder integration. WebP packaging requires an existing Homebrew `webp` installation (or `AOM_WEBP_ROOT`); the build bundles the codec and its license so installed apps do not need Homebrew. The signed build scripts also compile the annotation Quick Look extension.

## 1.1.1 clipboard interaction fixes

See [the interaction fixes and complete local feature inventory](docs/1.1.1-ui-and-feature-inventory.md) for implementation paths, remaining limits, and the UI inspection scope.
