# AOM 5.x → 6.0 — UI/UX 대격변 실행안

2026-11-16 22:10 · 기준 HEAD `b27582c` (AOM 5.0 Studio) · 작성: 진행 상황 대조 + 상용 앱 레퍼런스 재해석

이 문서는 **"무엇이 예쁜가"가 아니라 "무엇을 어떤 순서로 뜯어고치면 되돌리지 않고 대격변할 수 있는가"**를 다룬다.
근거 등급을 표기한다: **[코드]** 저장소/실행 상태에서 직접 확인 · **[공식]** 제작사 공식 페이지에서 오늘 확인 · **[조사]** 다른 에이전트(코덱스) 조사 결과 인용(2차) · **[추론]** 필자의 판단.

---

## 0. 결론 10줄

1. **5.0은 이미 나갔다.** `b27582c` 커밋, 설치본 `5.0.0 (2026111601)`, DMG `5.0.0-b2026111601-gb27582c508ec` 생성까지 확인됐다. **[코드]** 되돌리는 안은 선택지가 아니다.
2. **다음 대격변은 토큰 교체가 아니다.** 토큰 규율은 이미 높다 — `AOMSpace` 1,482회 / 원시 padding 24회, `AOMFont` 711회 / 원시 폰트 8회. **[코드]**
3. **진짜 구멍은 세 곳이다**: ① 선택(selection)이 액션 바까지 올라오지 않는다 ② 12개 화면이 크롬은 공유하면서 **본문 원형 선언이 없다**(라이브러리·믹서·캔버스가 같은 밀도) ③ 움직임이 사건이 아니라 곡선 단위로 145줄에 흩어져 있고, 그중 44곳이 토큰을 우회한다. **[코드]**
4. 레퍼런스의 공통 교훈은 하나다: **"경쟁해서 얻지 않은 주의를 요구하지 마라"**(Linear 2026 리프레시, 2026-03-12). **[공식]**
5. Raycast가 유려한 이유는 아이콘이 아니라 **Action Panel = 문맥**이기 때문이다. AOM의 액션 바는 아직 페이지 단위라 그 절반만 가져왔다. **[공식]**
6. 색 정체성(5.0)과 색 절제(레퍼런스 다수)는 충돌이 아니다. **"색은 위치를 알릴 때만, 반복되는 행에서는 중립"**이라는 예산 규칙 하나로 해소된다.
7. 대격변의 단위는 버전 5개다: **5.1 문맥 → 5.2 화면 원형 → 5.3 움직임·재질 → 5.4 색 예산·타이포 → 6.0 Studio II**.
8. 각 단계는 `AOMDesignV2` 플래그 뒤에서 A/B로 들어간다. Linear도 같은 방식(기능 플래그 + 개발 툴바)으로 리프레시를 점진 통합했다. **[공식]**
9. 검증은 이미 있는 하네스로 한다: `--aom-ui-preview` + `--aom-preview-snapshot` + `MainWindowResponsivenessTests` + `AOMPageSwitchBench`. 새 도구를 만들 필요가 없다. **[코드]**
10. 성능 불변식이 디자인보다 우선한다: **방문 페이지 유지, 페이지 전환 무애니메이션, 숨은 페이지 폴링 중단** — 4.0에서 잡은 이 세 가지를 깨는 변경은 채택하지 않는다. **[코드]**

---

## 1. 두 갈래 진행 상황 (대조)

