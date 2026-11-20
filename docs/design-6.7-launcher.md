# AOM 6.7 — 런치바 화면 스택·메인 창 Now·결함 수정 종합 보고서

작성 2026-11-20 · 기준 6.6.0(`99a9cc1`) → 6.7.0 · 근거: Codex 명세서·종합보고서(2026-11-20, `~/Documents/Codex/2026-11-20/aom/outputs/`), Oracle `/data/work/rea/aom-ux-20261117/report/01–04`, `macutils-20261114/04`, `popclip-202611/01–03`, 제작사 공식 문서(아래 §2).

## 0. 결론

1. 6.6의 핵심 누락은 Codex 지적대로 **"명령 → 대상 → 검토·확인 → 결과"를 한 패널에서 끝내는 화면 스택**이었다. 6.7은 Raycast의 navigation stack(push/pop)과 confirmAlert를 그대로 옮겨, ⌥Space 패널 안에 **7개 화면**(Kill Apps, Uninstall App, Sound Devices, Clipboard History, Window Management, Keep Awake, System Commands)과 **인패널 확인 화면**을 넣었다.
2. Kill Apps·Uninstall App은 Codex 명세(7쪽, 인수 시험 14개)를 기준으로 구현했고, 테스트로 검증 가능한 항목은 `AOM67LauncherTests`(16건)에 넣었다. 실제 키 입력·VoiceOver·강제 종료·휴지통 이동은 실기 확인 항목으로 남는다(§6).
3. 메인 창은 Workspace 첫 화면을 **Now**(실행 중 세션 → 주의 필요 → 최근)로 바꾸고 디렉터리는 **All Tools**로 옮겼다. 메뉴바 패널은 실행 중 세션 행, 1초 갱신, 전원 버튼 제거.
4. Codex 결함 10건 중 **9건 수정**(L1–L5, A1–A5 중 A4는 런치바 범위만), 근거와 테스트는 §4.

## 1. Codex 명세 검증 — 그대로 따른 것과 바꾼 것

| 명세 항목 | 6.7 구현 | 판단 |
|---|---|---|
| 명령 우선 진입(`killapps`, `unistall app`, `앱 종료`, `앱 삭제`) | 루트 명령 행 + 별칭(aliases). 별칭 완전 일치는 제목 접두와 같은 순위 | 그대로 |
| 같은 NSPanel 유지, 메인 창 활성화 0회 | `PaletteAction.Effect` `.push`/`.stay`/`.close`; 화면 이동·종료·검토는 패널 유지 | 그대로 |
| Esc = 한 단계 pop(검색어가 있어도) | `escapeOutcome(query:depth:)` → `.pop` | 그대로 |
| 뒤로 가면 검색어·선택 행 복원 | `PaletteNavigation` 프레임이 `returnQuery`·`returnSelection` 보관 | 그대로 |
| 일반 종료가 기본, 성공은 종료 관찰 후 | ↩ = `terminate()` 후 "Quitting…", 10초 뒤 "Still running · ⌘K to force quit"; 행은 종료 알림에 사라지고 선택은 이웃 행으로 | 그대로 |
| 강제 종료: 이름·경로 확인, 직전 재대조 | 확인 화면 → 같은 PID·같은 경로·같은 번들 ID만 `forceTerminate()` | 그대로 |
| 확인 화면 초기 포커스 = 취소, 키 반복 차단 | **버튼 대신 두 행**(Cancel이 선택된 첫 행, 실행 행은 빨간 선택색). ↩는 `.down` 단계만 받아 반복 입력 무시 | 형태 변경 — 기존 ↑↓/↩ 조작을 그대로 쓰고, 텍스트 필드 포커스(IME)를 잃지 않기 위해 |
| 검토 화면 ↵ = 휴지통 이동 | **↩ = 행 체크 토글, ⌘↩ = "N개 휴지통으로…" → 확인** | 변경 — 체크리스트에서 ↩가 파괴 동작이면 실수 비용이 큼 |
| 보호 앱(AOM·Finder·시스템 호스트) | 목록에 흐리게, "Can't quit from here" 그룹 | 그대로 |
| 다른 사본 실행 중이면 차단 | 검토 진입 시 "Another Copy Is Running", 이동 0건 | 그대로 |
| 부분 실패 분리 | 결과 화면에 실패 항목 행 + 요약(`TrashOutcome.summary`) | 부분 반영 — "남은 항목만 재검토"는 미구현(§6) |
| v1 범위 = GUI 앱 | Dock 아이콘 있는 앱만. 메모리 사용량(phys_footprint) 표시·정렬은 추가 | 추가 — Raycast Kill Process·활동 모니터 관례 |

## 2. 레퍼런스 조사(공식 자료)

