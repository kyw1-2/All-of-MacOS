# Text Actions regression repair on 3.4.23

Base: `aom-v3.4.23-b2026110705-g4d551296e956` (`4d551296e9563d795cf13e6c513c4283d511ec71`). This patch does not change the release version or installed application.

## Reported defects and changes

1. **Lists and tables:** AXList/AXTable/AXOutline/AXGrid are contextual, not unconditional file-view vetoes. A text selection, web/content-list context or native text editor can traverse them. Collections without text evidence still block file-copy fallback.
2. **Dead click retry:** the controller uses one tested disposition function. Empty, unchanged or unconfirmed first reads retry once with the original anchors, gesture and generation. Protected targets never trigger copy. Incomplete AX walks get one read retry and then fail closed.
3. **Asymmetric anchors:** mouse-down and mouse-up use the same pointer/ancestor resolver. Selection bounds and a separate focused snapshot are retained. Verified text hits or local selection bounds can confirm a click without an anchor. Direct selected text does not require AX range/bounds APIs; verified wide/multiline paragraphs have no arbitrary 600 × 76 limit. A late mouse-down snapshot no longer defeats positive click-local evidence.
4. **Focused media bypass:** focused nodes now pass the same DOM/role media check as hit-tested nodes. Password/media metadata is checked before reading that node's selected text.
5. **Selection identity:** geometry distinguishes identical words at different positions. Equal text/geometry remains stale across AX wrappers; absent geometry, changing wrappers alone is not a selecting drag. Focused snapshots additionally catch scrollbar/window drags that finish over stale selected text.
6. **ChatGPT recovery:** double/triple-click copy recovery is reachable after the retry, only for the existing host allowlist and a verified text hit. Media, password, file, pause, exclusion and secure-input gates remain in force. The existing pasteboard-preserving implementation is reused.
7. **Popover placement:** the extra 38 points apply above only, including an actual Dock-edge flip. Below remains 8 points from the selection.
8. **Expansion drag:** movement past the drag threshold takes precedence over click count, while drag-and-drop/modifier exclusions and trigger preferences remain respected.
9. **Depth/endpoint:** the walk supports 32 nodes, tracks cycles, and uses elapsed-time checks between nodes (0.35 seconds for an anchor probe; 0.8 seconds for a regular probe, plus in-flight bounded AX IPC). It continues checking metadata after finding text. A changed focused selection from a verified text start can survive an adjacent image/list endpoint only after that endpoint's ancestry is checked; an image inside a media player still blocks.
10. **Status icon:** icon creation immediately calls the current-state updater. The globalEnabled observer uses its existing main-queue delivery without adding another dispatch.

## Validation

- Full debug application/test-target compile and link through `scripts/run-tests.sh`.
- `TextActions|StatusMenuLayoutTests`: 120 tests passed, zero failures, before the final targeted refinements.
- Final targeted rerun (`TextActionsGateTests|TextActionsReadDecisionTests|TextActionsReaderRegressionTests`): 35 tests passed, zero failures, after the last code changes.
- Pure tree fixtures exercise the same generic traversal used by real AX reads, including deep media, content collections, native editors, file views, cycles and budgets.
- No app installation, clipboard action against another app, Git push or release publication was performed.

## Remaining live validation

Real Safari/Chrome/ChatGPT selection and AX IPC timing were not exercised by the automated fixtures. Check list/table drags, wide paragraph triple-clicks, background-window activation, ChatGPT's native selection bubble and YouTube fullscreen in the installed build before publishing. Geometry-free identical-word drags remain conservative when AX supplies no positive evidence of a changed selection. Existing unrelated compiler warnings are outside this patch.
