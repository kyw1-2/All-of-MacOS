# CleanShot X 5.0.1 → AOM parity ledger (evidence-rated)

Date: 2026-10-13 KST · Goal: independently implement comparable behavior and appearance without embedding CleanShot X code, artwork, compiled UI or licensed resources.

## Source provenance
- Official 5.0.1 installer: `https://updates.getcleanshot.com/v3/CleanShot-X-5.0.1.dmg`
- Verified SHA-256: `85ab95c8a4be4fb650a94ec087a7e7d89f4e6bda9c18611cdd44ab6a3edb1cf1`
- REA IB graph: `ev_2add849ab73838474c50d8c8944eceda21c7e8ba56434bc32ba38a25bb112497` (15 documents; 1,316 nodes; 706 links, no truncation)
- REA Mach-O/dylib graph: `ev_888ae81430de783297e09ba0ec1974c238eb39f819cfa68e29c46af848f7bcec` (142 load edges, two architectures)
- AOM baseline: `main` at `f660714`, focusing on `QuickAccessOverlay.swift`, `AnnotationEditor.swift`, `AnnotationDocument.swift`, `PinnedScreenshot.swift`, `CaptureSettingsView.swift`, `MediaHistoryOverlay.swift`.

### Status vocabulary
- **implemented, not parity-tested**: corresponding AOM code exists; reference interaction or image was not measured.
- **gap**: AOM source lacks a user-facing counterpart to an observed 5.0.1 control or behavior.
- **unknown**: REA NIB/strings only or no direct evidence; requires user-owned runtime observation.
- **PR**: implemented in the draft PR; not deployed.
- **out of scope**: excludes CleanShot Cloud, proprietary account integration, licensing and exact copyrighted visual assets.

## Evidence-backed capability mapping