| 제품 | 확인한 동작 | AOM 6.7 반영 |
|---|---|---|
| Raycast System Commands (manual.raycast.com/system-commands) | Lock, Sleep, Sleep Displays, Restart, Shut Down, Log Out, Empty Trash(경고 옵션), Eject All Disks, Toggle Hidden Files, Toggle System Appearance, Hide All Apps Except Frontmost, Quit All Apps(경고), Manage Sound Output/Input Devices, Set Volume 0–100%, Toggle Mute/Microphone | System Commands 화면 + 루트 검색 노출; Quit All Apps Except Frontmost(확인), Hide Others; Sound Devices 화면 |
| Raycast API — Navigation / Action.Push / Alert.confirmAlert | ESC가 자동 pop, 1·2번째 액션 = ↵·⌘↵, 되돌릴 수 없는 동작은 confirmAlert, Destructive 스타일 | 화면 스택, 파괴적 액션 빨간색, 인패널 확인 |
| Raycast Applications / Uninstall Applications | 앱 행 액션 패널과 독립 Uninstall 명령이 같은 검토로 합류 | 앱 행 Uninstall… → 같은 패널 검토(6.6은 System Tools로 이동) |
| macOS Tahoe 26 Spotlight (support.apple.com/122868, Apple newsroom 2025-06) | 액션 실행, quick keys(짧은 문자열), Clipboard 브라우즈, 메뉴 항목 검색 | 별칭(quick key 성격), Clipboard History 화면(전체 기록, ↩ 붙여넣기) |
| Codex 비교 27종(Alfred, LaunchBar, 1Password Quick Access, Superhuman, Linear, Things, Craft, Nova, Bear, OmniFocus, Sketch, Pixelmator Pro, Fantastical, Keyboard Maestro, BTT, Hazel, PopClip, Paste, CleanShot X, Shottr, Dropover, Default Folder X, SoundSource, Moom, Rectangle Pro, DaisyDisk) | 보고서 8–10쪽 | 6.7 반영: Superhuman식 푸터 키 힌트(기존), Linear식 선택별 ⌘K(기존), Things식 "원래 앱을 떠나지 않음", Rectangle Pro식 Window Management 화면, SoundSource식 출력 전환, DaisyDisk식 경로·크기 표시 |
| Oracle 03·04 (Raycast 클론 설계) | Kill App·Caffeinate·Uninstall 1급 노출, 파괴적 액션 확인, 44 pt 행 | Kill Apps·Keep Awake(15분–8시간)·Uninstall 화면; 44 pt·52 pt 치수 유지 |

## 3. 6.7에 적용한 것

### 3.1 런치바(⌥Space)
- **화면 스택**: 검색창 왼쪽에 `‹ 화면 이름` 토큰(클릭 = 뒤로), 화면별 placeholder, 푸터 왼쪽에 경로(`Uninstall App › Uninstall Notes`), `esc Back`.
- **Kill Apps**: 메모리 큰 순, 숨김 표시, ↩ Quit(목록 유지), ⌘K Force Quit…/Hide·Unhide/Switch To/Show in Finder, 하단 "Quit All Apps Except <앞 앱>…"(확인)·"Hide All Apps Except <앞 앱>". 앱 실행·종료·숨김 알림으로 실시간 갱신.
- **Uninstall App**: 설치 목록(시스템 앱·AOM 제외, 하위 폴더 앱 포함) → 검토(실행 중이면 "Quit and Review", 번들 ID 일치 체크·이름만 일치 해제, 크기, 폴더별 그룹) → ⌘↩ 확인 → 결과(실패 항목, Open Trash, Done). 판정·스캔·이동은 System Tools와 같은 `CleanupTools`.
- **Sound Devices**: 출력·입력 장치(현재 ✓), Mute, 25/50/75/100%. HAL 읽기는 백그라운드.
- **Clipboard History**: 루트의 최근 20개가 아닌 전체(최대 1000) 검색, ↩ = 앞 앱에 붙여넣기(손쉬운 사용 허용 시), ⌘K Copy/Copy as Plain Text.
- **Window Management**: 반·4분할·3분할·전체 화면 그룹 + Pin/Unpin/Window Switcher.
- **Keep Awake**: 15분·30분·1·2·4·8시간·끌 때까지·화면도 켜기, 외장 디스플레이 규칙 토글.
- **System Commands**: 19개(§2 Raycast 목록 중 AOM이 이미 수행하는 것). Restart…/Shut Down…은 loginwindow의 macOS 자체 확인창을 띄우고, Log Out…/Empty Trash…는 패널 안에서 확인.
- 루트: 화면 명령 7개가 Commands 맨 위(› 표시), 검색 중 System Commands 노출, 빈 검색 Suggestions에 자주 연 앱 복원(L3).

### 3.2 메인 창·메뉴바
- Workspace 기본 보기 **Now**(기억됨): "Running now" 카드 — 녹화(Stop), Keep Awake(남은 시간·Turn Off), 집중 세션(End), 마이크 음소거(Unmute), 클립보드 일시정지(Resume), 자동화 일시정지(Resume). 없으면 한 줄 안내 + Launcher 버튼. 디렉터리는 **All Tools**.
- 메뉴바 패널: "Open Launcher…" 버튼(검색창처럼 보이던 문제), 실행 중 세션 행(녹화·Keep Awake 추가), 1초 갱신(A5), 전원 버튼 제거(종료는 … 메뉴와 ⌘Q).

