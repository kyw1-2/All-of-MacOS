## 3.0.11 — AirPlay playback continuity (2026-10-27)

## 3.0.13 (2026-10-27)

- Add an Audio entry and effect status to Workspace; improve mixer navigation, app filtering, reset actions, and accessible names.
- Process app boost per stream and output boost after mixing on each managed output, followed by the output limiter. Both can increase loudness.
- AOM's compressor has no lookahead and is not claimed to reproduce SoundSource's proprietary processing.


- Prevent zero-frame capture callbacks and paused video transitions from being interpreted as active output stalls; preserve the native route while playback switches streams.
- Keep large AirPlay output slices fully primed before rendering to avoid repeated partial-block silence at 44.1/48 kHz.
- Isolate remote-output lifecycle queues by device while preserving same-device teardown/start ordering, so one slow receiver cannot block other speakers.
- Ramp volume and mute changes over 5 ms; crossfade live EQ updates instead of applying abrupt filter state changes.
- Scope manual remote reconnection to apps sharing the chosen receiver; leave unrelated local video players and receiver sessions undisturbed.
- Clarify native/direct playback and connection errors in audio workspace; improve reconnect, mute and volume accessibility.
- Add regressions for callback transitions, large output slices, independent receiver teardown, ramp continuity, EQ changes and PCM stability. Physical-device AirPlay testing is still recommended.

## 3.0.10 — Continuous audio delivery (2026-10-26)

- Replace mutex-protected capture and AirPlay queues with bounded single-producer/single-consumer stereo queues. A busy control or producer lock no longer turns an entire IO block into silence.
- Use acquire/release atomic cursors, consumer-owned resampling state and coordinated clear requests; never overwrite frames still in use.
- The dedicated AirPlay mixing worker waits for short source-list/handoff operations instead of dropping its mix block. HAL callbacks remain non-blocking.
- Request a 1,024-frame quantum on AOM's private AirPlay capture aggregates where supported, reducing unnecessary 128-frame wakeups without changing the system output device.
- Add opt-in local queue/dropout counters without recording audio, plus wraparound, clear and concurrent ordering regressions.
- Skip EQ and compressor work while an app is idle or its capture queue is still priming, keeping spare CPU for realtime delivery.
- Retain the 3.0.9 EQ headroom, linked stereo limiter and full-session native mute protections.

## 3.0.9 — EQ distortion and audio recovery (2026-10-26)

- Hold native audio mute for the full capture session, and resolve returning helpers by verified ownership instead of shared helper bundle IDs to prevent overlapping tap membership.
- Reserve headroom from the combined app/master EQ response, avoiding hard clipping on loud material and boosted presets.
- Sum applications before linked stereo peak limiting; preserve waveform shape instead of flattening each app's peaks.
- Recover outputs whose device UID survives a changed CoreAudio object ID; restore native audio if recovery fails.
- Detect stalled capture and render callbacks, and base processing status on recent rendering rather than historical counters.
- Exclude AOM's raw audio PID before helper ownership resolution to prevent accidental self-capture.
- Mute All uses a current app snapshot. Automation rejects malformed PIDs, Boolean volume values and disconnected route UIDs, and exposes recent capture/render and EQ state.
- Reject malformed database ordering and shortcut values without crashing; leave the database intact for recovery.
- Add production PCM-path and distortion regressions, and replace an obsolete simulated boost test with the actual compressor.
- See docs/audit-3.0.9.md for measurements, verification and limits.

## 3.0.8 — Automation, audio and capture follow-up audit (2026-10-26)

- Mouse positioning uses converted Quartz display coordinates, including vertically arranged displays and Dock/menu-bar insets.
- Mouse actions and scrolling-capture events carry AOM's self-event tag to avoid recursive input triggers.
- Small smooth-scroll amounts span the requested duration. Integer extremes in imported scroll actions are rejected without overflow; function-key lookup handles extreme indices.
- EQ filters recover from NaN, infinity and arithmetic overflow instead of poisoning persistent channel state.
- Clipboard preview statistics stream through text without word/line arrays and count CRLF as one line break.
- Script client requests enter on main so its active-call dictionary and completion lifecycle share one queue. Removed unreachable legacy in-process script implementations.
- Trimming preserves click-only overlays and camera-only sidecars even without a cursor track.
- Added behavioral regressions; scope and interactive-test limitations are in docs/audit-3.0.8.md.

