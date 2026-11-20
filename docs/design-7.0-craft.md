# AOM 7.0 — Craft & Fluidity

Source: the user's 7.0 plan (Phases 1–4, nine files) and Codex's review of it
(`~/Documents/Codex/2026-11-20/dlrj-x20/outputs/AOM-7.0-구현검토-보고서.docx`, `AOM-7.0-보완코드.zip`).
Codex's revised files were taken as the base (`Views/AOMCraftTokens.swift`,
`Services/AOMOverlayCoordinator.swift`, `Views/{Launcher,Clipboard,Audio,Automation,Capture,MenuBar}/`).

## What is wired where

| Plan item | Where it lives in the app |
|---|---|
| Tokens (warm canvas, hairline, hover fill, motion, radii, keycap) | `AOMCraftTokens.swift`; `AOMColor.canvas`/`surface` moved to the warm values; launcher ink + `aomLauncherSurface` added |
| Exclusive overlays | `AOMOverlayCoordinator.present` from the launcher, clipboard shelf, menu bar panel, window switcher, Files drop shelf; dismiss closures hide synchronously and never restore focus (`AOMLauncherController.hideImmediatelyForHandoff`, `WindowSwitcherController.closeForHandoff`) |
| Progressive hydration | Audio and Automation pages in `MainWindow` (`AOMPageSkeleton` placeholder) |
| Hygiene test | `AllOfMacOSTests/DesignTokenHygieneTests.swift` (Codex's corrected file list) |
| Launcher header / split view / calculator card / footer | `QuickCommandPalette` (search field accessory, `AOMLauncherSplitView` on Clipboard History and Window Management, `AOMCalculatorSplitCard`, `AOMLauncherFooterBar` with `bindsKeys: false` because the palette owns ↩ and ⌘K) |
| Paste card | launcher Clipboard History detail (`AOMLauncherClipDetail`); the shelf keeps its own card with the contrast fix and top light |
| SoundSource rows | `MixerAppRow`: `AOMOverdriveSlider` (gain ≤ 1, overdrive > 1 in 5 % steps), `AOMPeakMeterView` |
| Recipe spine | `ModernGesturesWorkspace` → Then → Steps \| Recipe (`AOMAutomationRecipeCanvas(scrolls: false)`) |
| Menu bar panel | `AOMMenuBarPanel` renders `AOMMenuBarCraftPanel` (+ battery accessory) |
| Annotate workbench / Quick Access card | compiled and hygiene-tested, **not wired**: the existing Quick Access already has CleanShot's hover controls plus a context menu, and the annotation editor's toolbar is out of 7.0's scope |

## Ask AI (beyond the plan)

The user asked for something better than "AI through a CLI", without losing the CLI.

- Providers (`Services/AI/AOMAI.swift`): Apple Intelligence (on-device), Anthropic, Local Proxy (:8082), OpenAI, DeepSeek, Ollama, Claude Code, Codex.
  Anthropic follows the current API: `anthropic-version: 2026-10-21`, `claude-opus-5-5` first, no sampling parameters, `output_config.effort` only for known Claude 5 ids on the first-party host, `fallbacks: "default"` with `server-side-fallback-2026-07-01` for Opus 5.5 / Sonnet 5.5 / Fable 5.2.
- Subscription use without API keys: no OAuth-token reuse (Anthropic's subscription sign-in is for its own apps, and reading another app's token is a credential risk). Instead the CLI path was made fast: one warm `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --permission-mode plan --strict-mcp-config` process per conversation. Measured in a probe: first answer starts 1.3 s after launch (CLI start), a follow-up in under 0.1 s; the process survives between turns.
- The transcript coalesces tokens to one update per ~30 ms; the palette itself redraws only when the AI rows' signature changes.

## Not verified here
- macOS 14–25 fallbacks (material instead of glass) and Increase Contrast / Reduce Transparency were not run on hardware.
- `--aom-preview-bench` was not re-run; the hydration change is not measured.
- Paid API providers were not called (no Anthropic key on this Mac); their request bodies and stream decoders are unit-tested.
