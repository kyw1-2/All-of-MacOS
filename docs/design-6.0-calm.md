# AOM 6.0 — Calm

2026-11-16 · base 5.0.0 (`b27582c`) · main window, menu bar, buttons, Automation editor, performance

## Why

5.0 gave every tool a coloured identity, but drew it as a saturated white-glyph squircle on every
sidebar row, setting row, card, quick action and palette row, added a brand-gradient greeting banner
and hue-washed cards. The owner's verdict: cheap and "AI-looking", the Automation ("actions") screen
unchanged from 4.x, and the main window lagging every time it opened. Two independent reviews of 5.0
reached the same conclusions:

- GPT/Codex report (`~/Documents/Codex/2026-11-16/new-chat-2/outputs/AOm-design-report.md`, brief
  `AOm-Claude-design-brief.md`; 40 references incl. Things, Bear, Linear, Sleeve, Dropover,
  Pixelmator, Sketch): keep the identity in the sidebar/header, neutralise repeated row icons, no big
  gradients or equal-size card grids, connect the selection to the action bar, motion only for state.
- DeepSeek plan (`docs/design-overhaul-plan-20261116.md`): "the bar is a page sign, not a context
  tool"; colour budget (colour only for *which tool*, repeated rows neutral); performance invariants
  first (kept pages, no page-switch animation, hidden pages idle).

## What changed

**Marks** (`AOMIdentity.swift`): `AOMAppIcon` gains styles. `.tinted` (glyph in its hue on a 12–20 %
wash of the hue, radius 28 %) is the default; `.glyph` (no plate) is the sidebar; `.solid` is kept only
for brand use. No drop shadows, no top-lit strokes. Marks turn white on a selected row.
`AOMRowIcon` (setting rows, Settings window rows) is a neutral secondary glyph again.

**Buttons** (`AOMButtons.swift`): `AOMSoftButtonStyle` (quiet fill, no outline or shadow, hover and
press steps) is the default for every page and Settings button; `AOMPrimaryButtonStyle` (accent fill)
replaces `.borderedProminent` everywhere and is applied to every `.defaultAction` button. Sizes follow
the control size (18/22/26/32 pt). Increase Contrast adds an edge.

**Action bar**: contextual. Pages publish `aomBarContext(id:_:)` — a title for the selection and its
actions. Automation: *Test ⌘↩*, Turn On/Off, Duplicate, Pin, Delete. Clipboard: *Copy ⌘↩*, Copy as
Plain Text, Rename, Pin to/Unpin from each pinboard, Delete. The first three are buttons in the bar
(primary in the accent), all of them head the Actions panel. Related-tool marks left the bar.

**Workspace**: plain title ("Workspace", Running · N automations on) instead of the gradient greeting;
tools as one grouped two-column list (mark, name, description, chevron) instead of hue-washed cards;
quick actions as command tiles (mark, name, shortcut) in one card. Scope chips are Linear-style tabs.

**Automation editor**: header with the input's mark and a summary line (Trackpad · 1 step · On), the
scope picker and switch without labels; each step shows its mark with the step number as a corner badge
and its own switch (the "Step / Enabled / Name / Notes" block is gone — name and note fold into a
collapsed "Name and note" group); "Shortcut to send" is one recorder field (click to record, Esc
stops, × clears). List rows use neutral input glyphs. Filter chips are tabs.

**Sidebar**: glyph-only marks in the tool's hue (Things), the app's own icon in the header.

**Menu bar**: a click on the icon opens a control panel (`AOMMenuBarPanel.swift`): state and master
switch, switch tiles (Drag to Snap, Clipboard, App Audio, Keep Awake, Gesture HUD) that fill with the
tool's hue when on, a focus/microphone strip when one is active, six quick actions, then Open, Settings,
All Commands and Quit. ⌥-click or right-click (or `defaults write com.kyw.allofmacos
AOMClassicStatusMenu -bool true`) opens the full menu as before; All Commands opens it from the panel.

## Performance

Measured with the new `--aom-preview-bench-reopen` (hide and show the main window six times after
visiting every page; main-thread CPU and longest stall in the 1.5 s after each show), debug build,
same machine:

| | worst stall per reopen | main-thread CPU per reopen |
|---|---|---|
| 5.0.0 (all 12 visited pages alive) | 224–277 ms | 255–309 ms |
| 6.0.0 | 107–163 ms | 139–301 ms |

Causes found by sampling: every live page is laid out again when the window is shown; the Files
page called `FileManager.displayName` and read icons from its body; the toolbar subtitle was a
preference re-collected across every live page on each update; Focus' Add App menu enumerated
running apps on every render. Fixes: at most four pages stay built (`AOMPageRetention.keepAlive`,
least recently selected evicted, order preserved); the subtitle is a store the page writes
(`AOMToolbarSubtitles`); Files shows a placeholder until it has read the real values; the running-apps
list is cached for 5 s. With only Workspace alive the remaining cost is SwiftUI's own layout and
rendering (AOM frames are a few samples). Release builds are faster than these debug figures.

## Verification

- 160 tests (new `CalmRedesignTests`: retention cap and order, bar key text, button scale, subtitle
  store).
- Preview screenshots (light and dark, real preset seeded into the isolated preview): Workspace,
  Automation with 64 automations, Capture, Audio, Text Actions, the menu bar panel.

## Not changed

Engines, data formats, floating panels with their own styles (clipboard shelf, Quick Access, pins,
text-action bar), text fields (system rounded style kept for its focus ring).