## 3.0.7 — File utilities and export reliability (2026-10-26)

- Recursive .DS_Store cleanup now visits hidden files and folders.
- Lock/unlock and hide/show preserve unrelated file flags and operate on the selected symlink itself.
- Batch renaming validates names and collisions before moving files, keeps literal replacement text and extensionless names, and reports filesystem failures.
- System Tools WebP conversion uses the bundled codec and refuses to overwrite an existing output.
- Cache cleanup counts only successful removals, includes top-level files, and preserves AOM caches regardless of name casing. Tests use disposable cache roots.
- Cancelling GIF export cancels its background worker and removes temporary output.
- Automation URL aliases accept mixed-case host names consistently.
- Adds regressions for these behaviors. See docs/audit-3.0.7.md for scope and verification limits.

# All of MacOS — Changelog

A concise, English-language overview of user-facing changes. Release assets, build identifiers, checksums, signing information and version-specific verification notes remain authoritative in [GitHub Releases](https://github.com/kyw1-2/All-of-MacOS/releases).

## 3.0.0 — Design overhaul
- **Native on macOS 26/27:** AOM now ships with the SDK it is built with, so the system draws Liquid Glass sidebars, toolbars and controls instead of the compatibility look. The minimum system stays macOS 14.
- **Workspace:** one card per tool with its live state and everyday action — capture modes and the latest shots, the newest clipboard items, pinned or recent automations, and your snap zones as miniature layouts. Problems and a running recording appear on top only while they exist.
- **Every page, one grammar:** a calm canvas with cards, the page title in the toolbar, and filters as chips with counts (Automation inputs, capture kinds, pinboards). Capture gets a mode bar in CleanShot's order and S/M/L thumbnails; Window Tiling previews a layout before you use it.
- **Settings:** a System Settings–style sidebar with search, titled groups, side-by-side choices for short options, labels that flip their switch, and new Shortcuts and Permissions panes with live status.
- **Command palette, first run, menu bar:** a glass palette with clearer results; a three-step welcome (the four tools, the access they need, the shortcuts) instead of the old tour; and a menu bar menu grouped into Capture, Clipboard and Automation with the everyday capture modes at the top.
- **Floating surfaces:** Quick Access, Capture History, Paste Stack, the recording bar, the capture toolbars and the text-capture HUD share one material.
- Shortcuts, automations, clipboard data and settings are unchanged. References and decisions: `docs/design-overhaul-20261024.md`.

## 2.3.0 — Natural capture behaviour and competitive parity
- **Quick Access:** a Trash button sits beside More on the hover curtain (⌘⌫ too) — one click deletes a fresh capture; only recordings ask first. Cards auto-close after 5 minutes for people who never chose a setting (they stay in Capture History); a stored choice is never changed.
- **One close rule:** Copy, Save, Pin and Annotate close the surface they were used from — Quick Access card, expanded preview, Capture History — and ⌥ keeps it open; a failure never closes it. Capture History selects on the first click, and its menu offers the same core actions as the card. The clipboard shelf's Copy stays open on purpose and now says so.
- **After Capture = Copy/Save** no longer shows a second card (Capture > "Also Show After Copy/Save" brings it back; a failed copy/save still shows it).
- **No drag stall:** unsaved captures get their drag file encoded off the main thread on hover; dragging does not save the capture.
- **Clipboard:** Erase History (pinboards kept, undoable) in Settings, the shelf and the library — the library's old "Clear All History" no longer deletes pinned items. Lowering the item limit asks before deleting. Kind, date and app filter chips under the search field, synced with typed type:/from:/board: tokens. Remove Background for images (new item; original kept), also in Quick Access and the editor.
- **Capture:** area selections snap to window and screen edges (hold ⌃ to place freely; Capture > Snap Selection to Windows). Recording keystrokes: Shortcuts Only / All Keys, position, size and light/dark style.
- **Automation:** activation groups can require days and times, power source, display count or an app's window, edited in Automation › scope menu › Edit Activation Groups…. `{{var:name}}` places workflow variables (for example a script's output) into Type Text, Open URL, HUD and notification text. AppleScript: `run trigger`, `capture`, `restore quick access`, `open aom url`.