## 4. 결함 장부(Codex 보고서 12–13쪽 + 이번 확인)

| ID | 내용 | 6.7 | 근거 |
|---|---|---|---|
| L1 | Use Quicklink가 패널을 닫음 | 수정 — `.stay` 효과 | `testL1…` |
| L2 | 하위 폴더 실행 앱 누락 | 수정 — 같은 사본만 제외, 번들 내부 헬퍼는 계속 제외, 스캔 1단계 하위 폴더 | `testL2…` 2건, 기존 `testRunningAppsOutside…` 유지 |
| L3 | 검색으로 연 앱이 빈 검색 추천에 안 나옴 | 수정 — `suggestedApplicationItems()` | 코드 경로 |
| L4 | 작은 화면에서 패널이 경계를 넘음 | 수정 — `size(fitting:)`, 좌표 클램프 | `testL4…`(640×480, 음수 원점) |
| L5 | 등록 실패한 단축키도 안내 | 수정 — `AOMLauncherShortcut.isRegistered`(빈 런치바·메뉴바·Workspace) | `testL5…`. 이 Mac에 Raycast가 실행 중이며 기본값이 ⌥Space이지만, 실제로 어떤 앱이 키를 잡고 있는지는 확인하지 못함 |
| A1 | 폴더 규칙 미리보기 후 편집해도 이전 승인 적용 | 수정 — 미리보기한 규칙과 동일할 때만 Turn On, 다르면 새 미리보기 | 코드 경로 |
| A2 | 늦게 끝난 이전 테스트 결과가 덮어씀 | 수정 — 요청 티켓·파일·규칙 대조 | 코드 경로 |
| A3 | 클립보드 복사 실패를 숨김 | 수정 — HUD "Couldn't Copy" + 사유 | 코드 경로 |
| A4 | Reduce Motion 무시 | 런치바 수정(확대 제거, 페이드 단축). 메인 창 직접 애니메이션은 미점검 | 코드 경로 |
| A5 | 메뉴바 상태가 열린 동안 갱신 안 됨 | 수정 — 1초 폴링, 바뀐 값만 publish | 코드 경로 |
| 추가 | 6.6 앱 행 Uninstall…이 런치바를 떠나 System Tools로 이동 | 수정 — 패널 안 검토 | 명세 시험 14 |

## 5. 빼거나 줄이면 좋을 것(권고, 6.7 미적용 포함)

| 대상 | 권고 | 6.7 |
|---|---|---|
| 메뉴바 전원 버튼 | 엔진 일시정지 옆의 앱 종료는 오조작 위험 | **제거**(… 메뉴·⌘Q 유지) |
| 루트의 Keep Awake 30분·1시간·화면 켜기 행 | Keep Awake 화면으로 이동, 루트에서는 검색 시에만 | **적용** |
| Workspace 첫 화면의 도구 디렉터리 | All Tools로 이동 | **적용**(기본값만 변경, 탭은 유지) |
| 사이드바 Search Everything vs 디렉터리 검색 | 서로 다른 결과를 내는 두 검색 표면 — 하나로 | 미적용(다음 릴리스) |
| 메뉴바 Quick actions 6아이콘 | 런치바·Workspace와 중복; 사용자 고정 0–3개로 축소 | 미적용 — 캡처 진입로로 쓰는 사용자가 있어 사용 데이터 확인 후 |
| 본문 카드 유리 광택·호버 확대 | 6.6에서 요청으로 넣은 것. 긴 목록 가독성은 구분선이 낫다는 Codex 의견 | 미적용 — 설정 › Translucent window로 끌 수 있음 |
| 독립 Insights 페이지 | 활동 기록 안 통계로 | 미적용(IA 변경, 딥링크 이전 필요) |
| 플러그인 장터·AI 채팅·전체 프로세스 관리자 | 이번 범위 제외 유지(Oracle 03 §2와 동일) | 제외 |

## 6. 남은 확인(실기)

- ⌥Space → `killapps` → ↩ 일반 종료, ⌘K → Force Quit… → Cancel/승인, 저장 대화상자 앱.
- `unistall app` → 앱 선택 → (실행 중이면) Quit and Review → ⌘↩ → 휴지통 이동 → Put Back.
- 한글 조합 중 ↩(조합 확정이 행 실행으로 이어지지 않는지), VoiceOver 공지, Reduce Motion.
- 부분 실패 후 "남은 항목만 재검토" 흐름(미구현), 메인 창 페이지 전환 p95(Codex 측정 524 ms; Audio·Automation 첫 렌더 분해는 다음 과제).

미리보기 스크린숏은 `--aom-ui-preview` 격리 실행으로 확인했다(`--aom-preview-launcher --aom-preview-palette-route killApps|uninstallApps|sound|clipboard|windows|keepAwake|system|confirm|review:<앱 경로>`).
