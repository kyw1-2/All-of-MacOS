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
- Uses the local code-signing identity specified by `ALLOFMACOS_SIGN_ID`, which must be specified explicitly. Ad-hoc signing is reserved for CI builds.

## Build

On macOS with Xcode:

```bash
swift test
ALLOFMACOS_SIGN_ID="<authorized code signing identity>" ./build-and-sign.sh
codesign --verify --deep --strict "build/All of MacOS.app"
hdiutil create -volname "All of MacOS" -srcfolder "build/All of MacOS.app" -format UDZO "All-of-MacOS.dmg"
```

CI can use `ALLOFMACOS_SIGN_ID=-` to build an ad-hoc signed artifact for private testing only.

## Repository

Private repository: https://github.com/kyw1-2/All-of-MacOS . The independent source tree is tracked on `main`.

## Distribution

This repository is private. Distribution of any third-party code or bundled assets is subject to the necessary licenses and permissions.