## 2.2.0 — Glass window, compact rhythm
- **The window is glass now:** the chrome (sidebar, toolbar) sits on a real behind-window blur that shows your desktop through it — the System Settings / Things arrangement — while the page floats as an inset rounded card with a soft shadow and a hairline edge. Reduce Transparency and Increase Contrast restore the plain opaque window. The command palette keeps its material and gains the same lit rim.
- **Compact rhythm:** rows tightened (30 pt single-line, 44 pt two-line), page padding 24→20, section spacing 24→18, sidebar search field and footer trimmed — noticeably more of your content per screen at the same readability.
- **Depth with restraint:** filled buttons gained a vertical accent gradient with a lit top edge, and shortcut key caps read as tiny glass chips. Content surfaces stay opaque — glass belongs to chrome and floating layers, never to lists you read.
- Everything from 2.1.0 (selection contrast, all-input statistics, palette actions, searchable settings) is unchanged.

## 2.1.0 — Readability and honest numbers
- **Selected rows read again:** list rows (Automations, Clipboard library) used fixed label colours that macOS selection does not invert, so a selected row showed dark text on the accent fill. Rows, icons, pins and shortcut key caps now use hierarchical styles that invert with selection — key caps turn white-on-translucent inside a selected row. The command palette's keyboard selection, previously a 6% wash, is a clear accent fill; its no-results state gained a "Clear Search" button.
- **Empty states never clip:** every empty state's actions now wrap to a column when they do not fit (ViewThatFits), fixing the Automation input-filter empty state where both buttons were cut off by the list column; its primary button is "New Automation" instead of "New Trackpad Automation".
- **The editor gets its width back:** the trackpad preview in the When section shrank from a 180×140 block (plus padding) to 120×92 with proportional animation — about a third less height over the trigger summary.
- **Every automation counts:** keyboard, mouse-button, drawing and system triggers now record their runs, so Insights' figures and the Workspace's last-run times cover all inputs instead of only trackpad gestures (runs are counted once at dispatch; the trackpad keeps its own detect/fire statistics and is not double-counted).
- **Clipboard:** selected shelf filter chips and library pinboard chips use the accent fill with a luminance-derived label (yellow/orange/cyan accents get a dark label instead of unreadable white); the same rule protects every filled button. The shelf's empty state offers Resume / Open Clipboard Settings when recording is paused or storage failed; the Paste Stack panel gained the standard empty state with "Open Clipboard Library", a semantic status dot, caption-sized status text and a 22 pt remove hit target; gallery card previews end on a whole line (line limit instead of a mid-line clip) and card headers match the list-row tokens.
- **Command palette:** all capture commands show their real bound key caps (Window, Full Screen, Text, Record — previously only Area and the shelf did); secondary actions became a list — ⌘↩ keeps running the first, the rest live on the row's right-click menu.
- **Settings:** rows show their category colour icon again; menus size to their content so long labels ("Microphone + System Audio") stop truncating; the selected category is an accent-tinted chip instead of a faint grey; the permission row shows a live "All granted / n of m" badge beside Review; searching "shortcut/hotkey/단축키" now reaches Clipboard Storage, where the shelf shortcut recorder lives.
- **Consistency:** recording banners and permission/capture status colours use the app's warning/danger/positive tokens (respecting accent and high-contrast settings); the sidebar footer switch matches the app control size; capture overlay capsule labels shrink instead of clipping; the Window Tiling stage tops out at 280 pt so the layout grid leads.
- **Cleanup:** removed three dead view files' worth of unused code (the pre-2.0 sidebars, an unmounted inspector panel, a never-used shared search field — about 1,500 lines); the tiling editors moved to SnapEditors.swift. Palette search/Esc logic is extracted and unit-tested (10 new tests); automation statistics recording gained 3 tests. Known limitation (unchanged): Insights' 24-hour and 7-day figures derive from the recent-event ring buffer, so very heavy use can trim a day.