| 축 | 클로드 (5.0.0 실행) | 코덱스 (조사·보고서) |
|---|---|---|
| 산출물 | 커밋 `b27582c` "feat(ui): AOM 5.0 Studio — tool identities, action bar, sidebar header" (24파일, +1,023/−167) **[코드]** | `outputs/AOm-design-report.md` 315줄, `AOm-design-report.html` 1.1MB, `AOm-reference-catalog.csv`, `AOm-Claude-design-brief.md`(46줄), 공식 이미지 6장 **[코드]** |
| 상태 | 커밋·설치(5.0.0 / 2026111601)·DMG(22:05)까지 진행, 22:07 기준 세션 실행 중(앱 + `MainWindowResponsivenessTests`) **[코드]** | 40개 대상 비교표 완성(`{{REFERENCE_TABLE}}` 치환 완료, 0건), 22:10 턴 실패 — 원인 `usageLimitExceeded`(사용량 한도, 재개 시각 11-17 00:16). HTML 로컬 미리보기 검수만 미완 **[코드]** |
| 범위 | 도구 정체성(마크), 액션 바, 사이드바 헤더, 워크스페이스 배너, ⌘K, 설정, HUD **[코드]** | 40개 대상(39앱 + Apple), 3방향 개념 시안(A Quiet Studio / B Glass Desk / C Creator Workbench), 화면별 명세, 검증 시나리오, Claude용 실행 브리프 **[조사]** |
| 비고 | 155 테스트 통과는 **문서 기록**이며 이번 세션에서 재실행 확인 못 함 **[코드]** | 공식 이미지는 6종(Things·Linear·Bear·Dropover·SoundSource·Pixelmator)뿐, 실사용 검증은 없음. 브리프도 "설계 제안이며 승인 지시가 아니다"라고 스스로 한정 **[조사]** |

**세 갈래 중 세 번째가 이 문서다.** 클로드는 5.0을 만들었고, 코덱스는 "무엇을 참고할지"를 40개로 벌려 놓았고, 이 문서는 **"그래서 어떤 순서로, 무엇을 먼저 뜯어고쳐야 5.0을 되돌리지 않고 대격변할 수 있는가"**를 맡는다.

**충돌은 사람이 아니라 단계에서 생긴다.** 5.0은 "도구마다 색을 준다"로 끝났고, 코덱스 브리프의 2번 항목은 "반복 설정 행의 색 사각형을 중립 글리프로 낮추는 **비교안**"이다(일괄 제거가 아니다). 같은 방향이지만 순서를 정하지 않으면 "5.0을 만든 사람과 부순 사람"이 갈린다. 이 문서는 **철회가 아니라 예산**으로, **색보다 문맥을 먼저** 해소한다(§4-A → §4-D).

---

## 2. 코드로 측정한 현재 UI

| 항목 | 측정값 **[코드]** | 해석 |
|---|---|---|
| 메인 창 목적지 | 12개 (`AOMMainTab`: Workspace·Automation·Snapping·Capture·Clipboard·Audio·Tools·Insights·FolderRules·TextActions·Files·Focus) | 크롬("헤더+카드")은 공유하는데 **본문 원형은 선언 없이 각자 구현** — 라이브러리·믹서·캔버스가 같은 밀도를 쓴다 |
| 뷰 코드 규모 | 139파일 / 59,354줄 / 3.0MB, 최대 `ClipboardPanel.swift` 2,903줄 · `AnnotationEditor.swift` 2,857줄 · `HomeDashboardView.swift` 2,222줄 | 대격변의 실제 비용은 **대형 뷰 분해**에 있다 |
| 간격 토큰 | `AOMSpace` 1,482회 vs 원시 `.padding(숫자)` 24회 | 규율 양호 — 손댈 필요 없음 |
| 타이포 토큰 | `AOMFont` 711회 vs `.font(.system(size:` 8회 | 규율 양호 |
| 색 토큰 | `AOMColor` 889회 vs 원시 `Color(...)` 81회 | **드리프트 포켓** — 색 예산 단계에서 정리 대상 |
| 모서리/그림자 | 원시 `cornerRadius:` 43회, `.shadow(` 26회 | 반경 토큰 미적용 구간 존재 |
| 움직임 | 애니메이션 관련 145줄 / 31파일. 그중 `aomAnimation(토큰)` 40 · 원시 `withAnimation` **44** · 직접 `.animation(` 29 · Reduce Motion 분기 19 **[코드]** | 토큰 계층(`AOMMotion`/`AOMMotionToken`)은 있으나 **약 30%가 토큰을 우회**한다 → 곡선 정책이 아니라 **사건 분류표**가 필요 |
| 재질 | material 계열 사용 5곳 | 유리 사용은 이미 절제됨(문제 아님) |
| 액션 바 | `AOMActionBarModel.sections(for: appState: paletteKeys: …)` — **인자에 선택(selection) 없음** | 5.0 바는 "페이지 안내판"이지 "문맥 도구"가 아니다 |
| 창/행 치수 | 최소 980×600, 본문 최대 960, 행 34/44, 액션 바 34, 사이드바 220–300(ideal 236), inspector 260–360 | 수치는 건강함. 문제는 **원형별 예외 부재** |
| 테스트 | 18개 테스트 파일, `StudioIdentityTests`(7), `MainWindowResponsivenessTests`, `AOMPageSwitchBench` | 검증 하네스는 이미 존재 |

