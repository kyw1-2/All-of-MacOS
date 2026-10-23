# All of MacOS — Changelog

A concise, English-language overview of user-facing changes. Release assets, build identifiers, checksums, signing information and version-specific verification notes remain authoritative in [GitHub Releases](https://github.com/kyw1-2/All-of-MacOS/releases).

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