## 2.0.0 — A Mac window, built around your work
- **Navigation:** the capsule tab bar is gone. A labelled, collapsible system sidebar holds the six places (⌘1–⌘6, View ▸ Hide Sidebar) with Search at the top and the automation switch, Settings and Help at the bottom. Each page owns its toolbar: title and status, view switch, search and its primary action in the same places on every page.
- **Workspace:** problems first and only when they exist (permissions, paused automation, a shortcut conflict, clipboard storage), then Capture Area / Clipboard Shelf / Search with their real shortcuts, your pinned and recently used automations (with last-run time and a hover Run button — never for Type Text), recent captures you can copy, edit or drag, and recent clipboard items you copy with a click. The five-figure strip is one quiet line that links to Insights.
- **Automation:** list → wide editor. Rows show each automation once (no repeated input name), what it does with its key value (⌘W, Bedroom, …), its keys, pin and switch. The editor reads Name · Applies to · Enabled, then When, Do, Options; Test sits next to its result (running, ran, failed). The sortable table is a view switch. Scope moved to the toolbar; narrow windows switch between list and editor.
- **Command palette:** opens focused, ↑↓ to move, ↩ primary, ⌘↩ secondary (Run Now, Copy as Plain Text, Copy capture), Esc clears then closes; grouped when empty, one ranked list while searching. Its shortcut is ⌘K unless an automation or capture/clipboard hotkey owns it, then ⇧⌘K. Available as View ▸ Search….
- **Clipboard library:** list with a preview built for each kind (full text, image, link with Open in Browser, files), Copy and More next to it, Return copies the selected row; pinboards and type filter head the list. The ⇧⌘V shelf is unchanged.
- **Capture:** the tool column became the toolbar's Capture menu (with your shortcuts); cards offer Copy, Edit, Show in Finder and Pin on hover and drag straight into other apps.
- **Insights:** a period switch (24 hours, 7 days, all time) scopes every figure; labels say what each number is.
- **Design system:** system semantic colours and the user's accent, a 13 pt desktop type scale, spacing/size/motion tokens, glyphs without coloured squircles, hairline separators, no press-scaling. Shared row, heading, notice, run-status and key-cap components.

## 1.9.2 — No password typing at the lock screen
- Type Text refuses to run while the screen is locked, and stops if the screen locks mid-way. The lock screen also turns on Secure Event Input, so 1.9.0 and 1.9.1 registered their secure-input shortcuts (including the ⌃ alias) there as well; nothing is registered while locked now.
- Documented the one-time Keychain prompt each new build triggers for clipboard history.

## 1.9.1 — Sheet polish
- The Automation editor fits shorter windows: its header shows the scope and holds pin, duplicate and delete in a ⋯ menu, and the input type moved into the Trigger section, replacing the separate Details box.
- Capture Library thumbnails use the sheet's light inset grey instead of a dark backdrop; cards are wider so the kind, size and time caption is never cut off, and the kind is omitted when the title already states it.
- Insights' most-used rows use the 1.9 type scale (14.5 pt titles, 12 pt details).

