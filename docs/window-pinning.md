# Live window pinning (Always on Top)

## Reference and implementation

Behavior was checked against [lihaoyun6/Topit](https://github.com/lihaoyun6/Topit),
revision `5c804cec25e2e2e172152f3a0ffe7b82a3313a56` (installed Topit: 0.1.5).
The relevant public sources are `Topit/ViewModel/OverlayView.swift`,
`OverlayViewOpacity.swift`, `SettingsView.swift`, `Topit/Supports/SCManager.swift`
and `Accessibility.swift`. The upstream repository declares AGPL-3.0.
AOM's implementation was written in its own service, model and AppKit views;
no Topit source files, assets, updater or dependencies are bundled. This is a
functional reimplementation, not a claim that AOM is an official Topit port.

## Entry points

- Window Tiling → Always on Top: Choose Window, Select on Screen, current pins and options.
- Menu bar → Automation → Always on Top: picker, selection, front-window toggle,
  each pin's menu, and Unpin All.
- Settings → Shortcuts → Always on Top: five configurable shortcuts, initially unassigned.
- Automation → Window Management: Choose Window to Pin, Select Window to Pin,
  Pin / Unpin Front Window, Pin / Unpin Window Under Cursor, Unpin All Windows.

Existing Bring Window to Front and screenshot-pin actions retain their meaning.

## Behavior

| Topit behavior | AOM implementation |
| --- | --- |
| Several live windows on top | One desktop-independent ScreenCaptureKit stream and floating panel per pin |
| Window selector | Searchable grid with window/app names and refreshed thumbnails |
| Point-and-select | Existing AOM window selection overlay; Escape cancels |
| Move, resize and interact | Activate the original Accessibility window; track its frame across displays |
| Hover / click / focus-preserving double click | Three activation modes; control panels never take keyboard focus |
| Per-pin unpin, pause, resume, close | Floating pin menu and management list; closing uses the source app's close button |
| Opacity | 20–100%; temporarily park the opaque source off screen and restore it for interaction |
| Overlap ducking | Other overlapping pins hide during interaction with a pinned window |
| Corner, refresh rate, translucent border | Per-user options, applied to existing pins |
| Application exclusion and untitled windows | Picker and toggle filtering; excluding a currently pinned app also unpins it |
| Launch, menu icon and Dock behavior | AOM's existing application settings |

Captured frames remain in memory; this feature does not record to disk or send
window contents elsewhere. Screen Recording and Accessibility are required.
Failures produce an actionable message instead of a permission retry loop.

## Lifecycle and recovery

Capture start, resize, stop and resume are serialized per pin. Unpinning during
an asynchronous start drains the late stream. Audio/cursor capture is disabled,
frame delivery is bounded by a three-frame queue and the display layer's readiness.
Source close/termination removes its pin. Hidden/minimized/fullscreen sources,
screen lock, sleep and Space transitions suspend their overlays. Paused pins
retain a control button. Unpin does not close the source window.

Translucency journals the source's original frame before moving it. Unpin,
pause, activation, stream failure and normal app termination restore the source.
After an interrupted run, recovery requires the same window ID, process ID,
bundle ID and application launch date; already-repositioned windows are left alone.
If Accessibility is unavailable, the recovery record remains for a later attempt.
An app that refuses off-screen placement falls back to an opaque pin with a message.

Public Accessibility does not provide a universal window ID. AOM requires an
unambiguous frame/title match within the owning process; coincident duplicate
windows that cannot be distinguished are rejected. Pin sessions are not restored
after relaunch. Only preferences and outstanding source-frame recovery records persist.

## Verification

`WindowPinningTests` covers filtering, coordinate conversion, capture limits,
preferences, action metadata and shortcut compatibility. `WindowPinCaptureLifecycleTests`
uses suspended fake streams to exercise unpin-during-start, resume-during-stop,
resize-during-start and start failure. The existing window, status-menu and
capture regression tests cover integration.

`WindowPinningRuntimeTests` is opt-in with `AOM_PIN_FIXTURE_PATH`: it accepts only
an executable inside a `com.kyw.aom.pinfixture` app, launches its own process and
operates exclusively on that process's disposable windows. Existing permissions
are required; it never requests them. `NativeUIRenderTests.testRenderWindowPinning`
renders the card in light/dark appearances and narrow/wide Window Tiling layouts
when `AOM_UI_RENDER_PATH` is set.
