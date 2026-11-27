# AOM 7.22 — DeepSeek's commercial-app report, applied

Base: `96fe722` (7.21.1, installed). Branch `feat/7.22`. Claude Code, 2026-11-27.

Source: DeepSeek Harness on Oracle, 2026-11-26 —
`~/aom-killer-20261126/report/AOM_7.21_상용앱_역공학_기능_UI_적용_분석.md` (PDF/DOCX alongside; Ghidra evidence
for DaisyDisk, Electron sources for Screen Studio 4.1.0 and TextExpander 8.6, Mach-O metadata for Proxyman).

## 1. The report's claims, checked against the code first

| Claim | Checked | Result |
|---|---|---|
| Clipboard panel draws secrets in plain text (`ClipboardEntry.previewText`, `ClipboardPanel.swift:1964`) | Code read | **True.** The card drew `previewText`; launcher rows, the stack and the Clipboard page drew the title (the first line of the copied text). This was the one security defect in the report. |
| Only a global 30-day retention, no per-item expiry | `ClipboardStore.removalPlan` | True. |
| No `runScene` action (`Action.swift`) | grep | True — scenes ran only by hand. |
| No microphone-in-use or screen-text trigger | `SystemTriggerKind` | True. |
| Cursor sampled at 20 Hz, 3-tap FIR | `ScreenRecordingService.startCursorSampling` (0.05 s), `AOMCursorTrack.smoothedPosition` | True. |
| No audio file writing, no speech recognition anywhere | grep `AVAudioFile`, `SFSpeechRecognizer` | True. |
| Snippet fields asked in the launcher, not at the caret | `PaletteSnippetForm.askFromTyping` | True. |
| Port killer and treemap "missing" (the prompt's premise) | `SystemToolsNetwork`, `StorageTreemap` | False, as the report itself says — both existed. |
| "Empty white boxes" in Window Tiling | — | Report says outdated; not acted on. |
| Sidebar's system-blue selection should be neutralised | HIG Sidebars | Report recommends keeping it; kept. |

## 2. Applied

| Report § | Item | Where |
|---|---|---|
| 4.1 P0 | Items that look like a credential show a lock and a length, never characters, on every clipboard surface (cards, stack, launcher rows and detail, Clipboard page list/detail/title/action bar, VoiceOver). Show / ⌥-click reveals until the panel closes. Setting: Clipboard › Privacy. | `ClipboardConcealedContent.swift`, `ClipboardPanel.swift`, `ClipboardStudioView.swift`, `AOMLauncherDetail.swift`, palette rows |
| 4.1 P0 | Per-item lifetime: Expire › In 1 Hour / Tomorrow (09:00) / In a Week / After Pasting Once / Never. Expiry applies on pinboards too. "Paste once" deletes the item 1 s after it is pasted and clears the system clipboard 60 s later if it still holds that copy. | `ClipboardEntry.expiresAt/burnAfterPaste`, `ClipboardStore.setLifetime/scheduleBurn` |
| 4.1 P0 | Unpinned secrets leave history after 24 h by default (1 h – 1 week, or with other history). Removals go to Undo Delete. | `Settings.secretLifetime`, `removalPlan(isSecret:)` |
| 4.1 | Meaning search: `~ words` (or `의미:` / `meaning:`) ranks by NaturalLanguage sentence embeddings (Korean/English), 0.6 × cosine + 0.4 × text match, threshold 0.35; secrets are never embedded; in memory only. | `ClipboardCodeAndMeaning.swift`, `ClipboardPanelState.displayedResults` |
| 4.1 | Code clips are coloured (keywords, strings, comments, numbers; first 4,000 characters). | `ClipboardCodeHighlighter` |
| 4.2 P0 | Meeting recording: microphone (AVAudioEngine) and other apps' sound (ScreenCaptureKit, AOM excluded) to CAF files in Documents/AOM Meetings; transcript on-device only (SFSpeechRecognizer, `requiresOnDeviceRecognition`, 50 s pieces), "Me" / "Others" from the two files; summary (decisions, action items, open questions) with the on-device Apple Intelligence model when available. Red menu bar indicator with elapsed time while recording. Start from the Capture menu, the meeting alert's Join and Record, the new action, or the offer that appears when the microphone turns on during a calendar meeting (once per meeting, 20 s, never records by itself). | `MeetingRecorder.swift`, `MeetingAlerts.swift`, `CaptureMenu.swift` |
| 4.3 P1 | Cut Silences (Long Pauses / Pauses / Every Gap): 16 kHz mono levels in 10 ms frames, speech level = 95th percentile, pause = 30 dB below it (bounded −60…−30 dB), ≥ 400 ms, 300 ms kept around speech — Screen Studio's podcast constants. Non-destructive (sequence clips), Undo Cuts; 10 ms audio fades at every cut on export. | `AOMSilenceCutter.swift`, `RecordingExportEditor`, `RecordingExportService.render` |
| 4.4 P1 | Cursor sampled at 60 Hz; One Euro filter on the editable cursor; "Follow the pointer while zoomed" (240 ms window, blended in as the zoom rises). | `AOMCursorTrack.swift`, `AOMStudioTimeline.following`, `AOMStudioRenderer` |
| 4.5 P1 | Network sheet: live download/upload and a 60 s sparkline (getifaddrs counters, 1 s, only while visible). Folder Sizes: Map / Rings toggle (DaisyDisk-style sunburst, 3 rings, hover names, click to enter). | `NetworkThroughput.swift`, `NetworkThroughputGauge.swift`, `SystemToolsStorageMap.swift` |
| 4.6 P2 | Run Scene action; triggers Microphone turns on / off (default input's IsRunningSomewhere, follows a new default input) and Text appears on screen (display under the pointer, every 2–60 s, OCR only when a 32×18 thumbnail changed, fires on appearance, baseline at start). | `ParityActions`, `TriggerWatchers722.swift`, `TriggerSystemSignals`, `TriggerListPanel` |
| 4.7 P2 | Snippet fields at the caret: non-activating panel at the AX caret bounds (re-placed after 200 ms, screen-centre fallback, clamped to the visible frame), all fields on one form, ↩ inserts, ⇧↩ new line, esc leaves the text. Toggle in the typed-string editor. | `SnippetCaretForm.swift`, `KeyboardMonitor` |
| 4.7 P2 | Korean/English typing fix: 2-set automaton both ways (compound vowels/finals, final carry-over). Action "Fix Korean/English Typing" (selection or the word before the caret, switches the input source) and a text transform. | `HangulLayoutConverter.swift` |
| 5.3 | Cards get a 0.5 pt hairline (1 pt with Increase Contrast / Show Borders). Page column 960 → 1,180 pt. Page hero mark 36 → 28 pt. Menu bar panel fonts on tokens (22 hard-coded sizes). | `AOMTheme.swift`, `AOMTokens.swift`, `AOMMenuBarCraftPanel.swift` |

## 3. Not done (open)

- Meeting: starting without a click (the offer asks first), a mixed m4a, SpeechAnalyzer (macOS 26) instead of SFSpeechRecognizer, real speaker diarization. A Microphone turns on → Start Meeting Recording automation covers the automatic start by hand.
- Studio: camera bubble hidden during silence (Screen Studio `hideDuringSilenceMs` 1388), hatched silence marks on a timeline, a zoom-range (slice) model, a smooth/precise slider.
- System Tools: per-app traffic (nettop), file-type/age/duplicate overlays on the map.
- Clipboard: a menu bar badge for items about to expire; a panel text search still matches inside a hidden secret (the card stays hidden).
- Scenes: a "When" section in the scene editor; screen-text region selection.
- Typing fix: automatic suggestion (double space) — the action is explicit only.
- UI: per-page layout archetypes (Studio / Instrument / Board / Flow / Form), removing the hero on non-Home pages, row density 34/44 → 30/38.

## 4. Verification

Unit tests: `AllOfMacOSTests/AOM7220Tests.swift` (lifetimes and decoding, mask, Hangul both ways and round trips,
trigger matching/needs/validation/JSON, screen-text edges, caret geometry, silence ranges and clip removal, One Euro,
follow zoom, transcript format, throughput, sunburst layout and hit test, code tokens, meaning query). Full suite and
release on GitHub CI.
