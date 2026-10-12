# All of MacOS

All of MacOS is a macOS productivity application with configurable gestures, keyboard actions, clipboard utilities, and screen capture.

## Features

- Trackpad, keyboard, window-management and automation controls
- Clipboard history, pinboards, double-click copy
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
swift test
./build-and-sign.sh
codesign --verify --deep --strict "build/All of MacOS.app"
```

Create a local Keychain Access **Self Signed Root / Code Signing** identity named `AOM Dev` before a local release build. CI can use `ALLOFMACOS_SIGN_ID=-` to build an ad-hoc signed artifact for private testing only; it must never be confused with the local stable-signed DMG.

## Repository

Private repository: https://github.com/kyw1-2/All-of-MacOS . The independent source tree is tracked on `main`.

## Distribution

This repository is private. Distribution of any third-party code or bundled assets is subject to the necessary licenses and permissions.


## Private development DMG releases

All of MacOS uses the **local AOM Dev self-signed signing identity** for private development builds. This is not an Apple Developer ID or notarized distribution certificate. GitHub CI creates an **ad-hoc signed test artifact**; it does not publish that artifact as a stable AOM Dev release.

On the Mac, install and authenticate GitHub CLI (gh) once with access to this private repository, and pull the latest source from main. Every successful local build-and-sign.sh run using AOM Dev then:

1. Verifies the app signature and bundle identifier.
2. Creates a unique DMG under build/releases/.
3. Verifies the DMG and its mounted app/XPC signatures, computes SHA-256, and publishes it along with a `.sha256` checksum file as a GitHub **prerelease**.
4. On the first successful release, scans recognizable All of MacOS/AOM DMGs in Downloads, Desktop and the repository build directory. Each archive is validated before uploading, and originals are never modified. Failed imports can be retried.

To import previously created DMGs without rebuilding: bash scripts/publish-dmg.sh --import-existing

To publish one eligible DMG from elsewhere: bash scripts/publish-dmg.sh --file "/path/to/All-of-MacOS.dmg"

To build without a release, set ALLOFMACOS_SKIP_AUTO_RELEASE=1. If GitHub authentication or network access is unavailable, the local build stays intact and the upload failure is logged rather than being mistaken for a compilation failure. CI uses ALLOFMACOS_SIGN_ID=- and does not publish this development release channel.

**Important:** GitHub releases remain private while the repository is private. The self-signed certificate does not remove macOS Gatekeeper warnings or notarize the build. A tag identifies an archived binary by checksum; it does not assert that GitHub's current source reproduces that historical binary.