| Area | Reference evidence | AOM baseline | Priority and next check |
| --- | --- | --- | --- |
| All-In-One capture | `MainMenu.nib` menu and selector `allInOneClicked:` | implemented, not parity-tested | P1: focus/selection comparison |
| Area capture | `areaClicked:` | implemented, not parity-tested | P1: coordinates, magnifier, crosshair |
| Window capture | `windowClicked:` | implemented, not parity-tested | P1: shadow/border exclusion |
| Fullscreen capture | `fullscreenClickedWithSender:` | implemented, not parity-tested | P1: multi-display |
| Previous-area capture | `takePreviousAreaClicked:` | implemented, not parity-tested | P2: stale display geometry |
| Text/OCR capture | `captureTextClicked:` | implemented, not parity-tested | P1: text grouping, language, clipboard |
| Scrolling capture | `scrollingCaptureClicked:` | implemented, not parity-tested | P1: seamless stitch/scroll termination |
| Screen recording | `recordVideoClicked:`; AVFoundation/ScreenCaptureKit | implemented, not parity-tested | P1: video/audio timing, pause, crop |
| Self timer | `selfTimerClicked:` | implemented, not parity-tested | P2: countdown fidelity |
| Status menu | `MainMenu.nib` 114 objects, 72 connections | implemented, not parity-tested | P1: layout/shortcuts/menu state |
| Quick Access preview | `ImagePopup`, `PopupBasic`, `QuickAccessSettings`, `PRQuickAccessView` symbol families | implemented, not parity-tested | P0: requires runtime capture and pixel diff |
| Copy / Save overlay | NIB/metadata and 4.8.8 focused evidence | implemented, not parity-tested | P0: click/hover behavior |
| Pin / Annotate from preview | `ImagePopup` symbol family, 4.8.8 evidence | implemented, not parity-tested | P0: hitboxes and return state |
| Drag file out | behavior inferred from user-visible product and AOM source | implemented, not parity-tested | P0: Finder/Slack/Discord drop |
| Swipe dismissal | behavior not demonstrated by 5.0.1 NIB | unknown | P0: gesture sensitivity, direction |
| Overlay auto-close | `QuickAccessSettings` family, prior 4.8.8 Preferences NIB | implemented, not parity-tested | P0: timer pause/hover/drag |
| Overlay stack/restore | `QuickAccessSettings` and AOM coordinator | implemented, not parity-tested | P1: screen edge, multi-monitor |
| Quick Access settings | 5.0.1 NIB doesn't expose full Preferences UI | unknown | P0: live capture of all 5 sizes/positions |
| Pin floating panel | `FloatingOverlay`/controller symbol family | implemented, not parity-tested | P1: native window level and move |
| Pin shadow/border/corners | `floatingOverlayShowBorder`, `floatingOverlayRoundCorners`, `floatingOverlayDropShadow` | implemented, not parity-tested | P2: draw/opacity |
| Pin locking | `floatingOverlayLocked`, `floatingOverlayUnlocked` | **gap** | P1: lock/movement interaction |
| Pin opacity | 4.8.8 metadata family; not independently confirmed 5.0.1 interaction | unknown | P1: runtime menu/slider |
| Pin zoom/magnification | 4.8.8 metadata family; not independently confirmed 5.0.1 interaction | unknown | P1: bounds and actual pixels |
| Annotation move | known toolbar functionality | implemented, not parity-tested | P1: selection/handles |
| Rectangle/filled/ellipse | tool labels and AOM `AnnotationKind` | implemented, not parity-tested | P1: line/corner controls |
| Arrow/line | tool labels, type metadata | implemented, not parity-tested | P1: arrow shape, caps, style |
| Text / counter | reference tool labels; AOM editor | implemented, not parity-tested | P1: font metrics, numbering |
| Freehand and highlight | reference tools; AOM editor | implemented, not parity-tested | P1: pressure/smoothing |
| Pixelate and spotlight | reference tool labels; AOM editor | implemented, not parity-tested | P1: blur/pixel fidelity |
| Crop | crop functionality and resize NIB | implemented, not parity-tested | P1: preserve layers, crop origin |
| **Resize dimensions** | `ANResizeControlViewController.nib`: Width/Height, pixel/percent, aspect lock, Resize | **gap → PR #2** | P1: CI then live validation |
| **Flatten Annotations** | same NIB, dedicated flatten button and irreversible-warning text | **gap → PR #2** | P1: undo preservation |
| Background expansion | historical 4.8.8 toolbar symbols, AOM model | implemented, not parity-tested | P2: fill/blur/canvas |
| File naming patterns | `NameTemplateWindow.nib`: token field, UTC, increment, illegal chars, preview | **partial / gap** | P1: independent naming UX |
| Changelog display | `ChangelogView.nib` Show changelog after update | unknown | P3: independent update UI |
| Local update framework | Sparkle framework and appcast URL | different implementation | P2: AOM's private GitHub updates |
| Quick Look sharing | four extensions incl. QuickLook | **partial / gap** | P2: native Finder extension integration |
| Share action | PinShare/AnnotateShare extension NIBs | **partial / gap** | P2: share sheet vs extensions |
| Camera/microphone recording | usage-description keys | implemented, not parity-tested | P2: consent and state transitions |
| Exact visual 99% | requires reference runtime screenshots, video and accessibility tree | **not established** | P0: acquire authorized runtime baseline |

## Acceptance gates for a measurable 99% target
1. Establish **at least 100 representative interactions** on an owner-authorized running copy of CleanShot X 5.0.1, with the same macOS version, screen DPI, language, light/dark appearance, permissions, and preferences as AOM.
2. Record each interaction's **starting state, keyboard/mouse input, visual output, clipboard/file side effects, focus and timing**. Independently screenshot/record those states.
3. Implement independently in AOM; do **not** transplant CleanShot's compiled UI graphs, internal implementation, copyrighted icons/art or license assets.
4. For functional parity: passing binary pass/fail assertions for all P0/P1 scenarios, plus no regressions in AOM's existing gesture/clipboard flows.
5. For visual parity: compare masks, dimensions, offsets, hover states, fonts, geometry, transitions, and retained accessibility semantics with clearly documented pixel-diff threshold. **No claimed percentage without runtime evidence.**
6. Build on GitHub Actions macOS CI, validate with user-owned Mac runtime testing, then merge/release. Don't publish a CI-unverified PR directly to Latest.
7. Scope excludes CleanShot Cloud/account/license systems and incompatible proprietary file formats.

## Implementation record
- 2026-10-13: draft [PR #2](https://github.com/kyw1-2/All-of-MacOS/pull/2) adds independent Resize Image dialog, resampling, stroke/shape scaling, undo-safe flatten, and deterministic XCTest coverage.
- Baseline Mac was unreachable during this work, so local UI playback/screenshot comparison is **not run**. Static reference evidence is not runtime equivalence.
- Full 5.0.1 reference artifacts/REA outputs retained privately on Oracle under `/data/academic-workspace/projects/cleanshotx-rea-20261013`.
