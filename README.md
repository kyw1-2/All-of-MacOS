# All of MacOS

All of MacOS (AOM) is a native macOS productivity application for gestures, keyboard shortcuts, window management, clipboard history, screen capture, recording, and local automation.

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
