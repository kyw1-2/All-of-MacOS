# AOM 6.1 — Integrated plan (Claude · Codex · DeepSeek)

2026-11-17 · base 6.0.0 (`0d48ddf`)

Owner feedback on 6.0: the shell changed, but much of the inside of the app looked the same. Three
plans were made in parallel and merged here:

- **Codex** (MacBook, `~/Documents/Codex/2026-11-16/new-chat-2/outputs/AOm-6.0-UX-review.md`):
  Automation as "a quiet list + a readable run order + edit only what is selected"; four alternatives
  (A Outline Studio, B Recipe Editor, C Mapping Library, D Flow Overview); 6.1 = list summaries and
  scope, no forced expansion, honest Run/Test, predictable action search, branch boundaries.
- **DeepSeek** (Oracle, Telegram reply tg344820023): alternatives A input canvas, B document-first,
  C status-first rows, D recipe gallery; 6.1 = C + one term for Automation + dead-code removal.
- **Claude** (this session): an inventory of every main-window page after 6.0 and a second reference
  sweep by domain — Flow/Session (Focus), iStat Menus 7 (System Tools), Rectangle Pro and Loop
  (Window Tiling), PopClip (Text Actions), Control Center (toggles), Linear (inline banners).

## Decisions

| Item | Source | 6.1 | Notes |
|---|---|---|---|
| Rows say what they do and when they last ran | Codex 6.1-1, DeepSeek C | **Yes** | Second line: input → result · scope · "Ran 3 min ago" (statistics), no script/text content |
| "N of M on · K runs today" over the list | DeepSeek C | **Yes** | From `GestureStatistics.events` |
| No forced expansion; remember per automation | Codex 6.1-2 | **Yes** | Input settings and Options start folded; steps remember what you opened |
| Test → "Run" with the latest model, busy state shared | Codex 6.1-3 | **Yes** | Runs look the trigger up by id; a second run is ignored while one runs; the bar shows "Running…" |
| Action search spans every category while typing | Codex 6.1-4 | **Yes** | Chosen category's matches first, then the rest; the query survives a category change; rows show a mark and one line on what the action does |
| Branch boundaries (If / Otherwise / End) | Codex 6.1-5 | 6.2 | Else is already marked; containers with an End need the outline layout of Codex A |
| One term "Automation" | DeepSeek 1 | **Yes** | "Gestures & Triggers" sheet → "Automation Inputs"; enum raw values unchanged (persisted) |
| Remove `TriggerListPanel` as dead code | DeepSeek 8 | **No** | Verified false: the file holds the live `AddTriggerSheet`, `TriggerEditorCommands`, `MouseTriggerEditor` |
| New Automation sheet | Claude | **Yes** | Wider two-pane sheet: input kinds as a rail (mark, name, what it listens to); the per-kind pickers inside are unchanged |
| Focus hero (ring + large time) | Claude (Flow, Session) | **Yes** | `AOMStatusHeader` becomes a hero card |
| System Tools categories as tabs; tool rows with tinted marks; stars on hover | Claude (iStat, Raycast) | **Yes** | |
| Window Tiling tool cards; layout footprints in the tiling hue | Claude (Rectangle Pro, Loop) | **Yes** | |
| Notices as cards with a tinted glyph | Claude (Linear) | **Yes** | |
| Outline Studio inspector, Recipe sentences, Mapping table columns, Flow view, Input canvas, Recipe gallery | Codex A/B/C/D, DeepSeek A/B/D | 6.2+ | Need executor step events, multi-select and new layout work; not rushed into 6.1 |

## Invariants kept

Five live pages, no page-transition animation, hidden pages idle, Calm colour budget (colour marks
which tool; repeated rows neutral), 13 pt body, system text fields.

## 6.1.1 — "All Applications"

Codex's review flagged it (`scopedTriggers`: "All Applications" = global rules only) and 6.1.0 left it
for 6.2 as "a new feature". The owner asked for it specifically, so 6.1.1 does it: an "All" view
(default, stored in `AOMAutomationShowsAll`), visible scope tabs with counts instead of the toolbar
menu, and a labelled "Applies to" picker in the editor with "Every app" / "Only in <app>".