## 1.9.0 — Unified sheets and password-field typing
- Redesigned every page as one flat sheet on a neutral canvas: sections are separated by hairlines rather than separate cards, shadows are nearly invisible and colour is limited to small icons, state and one primary blue. Glass and ambient gradients are gone.
- Rebuilt the Workspace to fit on one screen: a five-figure summary strip, the automation list with inline switches, and a This Mac column with permissions, Drag to Snap, clipboard history, password-field status and quick actions.
- Moved the Automation editor inside the page sheet with a draggable divider, so it no longer covers the navigation row; dropped the redundant Type column.
- Window Tiling, Capture, Clipboard and Insights now share the same sheet layout and fill the window height; Insights shows inputs and configuration side by side on wide windows.
- Raised the type scale (14 pt body, 26 pt titles) and verified light and dark appearance.
- Fixed Type Text in macOS password dialogs: ⌥ and ⌥⇧ hot keys are withheld by macOS during Secure Event Input, so AOM registers a ⌃-added alias (for example ⌃⌥P for ⌥P) only while Secure Input is active and never over an existing binding. Typing uses a private event source so modifiers cannot latch; the 1.8.0 pasteboard round-trip was removed.

## 1.6.0 — Unified visual design
- Introduced a consistent app-wide design system with a light-gray canvas, borderless elevated cards, clearer typography and a single blue accent.
- Refined navigation, page headers, controls and the Home dashboard for denser, more coherent presentation.
- Applied shared visual components across Gestures, Window Tiling, Capture, Clipboard, Insights and Settings.
- Multiple archived development builds share the 1.6.0 version; inspect each release's build number to distinguish artifacts.

## 1.5.0 — Navigation and Home
- Rebuilt the main window around one persistent navigation rail and a shared page header.
- Reorganized the Home screen with primary actions, automation status, metrics and responsive activity panels.
- Consolidated search, capture access and diagnostics into consistent navigation controls.

## 1.4.0 — Searchable Settings
- Replaced separate settings pages with a unified, searchable settings hub.
- Added category chips, persistent search controls and grouped settings cards.
- Applied preference changes immediately and moved advanced controls into contextual sheets.

## 1.3.1 — Capture visibility
- Extended the screen-capture visibility preference to annotation, recording export, expanded previews and floating windows.
- Centralized visibility handling across AOM-managed windows. Actual capture exclusion remains dependent on macOS and the capturing application.

## 1.3.0 — Local workflow expansion
- Added multi-file drag support, reorderable clipboard collections, expanded search and configurable clipboard interaction.
- Extended recording editing with ordered ranges, zoom suggestions, editable camera/shortcut layers and export presets.
- Added floating action menus, more local input/trigger options, scoped automation commands and Finder integrations.
- Introduced privacy-conscious, opt-in link previews. Some hardware and operating-system combinations remain unverified.

## 1.2.8 — Responsive workspace and text automation
- Refined the native main window, gesture editor, sidebar and appearance handling.
- Reduced unnecessary UI-thread work in clipboard and navigation paths.
- Updated Type Text to emit per-character key events with configurable intervals without replacing clipboard contents.
- This release reported 873 passing tests; protected input fields may still reject synthetic typing.

## 1.2.7 — Clipboard responsiveness
- Improved focus handoff before direct insertion into destination applications.
- Moved clipboard payload processing, rich-text preparation, searching and previews off the primary UI thread.
- Prevented stale background results from overwriting newer edits, selections or copied content.

## 1.2.6 — Reliable automation and editing
- Made capture-dependent workflows wait for actual output completion and report failures.
- Improved OCR option handling, encrypted clipboard activity-log persistence and legacy-data preservation.
- Reduced UI-thread work for gesture history, preset saving, image decoding and preview transforms.
- Added revision checks to reject outdated asynchronous results.

## 1.2.5 — Clipboard, capture and automation fixes
- Improved clipboard polling and support for additional rich-text and image formats.
- Reduced synchronous processing in direct insertion, screenshot encoding and file saving.
- Fixed action ordering, cancellation behavior and stale capture reuse.
- A separate 1.2.5 hotfix strengthened archive recovery, encrypted activity logging, local automation access and capture-history memory management. Distinct tags identify the two 1.2.5 source revisions.
- The initial 1.2.5 release explicitly did not run functional or regression tests; this is not a claim of verified runtime performance.

## 1.2.4 — Dynamic clipboard filters
- Populated application filters from recorded clipboard sources instead of a fixed list.
- Improved filtering for historical entries and aligned the main-window header boundary.