**진단 한 줄**: AOM은 "토큰이 없는 앱"이 아니라 **"문맥과 원형이 없는 앱"**이다. 그래서 어떤 리스타일을 해도 3개월 뒤 같은 지적이 돌아온다.

---

## 3. 레퍼런스 — 무엇을 가져오고 무엇을 버리는가

기준: 앱 이름이 아니라 **메커니즘**을 가져온다. 검증 등급을 함께 적는다.

| 앱 | 확인된 사실 | 가져올 메커니즘 | AOM 적용 표면 | 가져오지 않을 것 |
|---|---|---|---|---|
| **Raycast** | 하단 액션 바는 2022 리디자인에서 "숨겨진 ⌘K를 드러내기" 위해 도입, 좌측=현재 위치+토스트, 우측=**현재 문맥의 액션+단축키**. v2(2.12.x)는 Tahoe Liquid Glass 대응 리디자인, Compact mode, **설정 전용 검색**, **액션 패널에서 바로 단축키 지정**. **[공식]** | ① 바 우측은 페이지가 아니라 **선택**이 결정 ② 단축키를 보여줘서 학습시킴 ③ 액션 패널에서 단축키 즉석 지정 | `AOMActionBar` + `AOMBarAction`(§4-A) | 대형 검색창 중심의 단일 진입점(런처가 아닌 앱) |
| **Linear** | 2026-03-12 리프레시: "**경쟁해서 얻지 않은 주의를 요구하지 마라**" — 사이드바를 몇 단계 어둡게, 탭 compact화, 아이콘 축소·**팀 아이콘 배경색 제거**, 테두리 약화·둥글게, 쿨 블루 → **웜 그레이**. 기능 플래그 + 사내 dev 툴바로 점진 통합. **[공식]** | ① 사이드바는 후퇴, 본문이 전면 ② 반복 요소의 색 배경 제거 ③ **웜 뉴트럴 캔버스** ④ 플래그 기반 점진 배포 | `AOMColor` 캔버스(#F5F5F7 → 웜 그레이), 사이드바 대비, `StudioIdentityTests` 색 기준 | 정보 밀도 극대화(이슈 트래커 전용) |
| **Apple HIG / Liquid Glass** | macOS 26의 시스템 재질. 저장소 주석도 "유리는 시스템이 그리고 AOM은 자기 재질을 그리지 않는다"를 원칙으로 삼고 있다. **[코드]** | 유리는 **탐색·일시 조작 층에만**, 콘텐츠는 불투명 | ⌘K, HUD, Quick Access, 진단 drawer | 전 화면 유리(가독성·성능 퇴행) |
| **Things 3 (2026 remaster)** | 여전히 Things 3가 현행, 2026-06 리마스터 영상 자산 존재. 리뷰 공통 평은 "펼쳐지는 애니메이션이 자리를 잃지 않게 한다". **[공식]** | **인라인 확장**: 행에서 바로 필요한 정보만 펼침, 위치 상실 없음 | 자동화 규칙 행, 설정 행, Folder Rules | 과한 모션(모션은 위치 유지에만) |
| **Bear** | 탐색/목록/본문 3단 대비, 내용이 곧 미학. **[조사]** | 리스트는 **내용 → 출처 → 시간** 순 위계 | Clipboard 라이브러리 | 마크다운 편집기 메타포 |
| **Pixelmator Pro** | 중앙 캔버스 + 선택 도구별 설정 분리. **[조사]** | **Workbench**: 캔버스 60–70% + inspector 260–300 | 주석/녹화 편집, 규칙 편집 | 전체 화면 몰입형 편집 |
| **SoundSource** | 앱/볼륨/출력/효과가 **고정 열**. **[조사]** | 행 확장 시 **열이 움직이지 않는다** | Audio 믹서 | 새 믹서 신규 개발(이미 있음) |
| **Dropover / Yoink** | 드래그 대상과 드롭 지점의 즉시 연결, 임시 선반. **[조사]** | 임시 표면은 **결과물 중심 + 지금 가능한 행동만** | Files 선반, Quick Access | 별도 앱 같은 독립 창 |
| **Paste** | 색을 **분류 수단**으로 사용(핀보드). **[조사]** | 색은 "어느 보드인가"에만, 카드 전체 채색 금지 | Clipboard 보드 표시 | 카드 배경 전면 채색 |
| **Swish / Loop** | 작은 유틸의 촉감(햅틱·툴팁·즉시 프리뷰). **[조사]** | 80–120ms 피드백, 실행 전 결과 프리뷰 | 스냅 갤러리, HUD | 장식적 바운스 |
| **Arc** | **2026-12-22 종료 예고**, 후속은 Dia. **[공식]** | (역사적 사례) 공간 탐색의 실패 조건 | — | 사이드바 중심 공간 탐색 신규 도입 |

> 참고: 코덱스 보고서는 39개 앱 + Apple을 비교표로 정리했지만 표 자리표시자가 아직 치환되지 않았다. 위 표는 그중 **AOM 결정에 직접 영향을 주는 9개**만 남기고, 오늘 공식 페이지로 재확인한 사실만 **[공식]**으로 표기했다.

---

## 4. 대격변의 5개 축

### 4-A. 문맥(Context) — 선택이 액션 바까지 올라온다

지금 액션 바는 `sections(for: tab:)`만 받는다. 그래서 "3개 선택됨 → 복사" 같은 말을 할 수 없다. 이건 **문자열 문제가 아니라 배선 문제**다.

```swift
// Views/AOMSelection.swift (신규)
/// A page's current selection, published upward to the action bar.
struct AOMSelection: Equatable {
    enum Kind { case none, clipboardItem, captureItem, audioApp, rule, window, tool }
    var kind: Kind = .none
    var count: Int = 0
    var primaryTitle: String?      // "Text clip", "Safari → HomePod"
}

private struct AOMSelectionKey: EnvironmentKey { static let defaultValue = AOMSelection() }
extension EnvironmentValues { var aomSelection: AOMSelection { get set } }

/// 5.0 액션 모델을 문맥까지 확장한다. 기존 AOMBarAction은 그대로 두고
/// 비활성 이유·파괴성·그룹만 추가한 상위 타입을 둔다(마이그레이션 비용 최소화).
struct AOMBarActionV2: Identifiable {
    let id: String
    let title: String
    let identity: AOMIdentity
    var shortcut: String?
    var isEnabled = true
    var disabledReason: String?     // 비활성이면 이유를 툴팁/보조줄로 보여준다
    var isDestructive = false
    let run: @MainActor () -> Void
}
```

배선 규칙:

1. 각 페이지는 **이미 가진 선택 상태를 그대로** 올린다(이중 보관 금지). `AOMPageHost`가 `aomSelection`을 주입한다.
2. 액션 바 좌측은 `페이지 마크 + 이름` → **선택이 있으면 `마크 + "3 items selected" + 주 행동 1개`**로 바뀐다.
3. 우측은 `주 행동 1 + 보조 2–4`만 노출, 나머지는 `More`(↑↓ ↩ Esc 유지).
4. 비활성은 숨기지 않고 **이유와 함께** 비활성(System Settings·Raycast 공통).
5. 파괴적 행동은 단독 그룹 + 확인 또는 Undo 필수.
6. ⌘K의 의미는 바꾸지 않는다(전역 검색). 단, **패널에서 단축키 지정**은 5.0 범위 밖이므로 별도 검토(Raycast v2 방식).

적용 순서와 기대 효과:

| 순서 | 표면 | 선택 종류 | 대표 문맥 액션 | 근거 파일 |
|---|---|---|---|---|
| 1 | Clipboard | 클립 0/1/다수 | 복사·일반 텍스트로 복사·보드 지정·삭제 | `ClipboardStudioView.swift`, `ClipboardPanel.swift` |
| 2 | Capture | 이미지 0/1/다수 | 편집·복사·Finder·내보내기 | `CaptureStudioView.swift` |
| 3 | Audio | 앱/출력 | 출력 지정·음소거·효과·기본값 복원 | `AudioWorkspaceView.swift`, `AppAudioMixer.swift` |
| 4 | Folder Rules | 규칙 | 미리보기·실행·복제·이력 | `FolderRules/FolderRulesPage.swift` |

### 4-B. 화면 원형(Archetype) — 12개 화면을 6개 원형으로

지금은 12개 페이지가 크롬(헤더+카드)은 공유하면서 본문 구조는 각자 만든다. 그래서 라이브러리·믹서·캔버스가 같은 밀도를 갖고, 그 순간 어느 것도 전문 도구처럼 보이지 않는다.

| 원형 | 구조 | 해당 페이지 | 핵심 규칙 |
|---|---|---|---|
| **Overview** | 상태 배너 + 요약 2–4그룹 + 이어하기 1행 | Workspace, Insights | 카드 6개 초과 금지, 통계는 결정에 쓰이는 것만 |
| **Library** | 목록 열 + 상세 패널, 헤더 내 검색 | Clipboard, Files, TextActions, Tools, Automation | 행 34/44, 타입어헤드, 선택 유지 |
| **Picker** | 타일 그리드 + hover/focus 프리뷰 | Snapping 레이아웃, Capture 모드 | 프리뷰와 실행의 시각 구분 |
| **ControlBoard** | 고정 열 [소스 \| 레벨 \| 출력 \| 효과] | Audio | **행 확장 시 열 이동 금지** |
| **Workbench** | 캔버스 60–70% + inspector 260–300 | Annotation, Recording export, Rule editor, Gesture action editor | 1080 미만에서 inspector → 팝오버 |
| **SingleFocus** | 큰 상태 1개, 크롬 최소 | Focus | 남은 시간·목표·일시정지 외 요소 금지 |

구현은 페이지가 원형을 **선언**하고, 헤더/행/간격이 그 선언에서 파생되게 한다.

```swift
// Views/AOMPageArchetype.swift (신규)
enum AOMPageArchetype { case overview, library, picker, controlBoard, workbench, singleFocus }
extension AOMMainTab { var archetype: AOMPageArchetype { … } }
```

효과: 페이지별 `padding`/`rowHeight` 분기가 사라지고, 새 도구를 추가할 때 원형만 고르면 된다. `AOMSize`에 이미 있는 `inspectorWidth`, `listColumnRange`, `readableWidth` 같은 값이 **처음으로 실제로 쓰인다**.

### 4-C. 움직임(Motion) — 사건 목록을 먼저 정한다

`AOMMotion`이라는 토큰 계층과 Reduce Motion 분기는 이미 있다(40곳이 사용). 문제는 **44곳의 원시 `withAnimation`이 그 계층을 우회**한다는 것, 그리고 **무엇이 움직이면 안 되는지에 대한 정의가 없다**는 것이다. 그래서 값을 바꾸는 게 아니라 사건 표를 먼저 만든다.

| 사건 | 규칙 | 토큰 |
|---|---|---|
| 페이지 전환 | **금지**(즉시) — 4.0 성능 불변식 | — |
| 숨은 페이지/폴링 갱신 | 금지 | — |
| 선택 하이라이트 | 80–120ms, 배경·불투명도만 | `quickCurve` 재정의 |
| 패널/팝오버 열기·닫기 | 160–220ms, 열린 방향으로 복귀 | `panelCurve` |
| 토스트 | in 120ms / out 150ms, 겹치면 스택 | 신규 `toastCurve` |
| 드래그·스냅 | `interactiveSpring()` 유지 | `dragCurve` |
| 성공 피드백 | 색+글리프+햅틱, **바운스 금지**(0.4 bouncy는 과함) | `successCurve` → 0.2 snappy |
| Reduce Motion | 이동·확대 → 즉시 또는 60ms fade | `aomAnimation` 래퍼가 분기 |

추가 규칙: `withAnimation`을 **페이지 전환·스크롤·데이터 갱신 경로에서 금지**하고, 이 금지는 테스트로 잠근다(§7).

### 4-D. 색 예산(Color budget) — 5.0을 지키면서 절제한다

5.0의 도구 색은 옳다(발견성). 문제는 **같은 색이 반복 행·설정 행·카드까지 번진 것**이다.

| 규칙 | 값 |
|---|---|
| 한 화면(뷰포트) 안의 채색 마크 상한 | **8개** |
| 사이드바 | 도구 마크 유지(정체성) |
| 페이지 헤더 | 마크 1개 유지 |
| **반복되는 설정 행** | 중립 글리프(graphite) — 색은 "어느 도구인가"에만 |
| 카드/타일 | 마크만 채색, 카드 배경 채색 금지 |
| 상태 | 의미색 + 글리프 + **단어** (색 단독 금지) |
| 선택·스위치·주 버튼 | 시스템 accent 고정 |
| 캔버스 | 웜 뉴트럴(#F5F5F7 → 예: #F6F5F3 계열) A/B |
| 대비 | 본문 4.5:1, 큰 글리프 3:1, Increase Contrast 경로 유지 |

원시 색 81곳은 이 단계에서 `AOMColor`로 흡수한다(색 하나를 바꿀 때 81곳을 찾아다니지 않기 위해서다).

### 4-E. 타이포·밀도 — 지금 값을 유지하되 리듬을 만든다

- 본문 13pt 유지(이미 통일됨). 제목 3단: 17 / 20 / 22.
- 숫자는 `monospacedDigit` 유지 — 오디오 레벨·통계에서 흔들리면 안 된다.
- 한국어/영문 혼용: 라벨 2줄 상한, 넘치면 **부제를 먼저 생략**(제목 잘림 금지).
- 980×600 최소 창에서 3열 금지, 표는 가로 스크롤 대신 열 우선순위 축소.
- 섹션 간 24, 카드 패딩 12, 행 34/44 — 현행 유지(값이 아니라 **적용 규칙**을 원형에 붙인다).

---

## 6. 실행 계획 (5.1 → 6.0)

각 단계는 `defaults write com.kyw.allofmacos AOMDesignV2 -bool true` 플래그 뒤에서 A/B, 문제 시 즉시 off. 저장소에는 이미 같은 방식의 기본값 플래그가 있다(`AOMAudioAirPlayDirect`, `AOMPasteStackReversed`, `AOMForcePressEnabled` 등). **[코드]**

| 버전 | 목표 | 주요 변경 | 완료 조건 | 되돌림 |
|---|---|---|---|---|
| **5.1 Context** | 선택 → 액션 바 | `AOMSelection` 환경, `AOMBarActionV2`, Clipboard/Capture/Audio/FolderRules 4개 페이지 배선 | 4개 페이지에서 선택 시 좌측 라벨·주 행동·비활성 이유가 바뀌고, ⌘K/단축키 충돌 0 | 플래그 off → 5.0 바 |
| **5.2 Archetypes** | 원형 선언 + 레이아웃 파생 | `AOMPageArchetype`, Workbench(inspector 접힘 규칙), ControlBoard(열 고정), Overview 상한 | 12개 페이지가 6원형 중 하나를 선언, 페이지별 padding 분기 제거 | 페이지 단위 롤백 가능 |
| **5.3 Motion & Material** | 사건→곡선 표 적용 | `AOMMotion`/`AOMMotionToken` 재정의, 원시 `withAnimation` 44곳 흡수, 금지 경로 lint, 유리 표면 화이트리스트 | 페이지 전환 p95 무회귀, Reduce Motion에서 이동 애니메이션 0 | 토큰 값만 되돌림 |
| **5.4 Colour & Type** | 예산 집행 | 원시 색 81곳 흡수, 반복 행 중립화, 웜 캔버스 A/B, 채도 −8~12% "Studio tone" | 화면당 채색 마크 ≤8, 대비 기준 통과, 라이트/다크 스냅샷 승인 | 색 토큰만 되돌림 |
| **6.0 Studio II** | 앱 수준 서사 | 첫 화면 = "이어하기", 도구별 정체성 유지, 키보드 우선 액션 모델, 설정 검색 강화 | 신규 사용자 5–8명 관찰에서 3개 핵심 과업 도달, 문서·CHANGELOG·릴리스 노트 완비 | 메이저라 되돌림 없음(플래그로 5.4 상태 유지 가능) |

의존 관계: **5.1 없이 5.4를 하면 안 된다.** 색만 줄이면 "왜 갑자기 밋밋해졌나"가 되고, 문맥이 붙은 뒤에 줄여야 "조용해졌지만 똑똑해졌다"가 된다.

---

## 7. 검증 하네스 (새로 만들지 않는다)

| 계층 | 도구 | 내용 |
|---|---|---|
| 스냅샷 | `--aom-ui-preview --aom-preview-snapshot <dir>` **[코드]** | 12페이지 × {light, dark} × {980×600, 1280×800, 1680×1050} = 72장 + 핵심 3페이지의 {빈/선택/오류/일시정지} 24장 = **96장 기준선** |
| 픽셀 비교 | `scripts/visual-parity-compare.py` **[코드]** | 단계별 before/after diff. 픽셀 유사도는 행동 동등성이 아님을 문서에 명시 |
| 토큰 위생 | 신규 `DesignTokenHygieneTests` | 허용 파일(`AOMTokens/AOMColor/AOMIdentity/AOMTheme`) 밖의 신규 `Color(`, `cornerRadius:`, `.font(.system(size:` **0건** |
| 문맥 계약 | 신규 `ActionContextTests` | 4개 페이지 × 선택 0/1/다수에서 주 행동·비활성 이유·파괴성 그룹 검증 |
| 성능 | `MainWindowResponsivenessTests`, `AOMPageSwitchBench` **[코드]** | warm switch 무회귀(4.0 보고치 ≈200ms 기준), 숨은 페이지 타이머 0 |
| 접근성 | 수동 체크리스트 | VoiceOver 이름/순서, Full Keyboard Access, Increase Contrast, Reduce Transparency, Reduce Motion, 한/영 UI, 980 폭 |

---

## 8. 위험과 하지 않을 것

**위험**

1. **5.0 직후의 색 축소는 정치적 비용이 크다.** → 예산 규칙(§4-D)으로만 줄이고, 사이드바·헤더 마크는 유지한다.
2. **애니메이션 도입은 4.0에서 고친 스톨을 되살릴 수 있다.** → 페이지 전환·목록 갱신은 애니메이션 금지 목록에 넣고 lint로 잠근다.
3. **대형 뷰(2,903줄) 분해와 디자인 변경을 같은 커밋에 넣으면 회귀 원인 추적이 불가능해진다.** → 분해는 별도 리팩터 커밋, 디자인은 플래그 커밋.
4. **선택 상태 이중 보관.** → 페이지의 기존 선택을 올리는 방식만 허용, 새 `@State` 금지.
5. **코덱스 보고서의 3방향 시안(A/B/C)을 테마 설정으로 오해.** → 하나의 앱 안에서 **역할별 화면 유형**으로만 적용(전역 테마 금지).

**하지 않을 것**

- 전 화면 Liquid Glass / 아이콘만 있는 탐색 / 거대한 환영 배너 / 클릭을 기다리게 하는 진입 애니메이션
- 사용자 작업과 무관한 수치 대시보드
- Arc식 공간 탐색 신규 도입(2026-12-22 종료 예정 제품의 패턴)
- 이미 있는 기능(Clipboard 분할, Audio 믹서, 스냅 프리뷰, 규칙 프리뷰·Undo)을 "신규 기능"으로 재구현

---

## 9. 부록 — 파일 지도와 측정 명령

| 바꾸고 싶은 것 | 고칠 파일 |
|---|---|
| 토큰(간격·반경·행·폰트·모션) | `AllOfMacOS/Views/AOMTokens.swift` |
| 색·캔버스·대비 | `AOMTokens.swift`(AOMColor), `AOMTheme.swift` |
| 도구 정체성·마크 | `AOMIdentity.swift` |
| 액션 바·패널 | `AOMActionBar.swift`, `MainShell.swift:91` (`safeAreaInset`) |
| 페이지 수명·환경 주입 | `AOMPageHost.swift` |
| 셸·사이드바·툴바 | `MainShell.swift` |
| ⌘K | `QuickCommandPalette.swift` |
| 클립보드/캡처/오디오/규칙 | `ClipboardStudioView.swift`, `CaptureStudioView.swift`, `AudioWorkspaceView.swift`, `FolderRules/FolderRulesPage.swift` |
| 검증 | `AllOfMacOSTests/*`, `scripts/visual-parity-compare.py`, `AllOfMacOS/App/AOMPageSwitchBench.swift` |

측정 명령(회귀 감시용):

```bash
# 토큰 위생: 허용 파일 밖 원시 값
grep -rnE "Color\((red|white)|cornerRadius: [0-9]+|\.font\(\.system\(size:" AllOfMacOS/Views --include=*.swift | grep -vE "AOMTokens|AOMTheme|AOMIdentity"
# 움직임 표면
grep -rn "withAnimation\|\.animation(" AllOfMacOS/Views --include=*.swift | wc -l
# 액션 바가 문맥을 받는지
grep -n "sections(for" AllOfMacOS/Views/AOMActionBar.swift
```

---

## 10. 역할 분담 (세 갈래가 겹치지 않게)

| 담당 | 지금 상태 | 다음 일 |
|---|---|---|
| 클로드 (코드 실행) | 5.0.0 커밋·설치·DMG, 세션 실행 중 | **5.1 문맥 배선**(`AOMActionBar.swift` + 신규 `AOMSelection.swift`) → 5.2 원형 → 5.3/5.4 토큰 집행. 작업 단위마다 `AOMDesignV2` 플래그와 스냅샷 기준선 생성 |
| 코덱스 (조사·문서) | 40개 비교표·HTML·CSV·Claude용 브리프 완료, **사용량 한도로 22:10 중단**(재개 11-17 00:16) | 재개 후 ① 96장 스냅샷의 **판정 기준**(무엇이 퇴행인가) 문서화 ② 사용자 관찰 시나리오(5–8명) 설계 ③ 5.1 결과의 문맥 액션 목록 검수 |
| 이 문서 (설계 순서) | 완료 | 5.1 착수 전 `AOMSelection.Kind` 목록 확정, 5.2 착수 전 원형 배정표 확정 |

**겹침 방지 규칙**: 두 에이전트가 같은 파일을 동시에 만지지 않는다. 5.1은 `AOMActionBar.swift` + 신규 파일만, 5.2는 `AOMPageHost.swift` + 페이지별 1개 파일만. 대형 뷰 분해(`ClipboardPanel.swift` 2,903줄 등)는 디자인 커밋과 **다른 커밋**으로 분리한다.

이 문서는 **코드를 변경하지 않았다.** 근거는 위 표의 경로·측정값이며, 외부 사실은 2026-11-16에 공식 페이지로 확인한 것만 `[공식]`으로 표기했다.
