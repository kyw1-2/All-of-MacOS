# 3.0.8 follow-up audit

Baseline: `e8046bebe221c8283b70a3619f1871b75f29e1c7` (3.0.7).

## Scope and method

Continues the repository-wide inventory/search from 3.0.7 with focused review of
automation admission, sequence execution, input synthesis, parameter validation,
script client/XPC execution, display geometry, audio output/transport and DSP,
clipboard loading/saving/editing/paste/preview, capture dragging and stitching,
recording finalization and export, preset persistence, trigger timing/conditions,
permission monitoring and window restoration. Existing tests and the trusted
signed-release workflow provide executable coverage on macOS.

Static review and searches cannot establish that every feature is bug-free.
Hardware and interactive verification limitations are listed explicitly below.

## Findings and corrections

| Area | Defect | Correction and evidence |
| --- | --- | --- |
| Mouse automation | Quartz pointer compared against AppKit screen rectangles; Y axis and vertically arranged display selection are wrong | Use WindowManager's converted frames and shared pointer selector; test display above primary plus menu/Dock exclusions |
| Input recursion | Basic mouse actions and automated capture scrolling bypass the self-tagging event publisher | Use SyntheticInput.post, already recognized by keyboard/mouse monitors as AOM-generated input |
| Smooth scrolling | Zero-amount steps are removed after delay assignment, collapsing small scrolls into the first few milliseconds | Distribute nonzero steps over the full interval; test exact amount and total delay including nondivisible durations |
| Imported automation | abs(Int.min) in validation traps; basic scroll actions reach Int32 conversion without bounds; function-key lookup subtracts before checking range | Reject scroll extremes before arithmetic, bound planner input and check function-key range first; regressions cover Int.min/Int.max |
| Audio DSP | Nonfinite or overflowing samples persist in EQ delay state; final mixer sanitization cannot repair that state | Sanitize before processing, reset only the affected invalid band state, validate channel index; feed bad then normal samples and assert recovery |
| Clipboard preview | Full word/line arrays allocated for statistics; CRLF counted twice | One grapheme pass counts characters/words/lines; update the old CRLF expectation to one line break and add mixed-newline regression |
| Script lifecycle | Client mutable calls dictionary admits requests on arbitrary caller queues while completion/removal runs on main | Marshal entry to main; concurrent invalid background requests test main-thread replies without launching scripts |
| Dead code | Legacy in-process AppleScript and unread shell pipe implementations are unreachable after the asynchronous XPC branch | Remove legacy methods and duplicate switch bodies; active scripts retain XPC limits, timeout and output capture |
| Recording trim | Click-only tracks bypass overlay rendering; camera sidecars are ignored if the cursor sidecar is absent | Decide camera and telemetry rendering independently; real-media click-only trim test verifies rendered-source linkage and unchanged source bytes |

## Validation and limits

- All tracked shell/command files pass bash syntax checks; git diff whitespace
  check and plist version metadata inspection are performed locally.
- Linux has no AppKit/AVFoundation or Swift compiler. GitHub's trusted-main
  signed-release job executes the Swift suite, builds/signs the app and XPC helper,
  verifies both signatures, packages/verifies the DMG and promotes that source
  revision to Latest only on success. Consult the source commit's Actions run for
  its actual result.
- The workflow's existing 15 interactive Vision OCR integration exclusions remain.
  Real HomePod/AirPlay, physical multi-display input, TCC revocation prompts,
  camera capture and screen-recording interactions still need interactive Mac
  testing. Geometry and export tests are not claims of physical hardware testing.
- Automatic updates remain intentionally disabled for this private custom build.
  OS maintenance actions still depend on machine configuration and permissions,
  as documented in the previous audit; no blanket hardware/system certification
  or claim that every possible defect was eliminated is made.
- Distribution retains the AOM Dev self-signed identity and is not Apple notarized.
