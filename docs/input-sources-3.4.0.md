# Per-app input sources (3.4.0)

AOM can pick the keyboard input source for each app, so Terminal always types in English and KakaoTalk in Korean,
and you stop typing a word in the wrong language and deleting it again (Input Source Pro-style).

## Turn it on

Settings › General › Input sources:

1. Turn on **Switch input sources by app**.
2. **Add App**: pick an open app, or **Choose App…** to pick one from Applications. Each app gets a row; choose its
   input source in the row's menu. Remove a row with its − button or its context menu.
3. Optional: **Remember in other apps** gives every app without a rule the input source it used last.
4. Optional: **Other apps** sets one input source for apps without a rule (or leave it as is).

The menus list the input sources turned on in System Settings › Keyboard › Text Input. A rule whose source was
turned off there shows "Not Enabled" and is skipped until the source is back.

## What it does and doesn't do

- It reacts only when an app comes to the front (no polling, no keyboard monitoring) and never reads what you type.
- A rule wins; then, with Remember on, the source that app used last; then the source for other apps.
- It does nothing in AOM's own windows, while AOM is paused (Pause AOM, everywhere or for that app), or while a
  password field has secure input on.
- If macOS switches back to a document's own source right after the app activates (Keyboard › "Automatically
  switch to a document's input source"), AOM checks once more 0.3 s later.

## Preferences

`AOMInputSourcesEnabled`, `AOMInputSourcesRules`, `AOMInputSourcesRemember`, `AOMInputSourcesFallback`,
`AOMInputSourcesMemory`, `AOMInputSourcesMemoryOrder` (at most 200 remembered apps, oldest dropped). Settings › Data ›
Reset Preferences clears them.

## Known limits

- At launch the switcher starts only after the integrator adds `AppInputSourcesModule.start()` to
  `AOMProductivityModules.start()`. Until then it starts when the switch is turned on in Settings.
- Not tested against a live Korean IME switch in this build (the policy and settings are unit-tested).
