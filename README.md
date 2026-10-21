# All of MacOS

All of MacOS is a macOS productivity application with configurable gestures, keyboard actions, clipboard utilities, and screen capture.

## Version 1.5.0

The main window is rebuilt around a single navigation rail and one stable page header:
the split view, system toolbar and per-page titlebars are gone. The new home screen leads
with two large actions (capture, clipboard), a status chip, three metric cards and a
two-column activity layout.

## Version 1.4.0

Settings is now a single searchable surface: pinned search and category chips, one
scrolling card list, and every control applies immediately with a "저장됨" confirmation
instead of a separate apply step. Gestures, shortcut recording, permissions, backups and
clipboard storage open as sheets over the hub.

## Version 1.3.1

Capture visibility now applies to every AOM window: the annotation editor, recording export editor, expanded Quick Access preview and floating menus follow the same "Show in screen capture" switch as the clipboard surfaces. See [release notes](docs/1.3.1-release-notes.md).

## Version 1.3.0

Local feature expansion based on the retained Oracle REA/Ghidra audits of CleanShot X, BetterTouchTool and Paste. Adds editable recording layers and ordered cuts, click-based zoom, output presets, clipboard ordering and native multiple-file dragging, private opt-in link previews, floating menus/widgets, scoped local automation MCP/CLI, MIDI/GameController/explicit HID inputs, resilient file triggers, and native Finder thumbnail/share extensions. Cloud, Magic Mouse and Stream Deck are excluded.

See [release details and validation](docs/1.3.0-release-notes.md) and the complete [CleanShot](docs/1.3.0-cleanshot-coverage.md), [BTT](docs/1.3.0-btt-coverage.md) and [Paste](docs/1.3.0-paste-coverage.md) coverage records. These distinguish implemented features from proprietary interoperability and physical-device checks that remain unsupported or unverified.

## Version 1.2.8

Redesigned main window with native translucent navigation, a responsive action dashboard, consistent page headings and inset gesture editing. Removes unnecessary window-wide log updates and moves library search/copy work off the UI thread. Type Text automation now types individual characters with an adjustable interval and preserves the clipboard. See [design references, performance scope and validation](docs/1.2.8-release-notes.md).

## Version 1.2.7

Improves clipboard responsiveness: background pasteboard payload reads, asynchronous rich-text preparation/search/previews, focus handoff before direct paste, and content-versioned image caches. See [findings, Paste 2 reference and verification](docs/1.2.7-release-notes.md).

## Version 1.2.6

Fixes capture workflow completion, per-action OCR options and macOS paste-log persistence. Moves gesture-statistics encoding, coalesced preset saves and Quick Access image transforms off the UI thread, with revision checks to preserve newer edits. See [audit, release notes and validation](docs/1.2.6-release-notes.md).

## Version 1.2.5

Faster clipboard collection, targeted direct paste, asynchronous capture output, and ordered/cancellable capture automation. See [release notes and comparison](docs/1.2.5-release-notes.md). The repository contains an automated `swift test` suite under `AllOfMacOSTests` and a CI workflow (`.github/workflows/tests.yml`), but they were not run for this release's commits at the user's request: the 1.2.5 release was built without functional or regression verification.

## Version 1.2.2

Native main window (grouped Home, sortable gesture table with inspector), clean ⇧⌘V shelf with shortcut-conflict detection, and a sweep of functional fixes. See [release notes](docs/1.2.2-release-notes.md).

## Version 1.2.1

Apple-native redesign of every page, a responsive ⇧⌘V clipboard shelf, and instant Capture Text. See [release notes](docs/1.2.1-release-notes.md).

## Version 1.1.4

Adds trigger organization, pause controls, global gesture settings, workflow variables, and expanded trigger/action catalogs. See [release notes](docs/1.1.4-release-notes.md) and [BTT catalog comparison and remaining gaps](docs/1.1.4-btt-catalog-comparison.md).

## Features

- Trackpad, keyboard, window-management and automation controls
- Clipboard history, pinboards, configurable double-click paste/copy
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