## 1.2.3 — Faster text capture
- Added a faster single-pass OCR path for interactive text selection, retaining configurable recognition settings.
- Reduced clipboard-shelf startup and long-item rendering work.
- Fixed cancellation-related stalls in text capture.

## 1.2.2 — Native main window
- Introduced a source-list layout, sortable gesture table and optional inspector.
- Refined the keyboard-accessible clipboard shelf and shortcut conflict handling.
- Fixed interactions across capture, navigation and gesture management.

## 1.2.1 — Design and performance
- Unified native UI components and accessibility-aware appearance.
- Improved gesture filters, scope management, window-tiling layouts and Capture Studio entry points.
- Refined clipboard history and instant text capture. An earlier build was superseded by a later 1.2.1 build.

## 1.2.0 — Native UI foundation
- Added a native navigation split view, unified toolbar and keyboard-oriented gesture controls.
- Refined the capture, clipboard, tiling and settings sections.
- Preserved document scrolling while reducing unnecessary visual chrome.

## 1.1.5 — System actions and annotation
- Improved system appearance, Focus and lock-screen actions, plus named-trigger deep links.
- Enhanced annotation controls, previews and interaction behavior.
- Refined local clipboard, screenshot and automation workflows.

## 1.1.4 — Trigger organization
- Expanded trigger and action catalogs, workflow variables and activation controls.
- Improved gesture organization, pause settings and global configuration.
- Published a verified development source snapshot.

## 1.1.3 — Local intelligence and integrations
- Expanded local clipboard intelligence, permission-scoped automation interfaces and responsive interactions.
- Refined capture, annotation and on-device text extraction.
- The supplied build record noted one failing codec-resource test; no clean-test claim is made here.

## 1.1.2 — Interaction refinements
- Improved clipboard selection, editing and preview interactions.
- Refined screenshot quick access and annotation interfaces.
- The supplied build record noted one codec-resource test failure.

## 1.1.1 — Clipboard selection fixes
- Made single-click card selection immediate and improved keyboard focus handoff.
- Consolidated multi-item text copying and corrected clipboard-stack ordering after deletion.
- Polished capture-history card interaction and related settings.

## 1.1.0 — Expanded local creative workflows
- Added scrolling capture sessions, OCR-enabled clipboard search, encrypted clipboard history and richer recording controls.
- Expanded annotations, editable projects, export formats and Finder integration.
- Included pause/recovery controls for recording and capture workflows.

## 1.0.14 — Preview and keyboard interaction
- Improved clipboard previews, keyboard shortcuts, selection after deletion and focus restoration.
- Refined capture preview controls, annotation manipulation and undo/redo.

## 1.0.13 — Preview and scrolling polish
- Refined the clipboard-preview and scrolling experience in the archived development build.

## 1.0.12 — Clipboard and capture editing
- Improved clipboard cards, searching, selection and interaction feedback.
- Expanded screenshot annotation, mosaic/blur, resizing, pinning and export controls.

## 1.0.11 — Development build
- Archived an AOM development artifact. Consult its release page for build and signing details; no additional functional changes are asserted here.

## 1.0.10 — History performance
- Made clipboard-card selection immediate and reduced forced scrolling.
- Generated image previews and metadata in the background.
- Reorganized capture history into a compact horizontal panel.

## 1.0.9 — Clipboard and capture UI
- Expanded clipboard search, filters, multi-selection and ordered copy workflows.
- Refined capture annotation, preview controls and quick actions.

## 1.0.7 — Annotation improvements
- Refined the contextual annotation toolbar and screenshot combining.
- Added reversible image merging and associated undo/redo restoration.

## 1.0.2–1.0.6 — Early development archives
- Preserved early local development artifacts with separate build identifiers, signing metadata and checksums.
- See their individual release pages for verified provenance; no additional feature or test claims are made here.

---

**Distribution notice:** These are private development builds. Self-signed or ad-hoc signatures are not Apple Developer ID notarization. Changes listed above describe documented implementation work, not guaranteed compatibility with every application, device or macOS release. Cloud synchronization and other excluded integrations are not represented as delivered features.
