# AOM 3.4.38: verified dead-code cleanup (2026-11-09)

Base: `73c60e9` (3.4.37, first-pass 1,665 Swift-line cleanup). This second pass prioritizes unchanged runtime behavior and preservation of regression coverage over a line-count target.

## Applied

- Removed 63 tracked, non-build reference/media files from `assets/`, `MacMagicReference/`, and `MissionControlPlusReference/` (~30 MiB in checkout). No source, test, CI or documentation reference to their literal paths was found. Git history retains these files if research needs them again. Binary-file byte counts are **not** Swift source-line counts, despite claims in the supplied audit.
- Removed unreferenced `CompactHUDView` alias and `translucentPane`, `overlayButton`, `suppressScrollerReservation`, `isDismissed`, `supportedLanguages` helpers. This eliminates unreachable Swift declarations, without altering the call sites, active render paths, timers, inputs or audio code.
- Kept `TranslucentWindow`, which has direct regression coverage in `MainWindowPresentationTests` (the initial audit omitted this dependency).

## Declined after verification

- Do **not** remove the 32 `@objc` action selectors solely because plain-text call-site searches return zero: selectors can be late-bound by AppKit, menus and responder chains. The safe criterion requires runtime menu/selector coverage and feature-equivalence evidence.
- Do **not** delete 51 version-labeled test files. Their filenames do not establish duplicated coverage; deleting the keyboard/input, AirPlay, capture and clipboard regressions would weaken release gating.
- Do **not** delete test-only helpers or `TranslucentWindow`, where tests rely on the tested contract.
- Do **not** collapse eight design files to two, rewrite SystemToolsModel dispatch, merge clipboard renderers, or generalize input-window/snap gestures without differential behavior tests, hot-path latency/memory measurements and equivalence validation. Refactoring file structure or import count does not itself make the installed app faster; the forecast line savings are unsupported.
- Several supposedly removable design wrappers are active transitively: `AOMFloatingSurface` is used by `.aomFloatingSurface(...)` across clipboard/HUD/capture; `AOMPageChrome` by `.aomPage`; `AOMMediaBadge` and `AOMInPanelCapsule` by their active View extensions; `AOMModeButton`, `AOMWorkspaceBackground`, `AOMTintedButtonStyle`, `AOMRunStatusView` have direct live callers.

## Verification

- Source/string call-site scan included app, tests, scripts, XPC and extensions. All six removed symbols have zero remaining references.
- `swiftc -frontend -parse` validated modified Swift syntax, `git diff --check` validated patch whitespace.
- A signed macOS CI workflow runs full headless test suite, builds/signs, verifies XPC and DMG, and publishes release. Capture success/failure in release run, not as an assumed result.
- For runtime performance, compare AOM idle CPU on the same Mac before and after installing 3.4.38. A short observational sample is a smoke test, not proof of identical performance under all workloads.
