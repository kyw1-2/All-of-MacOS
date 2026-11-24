# AOM 7.16 — GPT's independent review of 7.15 (V01–V16)

Inputs: `~/Downloads/AOM-7.15-독립검수-75refs-2026-11-24.md`, `~/Downloads/AOM-7.15-Claude-후속개편-프롬프트-2026-11-24.md`. Base `48b418a` (7.15.0, installed 2026-11-24 22:1x KST).

| V | Status | Change |
|---|---|---|
| V01 Actions Return index | DONE | `AOMActionPanel` keeps `selectedID`; `AOMActionPanelSelection.resolve/step`; Return re-resolves by id; test `AOM716Tests`. |
| V02 automation stale closure | DONE | `ModernGesturesWorkspace.barContext` captures the id; `latest(id)` at press time. |
| V03 clipboard stale entry/board | DONE | `liveEntry(id)` and live board lookup; bar key includes board ids+names. |
| V04 context retention / late clear | DONE | `AOMBarContexts` owner token per writer; `clear(tab, writer:)`. Test. |
| V05 Workspace narrow header | DONE (code) | `ViewThatFits` with stacked fallback. Narrow-width screenshots NOT_RUN. |
| V06 Menu Bar resize identity | DONE | `AnyLayout` H/V with the pane as the same child; `sideBySide(width:current:)` hysteresis. Test. |
| V07 Menu Bar states | DONE | `MenuBarHeadline.text`. Test. |
| V08 Actions scroll / O(n²) | DONE | `ScrollViewReader` + `LazyVStack`, max 420 pt; rows get `isSelected` from one resolved id. |
| V09 toolbar items | DONE | `AOMToolbarActions` and `AOMToolbarSearch` are separate `ToolbarItem`s. |
| V10 manual permissions | DONE | Workspace chip "check manually", neutral tone. |
| V11 dead action-bar props | DONE | `AOMActionBar` takes no arguments; `AOMBarButton` chevron/highlighted removed. |
| V12 Workspace derived data | NOT_DONE | Needs measurement first (no profile taken). |
| V13 opaque role audit | PARTIAL | `.paper` honours `aomOpaqueContent` (7.15); per-callsite audit and preference observation NOT_DONE. |
| V14 Menu Bar keyboard focus | PARTIAL | ↑/↓ on the pane list (7.15); roving focus / VoiceOver selected state on the list only via traits. |
| V15 diff cancellation | DONE | `PaletteDiffJob`: serial queue, generation, exact-text key, cooperative stop in the LCS loop (Myers path for >4M cells still runs to the end). |
| V16 PDF expiry | DONE | `scheduleExpiry` timed to the oldest entry's deadline. |

Structural redesign items (shared Inspector, Automation, Audio, Clipboard, Capture, Window Tiling, Settings search, M06–M36) remain NOT_DONE; R51–R75 not yet applied. Screenshot matrix (84+84) and performance p50/p95: NOT_RUN.

Build and tests: GitHub Actions only (the user's instruction of 2026-11-24).
