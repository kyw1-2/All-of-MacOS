# CleanShot X 5.0.1: Resize / Overlay / Annotation evidence follow-up

Date: 2026-10-13. Scope: existing Oracle artifacts only; no Mac execution, installation, or AOM source edits.

## Authority and reuse

- Reused REA Interface Builder evidence `ev_2add849ab73838474c50d8c8944eceda21c7e8ba56434bc32ba38a25bb112497` from `rea-interface-builder.json`. Coverage: 15 recognized NIB documents, graph not truncated. This is static archive decoding, not runtime observation.
- Original executable identity rechecked with SHA-256: `4876cf9206b9b051afd6a6d4e6adbae2347fac891ceaaae2821b0c30c8daf167`.
- `followup-resize-overlay-evidence.json` retains selected NIB nodes and supplemental ASCII observations checked directly against executable bytes. These byte observations have **no new REA Evidence ID**; cite binary hash + full-file offset. They are not decompiled source or execution results.

## Findings

| Question | Observation | Interpretation and remaining gap |
|---|---|---|
| Resize controls | NIB object 90 is width, 46 height; both declare `IntTextField`. Actions include `proportionToggleClicked:` and `scalingTypeSet:`. Pixel and percent options exist. | Numeric size editing and unit/proportion controls are declared. Accepted ranges, rounding, overflow handling, physical pixels vs points, and dimension scaling algorithm remain unknown. |
| Keyboard flow | NIB cell 13 (Cancel) has Escape (`\x1b`), cell 71 (Resize) Return (`\r`). | AOM can use these declarative keyboard affordances. Runtime event precedence is unverified. |
| Flatten UI | NIB control 21 / cell 24 says `Flatten Annotations`, connects to `flattenClicked:`, has `NSAuxButtonType=3` and an `NSSwitch` alternate image resource. Object 33 says `(Can't be undone)`. | Checkbox-style option is a stronger interpretation than a standalone immediate destructive command, but activation behavior is not established. Do not implement immediate flatten-on-toggle merely from the selector name. |
| Initial unit | Pixel menu object 106 has `NSState=1`. | Archived selected state only; does not establish persisted/runtime default. |
| Flatten consequence | Binary `0x1392280`: “This action will flatten all annotations, making them uneditable.” `0x13922c3`: “This operation cannot be undone.” | Shipped warning text supports explicit loss-of-editability communication. Trigger, timing, undo-stack handling, and whether every resize flattens remain unknown. |
| Quick Access entry actions | `0x138a600` right-click context-menu help; `0x138aa00` Space preview; `0x138aa70` double-click Annotate; `0x138aa30` double-click video trim/compress. | Declared user guidance supports these interaction requirements, but success and focus/modifier rules need runtime checking. |
| Capture retention | `0x138a970` says History restores closed files; `0x138a9c0` says Pin keeps item on screen; `0x138a910` advertises drag and drop into apps. | Overlay dismissal, history persistence, and pinning should be modeled separately in an AOM design. This is an inference from text, not confirmed storage/lifecycle code. |
| Drag preference and Option | `0x13903f0` “Close after dragging”; `0x13905b0` `deletePopupAfterDragging`; both `0x13903a8` Option-to-close and `0x13904e8` Option-to-keep text occur. | Strong design hypothesis: Option temporarily reverses the configured post-drag close behavior. Exact modifier capture time, failed drag behavior, and drop completion remain unknown. |
| Save destination and Option | `0x1390520` export-location and `0x1390540` ask-for-destination choices; `0x139043e` Option-to-choose and `0x139049e` Option-to-use-export-location text. | Likely symmetric inversion of save preference, not a single unconditional Option action. No call path or runtime proof. |
| Overlay placement/timeout | `popupAutoCloseInterval` / `popupAutoCloseMode` at `0x13905d0` / `0x13905f0`; position and active-display text at `0x1390610`–`0x1390690`. | Setting names and help exist. Duration options, defaults, timer suspension, stacking, animation, and geometry are unknown. |
| Annotation canvas | `0x1390ee0` says annotations fit by dynamically resizing canvas; `0x1390f20` says automatically expand canvas. | Canvas-expansion feature is described. Padding, crop interaction, off-canvas object handling, and output bounds are unknown. |

## Corrections to the earlier interpretation

`REPORT.md` section 5 calls Resize “non-destructive”. The NIB proves controls and labels, not preservation of editable annotations or undo history. Keep that as a proposed AOM design until implementation or runtime evidence supports it. Likewise, an `AN...` class name or pixelate-style resource name only gives an investigation lead; it does not prove rendering, blur security, or parity.

Previous full native dispatch evidence reports cancellation; `rea-quicklook-macho.json` reports unsupported provider/host for that operation. Neither is successful decompilation. This pass reuses completed static evidence and does not reopen an expensive main-binary Ghidra session.

## AOM acceptance questions informed by the evidence

1. Resize: validate width/height, preserve ratio when locked, switch pixels/percent without compounding rounding, support Escape/Return, and explicitly choose/test whether editable annotations survive. Treat these implementation details as AOM decisions while original algorithms remain unresolved.
2. Flatten: distinguish checkbox selection from commit; communicate loss of editability; define undo behavior consistently. Verify real CleanShot trigger before claiming identical behavior.
3. Overlay: Space preview, screenshot double-click editor, right-click actions, pin, and drag are separate flows. Overlay dismissal must not accidentally imply deletion from History.
4. Drag completion: apply close preference only after a successful drop; check Option inversion against the saved preference and cancellation. Successful-drop semantics are a proposed robust AOM rule pending runtime comparison.
5. Save: test configured destination and Option inversion, including cancellation and failed writes.
6. Visual/runtime parity: capture equivalent scenarios at equal display scale and compare actual output, window geometry, event timing, keyboard focus, and preferences. No percentage score follows from this static inventory.

Status: Resize control declarations answered; overlay/annotation intended affordances partially answered through shipped text; rendering, dynamic state, lifecycle, and pixel parity unresolved.
