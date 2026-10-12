# CleanShot X 5.0.1 → AOM: evidence-backed implementation ledger

Date: 2026-10-13 (KST). Target: user-installed AOM project, `kyw1-2/All-of-MacOS`, feature branch `feature/cleanshot-501-resize-parity`.

## Provenance and reproducibility

- Official reference: [CleanShot X feature catalog](https://cleanshot.com/features), [5.0/5.0.1 release notes](https://cleanshot.com/changelog), [URL scheme](https://cleanshot.com/docs-api). No reference source repository is publicly provided.
- Original Apple installer: official `CleanShot-X-5.0.1.dmg` (50,557,562 bytes), SHA-256 `85ab95c8a4be4fb650a94ec087a7e7d89f4e6bda9c18611cdd44ab6a3edb1cf1`, verified against Homebrew.
- Oracle private original and extracted bundle: `/data/academic-workspace/projects/cleanshotx-rea-20261013`. Do **not** commit extracted executable/assets to AOM or redistribute the proprietary reference binary.
- REA `inspect-artifact` DMG Evidence `ev_5439da1b725998afe60593b73241758508293f0e0e3b0c5a4ae8e5e6337fb5c5`.
- REA `decode-interface-builder` Evidence `ev_2add849ab73838474c50d8c8944eceda21c7e8ba56434bc32ba38a25bb112497`: **15 compiled IB documents**, 1,316 object nodes, 706 edges, not truncated. Includes reference MainMenu, ANResizeControl, NameTemplateWindow, changelog, update, Share extension UI; does **not** include all runtime SwiftUI/dynamic windows.
- REA `trace-dylib-resolution` Evidence `ev_888ae81430de783297e09ba0ec1974c238eb39f819cfa68e29c46af848f7bcec`: **142** observed load edges across the Intel and Apple Silicon slices.
- Independent verification of shipped arm64 Mach-O Objective-C-exposed Swift class metadata: **446 unique runtime names**, including `FLEditor`, `FLSmartZoomAnalyzer`, `FLTimeline`, `FLTimelineZoomAnimation`, `FLVideoEncoder`, `FLCameraRecorder`, `FLCursorManager`, `ANHighlighter`, `ImagePopup`, `QuickAccessSettings`. The full class-name-only inventory is saved privately as `rea-derived-class-inventory.json`. Class names are not executable code, inferred behavior, or exhaustive Swift types/functions.
- REA-Ghidra: 12.1.4 with JDK21 and locally built Linux ARM64 native decompiler reports `healthy=true`. **Native function pseudocode on CleanShot X has not been recovered completely**; whole-binary import is not resource-proportional on the 2-vCPU Oracle server. Universal Mach-O must be thinned first. Do not pretend the original Swift source code is available.
- REA MCP direct handshake succeeds and enumerates **170 tools**. Antigravity MCP registration written; WebGPT terminal path tested with an actual delegated task (using a login shell). WebGPT **does not yet advertise REA as 170 separate native tools**; it can invoke the CLI via `bash -lc 'rea ...'`.

## Capability audit

Status codes: `AOM` implemented preexisting; `PR` implemented in this feature branch, CI/runtime check as stated; `PARTIAL` smaller scope than reference; `GAP` not verified as implemented; `UNKNOWN` cannot establish equivalence without runtime A/B observation; `CLOUD` excluded from local app compatibility.

| Group | Reference features | AOM implementation / evidence | Status |
|---|---|---|---|
| Capture | area, full screen, window, previous area, multi-display | CaptureCoordinator + ScreenCaptureService | AOM, UNKNOWN parity |
| All-in-One | combined selection, interface and post-capture action | separate capture modes; no full equivalent verified | PARTIAL |
| Capture details | pixel snapping, magnifier, freeze screen, cursor, window shadows | Settings + selection overlay | AOM, UNKNOWN parity |
| Scrolling | capture and stitching across apps | ScrollingCaptureService | AOM, UNKNOWN parity |
| OCR | Vision on-device recognition, linebreak modes, QR | capture text, Quick Access OCR/QR | AOM, UNKNOWN parity |
| Self timer | delayed screenshots | CaptureCoordinator self-timer | AOM |
| Quick Access | copy, save, more menu, annotate, pin, OCR, multi overlay, restore, auto close | QuickAccessOverlay, Coordinator, Policy | AOM; P0 visual+gesture gap |
| Quick Access file import | external PNG/JPG/MP4, drag out | Coordinator import + NSDraggingSource | AOM |
| Preview positioning | corners, sizes, auto close, multi-monitor | QuickAccessGeometry + CaptureSettings | AOM; measured visuals UNKNOWN |
| Annotate shapes | rectangle, ellipse, arrows, lines, text, counters, freehand, highlighter | AnnotationKind + Editor | AOM; behavior/graphics UNKNOWN |
| Annotate media | crop, background expand, reorder, duplicate, undo/redo, export | AnnotationDocument + Editor | PARTIAL |
| Resize | separate pixel/percent dimensions, preserve aspect | PR: AnnotationResizeDialog + resampling | PR |
| Flatten layers | explicit Flatten Annotations with Undo/Redo | PR: undo-safe bitmap flattening | PR |
| Pixelate / Blur / Redact | mosaic, Gaussian blur, opaque blackout choices | mosaic preexisting; PR adds a selectable Core Image Gaussian blur and a separate solid-black redact tool. UI/visual behavior not A/B verified | PR, UNKNOWN parity |
| Smart Highlighter | word-aware highlighting | rectangular/highlight draw only | GAP |
| Save editable project | proprietary .cleanshot format | editable in current session; no compatible persisted project | GAP (format intentionally not copied) |
| Combine screenshots | append and position screenshot layers | append below implemented; general 2D composite not verified | PARTIAL |
| Pinned floating image | window, position lock, opacity, multiple panels | PR: original-res pin, lock and opacity; rest preexisting | PR; click-through lock UNKNOWN |
| Capture history | recent file history, browsing, restore, import | CaptureHistory persistence + history overlay | AOM |
| Background tool | padding, gradients, blur, preset templates | AnnotationBackground partial | PARTIAL |
| Capture naming | template tokens/preview, UTC, increments | PR: configurable safe filename templates | PR |
| Recorder | area/fullscreen, FPS/quality, microphone/system sound, clicks | ScreenRecordingService | AOM, UNKNOWN |
| Recording editor | preview, trim, GIF, mute audio, quality | PR: video preview, MP4 re-encode options + existing trim/GIF | PR; verify CI |
| 5.0 Studio Mode | Smart Zoom, cursor smoothing, motion blur, camera/keystrokes edit, timeline keyframes, backgrounds | native Smart Zoom/timeline/FFunction classes present in reference; no AOM implementation | GAP |
| QuickLook extensions | Finder QuickLook and Share extensions | app-level preview and sharing only | PARTIAL |
| URL command API | capture/open history/recording/open from clipboard/import | PR: independent `aom://` actions; does NOT register `cleanshot://` | PR |
| Updates | updater, release feed | AOM GitHub Actions release system, signing gated | PARTIAL |
| Cloud | hosted uploads, comments, sharing, subscriptions | no compatible service/token/API, out of scope | CLOUD |

## Implementation coverage policy

1. This is **not** a claim of 99% equivalence. Neither total branch coverage nor pixel fidelity has been measured.
2. Class names, linker references, NIB actions and vendor docs establish *feature existence*, not observed pixels, animation duration, input hit testing or internal algorithms.
3. Commit only original AOM code and unit tests, not CleanShot's compiled code, UI assets, or proprietary files.
4. Discrete gates: macOS GitHub CI tests/build/package; local Mac signing and install; paired A/B screen + input tests; event/clipboard/file output inspection; memory/CPU overhead.
5. Mac control tunnel was offline as of this audit. Do not merge a PR into `main`, update the installed .app or claim runtime equivalence before macOS live tests.
6. On Oracle native Ghidra analysis should be performed on isolated, explicitly selected, *small* architectures/modules only with memory/time/CPU limits; do not repeat whole-app imports that have already caused high server load.

## Follow-up acceptance test inventory

- Capture full-area/window/scrolling/Retina on internal/external screens with negative coordinates and mixed DPR.
- Overlay positioning for 4 corners × every size × light/dark, + 1/2/3 capture stacks, drag-and-drop success/failure, cursor hover/auto-close, swipe dismissal and keyboard shortcuts.
- PNG/JPEG/HEIC output color management; crop/resize with 0/1/2 scale and multiple annotations; undo/redo around flatten/crop.
- Solid-black redact export: verify pixels fully overwritten, not an alpha masking illusion. Blur and mosaic are visually obscured but not a substitute for guaranteed redaction.
- Pinned image: source resolution vs thumbnail, lock/drag, opacity slider, multiple spaces/full-screen and multi monitor.
- Video record/stop/pause/audio track presence/quality; trim/GIF/export read-back, source-file nonmutation. Advanced 5.0 Studio keyframe/Smart Zoom/camera/cursor features remain independent gaps.
- URL scheme accepts only `aom://` and registered commands, rejects duplicate or unexpected query params, and never silently performs a requested unsupported action.
- Performance: capture memory retention, no extra resident OCR/Ghidra/rea workers; failures leave AOM's existing primary workflow intact.

## 2026-10-13 update: Blur tool and connection verification

- AOM editor now has an independently implemented **Blur** annotation using a bounded `CIGaussianBlur` compositing area, separate from the existing pixelation tool and opaque blackout tool. A deterministic checkerboard test checks that selected pixels change, outside pixels remain stable, and undo restores the original.
- The REA CLI has a local `rea` launcher under `/home/ubuntu/.local/bin`, configured with on-demand Java/Ghidra environment and reduced scheduling priority for heavy analysis operations. No resident REA daemon.
- Antigravity registration `~/.gemini/config/mcp_config.json` contains the official `rea mcp` registration with provider environment variables. Direct REA MCP initialize and tools/list returned 170 advertised tools.
- A delegated WebGPT High worker used its terminal to run `rea --version` and `rea doctor --provider ghidra --json`, confirming 6.4.0 and `healthy:true`. In this harness, WebGPT invokes REA through its terminal rather than showing 170 REA operations as separate built-in tools.
- macOS release/install checks and end-user pixel/gesture comparisons require the currently offline Mac. New code remains in Draft PR #2, not deployed.
