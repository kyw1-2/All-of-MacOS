# [AOM 7.11] All-of-MacOS 수정 및 결함 보완 작업 명세서

> **문서 버전**: 7.11.0-SPEC-FINAL  
> **기준 커밋**: `a8baff798b88` (All-of-MacOS 7.10.0-2026112207)  
> **수신자 / 대상 구현자**: Claude (엔지니어링 에이전트)  
> **발행 주체**: `spec-architect` (협업: `oracle-rea-analyst`, `code-auditor`, `coordinator`)  
> **작업 기준 저장소**: `/Users/kim-yong-woo/All-of-MacOS`  

---

## 0. 개요 및 목적 (Overview & Principles)

본 명세서는 Codex의 최신 작업 지침(`AOM-구현자용-작업명세서.txt`), Oracle 서버 상용 앱 역공학 분석 보고서(Bartender 7, Raycast, AlDente 심층 분석), 그리고 All-of-MacOS 로컬 코드베이스 정밀 감사 보고서를 종합 대조하여 수립된 최종 구현 및 검증 명세서다.

구현자(Claude)는 본 명세서에 규정된 결함 수정 사항과 UX 벤치마크 요구사항을 엄밀히 반영하여 코드를 작성하고, 제6절의 자동화/실기 검증 및 패키징 절차를 완수한 후 배포해야 한다.

### 4대 기본 구현 원칙
1. **사용자 관찰 우선 (Observable Behavior First)**: 내부 구현의 편의보다 실제 사용자가 클릭 및 키보드 조작 시 관찰하는 0-레이스, 0-플리커, 즉각적 피드백을 최우선으로 한다.
2. **비침습성 및 무설치 원칙 (Non-invasive Architecture)**: 타사 앱의 비공개 plist를 강제 변조하거나 root 데몬을 설치하지 않으며, macOS 네이티브 API와 비침습적 오버레이를 지향한다.
3. **파괴적 작업의 인스턴스 정밀도 (Instance-level Safety)**: 강제 종료(SIGKILL)는 PID와 프로세스 시작 시각(tvsec+tvusec)을 이중 검증하여 PID 재사용 레이스를 100% 방지하고 세션 보호 화이트리스트를 엄격히 준수한다.
4. **정직한 시스템 한계 명시 (Honest System Boundaries)**: 비SMC 조건에서 Apple이 허용하지 않는 80% 미만 임의 충전 상한은 억지 구현(가짜 슬라이더/일회성 방전) 대신 공식 '미충족'으로 선언하고 네이티브 80% 단일 토글로 단순화한다.

---

## 1. Kill Process — Raycast 벤치마크 UX 및 안전성 보강

### 1.1 라우트 및 진입점 일원화
- **진입 키워드**: 런처 첫 검색 화면에서 아래 키워드 입력 시 즉시 `.killProcess` 라우트로 진입한다:
  - `kill process`, `killprocess`, `kill`, `killapps`, `kill -9`, `pkill`, `프로세스 강제 종료`, `프로세스 종료`, `강종`, `강제 종료`, `강제종료`
- **일반 종료(`.killApps`)와의 역할 분리**:
  - `killApps`: Dock 일반 GUI 앱 대상 정상 종료(`terminate()`, 저장 기회 제공)
  - `killProcess`: Dock 앱, 메뉴바 전용 앱, 앱 헬퍼, 자식 프로세스, 터미널 CLI 프로세스 전체 대상 즉시 강제 종료(`SIGKILL`)
- **PID 숫자 직접 검색 지원 (P0 결함 수정)**:
  - `PaletteProcesses.Entry`에 PID 정수 문자열 인덱싱 추가 (`String(entry.pid)`).
  - 사용자가 `kill 49201` 또는 `49201`만 입력해도 해당 PID를 가진 프로세스가 최상단에 검색되어야 함.

### 1.2 UX 원칙 (Raycast 벤치마크 완벽 재현)
- **↩ 1회 즉시 강제 종료 (One-key Immediate SIGKILL)**:
  - 선택된 프로세스 행에서 Return(↩) 키 1회 입력 시 확인 팝업/대화상자 없이 즉시 `SIGKILL` 전송.
- **검색어 및 뷰 지속성 (`effect: .stay`)**:
  - 프로세스를 종료해도 검색어와 런처 뷰가 유지됨.
  - 백그라운드에서 `PaletteProcesses.isAlive`를 폴링(0.05초 간격, 최대 10회)하여 종료가 확인되면 해당 행만 목록에서 애니메이션으로 제거(Drop)됨.
  - 행 제거 즉시 인접한 다음 행으로 선택(`selectedID`)이 자동 이동하여, 사용자가 ↩ 연타로 좀비/워커 프로세스를 연속 종료할 수 있어야 함.
- **다중 Return 및 Key Repeat 방지 (`isEnding` 플래그)**:
  - 동일한 `entry.id`에 대해 이미 `forceQuit`이 진행 중일 때는 추가 ↩ 입력이나 키 자동 반복(Key Repeat)을 무시(`isEnding` Set 관리).

### 1.3 한글 IME 조합 Commit 결함 원천 차단 (Critical Bug Fix)
- **현상**: `onKeyPress(.return)` 시 한글 조합을 확정(Commit)하는 순간 `hasMarkedText()`가 `false`로 바뀌며 선택된 행이 의도치 않게 즉시 강제종료됨.
- **해결 명세**:
  - 런처 텍스트 필드의 커스텀 NSTextView/필드 에디터 또는 입력 이벤트 체인에서 '방금 한글 조합이 완료된 Return(IME Commit Return)'인지 판별.
  - 조합 완료를 위한 Return인 경우 행 실행(`primary.action()`)을 가로채고 무시함.
  - 순수하게 목록 항목 실행을 의도한 Return만 `primary.action()`으로 전달.

### 1.4 메모리 안정성 및 버퍼 오버런 방어 (Code Auditor 지적)
- **현상**: `proc_bsdinfo.pbi_name`(32바이트) 및 `pbi_comm`(16바이트)이 고정 바이트 배열로 null-종단이 보장되지 않아 `String(cString:)` 호출 시 버퍼 오버런 발생 위험.
- **해결 명세**:
  ```swift
  // PaletteProcesses.swift bsd() 수정
  let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
      let ptr = raw.bindMemory(to: CChar.self).baseAddress!
      let len = strnlen(ptr, MemoryLayout.size(ofValue: info.pbi_name))
      return String(data: Data(bytes: ptr, count: len), encoding: .utf8) ?? ""
  }
  let comm = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
      let ptr = raw.bindMemory(to: CChar.self).baseAddress!
      let len = strnlen(ptr, MemoryLayout.size(ofValue: info.pbi_comm))
      return String(data: Data(bytes: ptr, count: len), encoding: .utf8) ?? ""
  }
  ```

### 1.5 프로세스 목록 갱신 안정화 (Polling Jitter 방지)
- `loadProcesses()`가 3초마다 전체 배열을 무조건 교체하지 않고, 살아있는 기존 엔트리를 유지하면서 변경된 엔트리만 diff로 갱신하여 키보드 탐색 중 선택 위치가 튀지 않도록 함.

### 1.6 세션 보호 화이트리스트 확장
- 기존: `loginwindow`, `WindowServer`, `Dock`, `Finder`, `SystemUIServer`, `ControlCenter`, `WindowManager`, `NotificationCenter`, `MenuBarAgent`, `launchd`, `TextInputMenuAgent`, `universalaccessd`, AOM 본체.
- **필수 추가 대상 (사용자 세션 크래시 방지)**:
  - `cfprefsd` (사용자 환경설정 데몬)
  - `tccd` (권한 관리 데몬)
  - `securityd` (키체인/보안 데몬)
  - `distnoted` (분산 알림 데몬)
  - `Spotlight`, `corespotlightd`
- 보호 대상 프로세스는 리스트에서 자물쇠(`lock`) 아이콘 표시, 행 비활성화(dimmed), ↩ 입력 시 "keeps your session running" 안내와 함께 종료 시도 차단.

---

## 2. 날씨 — 단위 변환 및 메뉴바 표시 엣지 케이스 보완

### 2.1 표시 포맷 및 단위 변환
- **단위 지원**: 섭씨(°C) ↔ 화씨(°F) 상호 즉시 변환.
  - 기온 / 체감 / 최고 / 최저: `°C = (°F - 32) * 5/9`, `°F = °C * 9/5 + 32`
  - 풍속: `km/h = mph * 1.609344`, `mph = km/h / 1.609344`
- **오프라인 / 캐시 불일치 해결 (Code Auditor 지적)**:
  - 설정에서 단위를 변경했을 때, 네트워크 연결이 없거나 API fetch가 실패(`WeatherError.offline`)하더라도 현재 캐시된 `self.reading`을 즉시 `converted(to: newUnit)`으로 인메모리 변환하고 `UserDefaults`에 저장.
  - 앱 재시작 시 오프라인 상태여도 사용자가 선택한 새 단위로 올바르게 표시되어야 함.
- **접근성(VoiceOver) 음성 안내 개선**:
  - `reading`이 존재하더라도 `problem == .offline`인 경우 "오프라인 캐시 데이터"임을 음성 레이블에 포함하여 사용자에게 상태를 명확히 고지.

### 2.2 메뉴바 표시 항목(Fields) 순서 및 설정 UI 점프 방지
- **기본 제공 필드 6종**:
  1. 현재 기온 (`temperature`)
  2. 체감 온도 (`feelsLike`)
  3. 오늘 최고/최저 (`highLow`)
  4. 오늘 강수확률 (`rainChance`)
  5. 습도 (`humidity`)
  6. 풍속 (`wind`)
- **설정창(`MenuBarWeatherPane`) UI 점프 해결**:
  - `orderedFields`를 즉시 리밸류에이션하지 않고, 체크된 항목 리스트와 미체크 항목 리스트를 분리하여 상하 이동 버튼(`chevron.up` / `chevron.down`)을 눌렀을 때 마우스 커서 밑의 버튼 위치가 튀지 않도록 애니메이션 및 식별자 안정화.
  - `UserDefaults` 로드 시 `Set`을 통한 중복 항목 제거 및 필터링 적용.

### 2.3 메뉴바 텍스트 길이 축약(`line(..., limit:)`) 경계 조건 개선
- **단일 필드 초과 방어**:
  - `while shown.count > 1` 루프 이후에도 만약 `shown[0]` 자체의 길이가 길 경우 글자 단위로 자르고 말줄임표(…)를 추가하는 안전장치 마련.
- **폭(Width) 기준 레이아웃 최적화**:
  - 단순 글자수(30자) 기준 외에, 한글/특수문자의 시각적 폭을 감안하여 노치나 인접 메뉴바 아이콘을 침범하지 않도록 최대 표시 개수를 우선순위 역순으로 지능적 탈락시킴 (후순위 항목부터 제거, 툴팁에는 전체 내용 보존).
- **빈 도시(`city == nil`) 아이콘 패딩 버그 수정**:
  - `city == nil` 또는 `fields.isEmpty`일 때 `button.imagePosition`을 `.imageOnly`로 명시적 전환하여 불필요한 공백 패딩 제거.

---

## 3. AOM 기능 하위 메뉴 — 패널 및 Workspace 인터랙션 보완

### 3.1 기능별 하위 명령 정의 및 즉시 실행 구조
- 본체 메뉴바 패널 및 Workspace 대시보드 카드에서 공통 호출되는 하위 명령:
  - **화면 캡처 (`AOMFeatureMenus.capture()`)**:
    - 영역 캡처 (`capture.area`) — `closesPanel: true`
    - 창 캡처 (`capture.window`) — `closesPanel: true`
    - 전체 화면 캡처 (`capture.fullscreen`) — `closesPanel: true`
  - **클립보드 (`AOMFeatureMenus.clipboard()`)**:
    - 기록 열기 (`clipboard.open`) — `closesPanel: true`
    - 수집 일시정지 / 재개 (`clipboard.pause` / `clipboard.resume`) — `closesPanel: false`
  - **잠자기 방지 (`AOMFeatureMenus.keepAwake()`)**:
    - 30분 (`awake.30`) — `closesPanel: false`
    - 1시간 (`awake.60`) — `closesPanel: false`
    - 타이머 종료 (`awake.off`, 활성 시만 노출) — `closesPanel: false`

### 3.2 패널 닫힘(`closesPanel`) 최적화 및 윈도우 전환 핸드오프
- **200ms 하드코딩 지연 제거 (Code Auditor 지적)**:
  - 기존의 `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2)` 제거.
  - `capture` 계열: 패널의 `orderOut`이 완료된 직후(`CATransaction.setCompletionBlock` 또는 동기적 윈도우 숨김) 즉시 캡처 코디네이터 호출 (불필요한 대기 데드타임 제거).
  - `clipboard.open`: `AOMOverlayCoordinator`를 통해 메뉴바 패널에서 클립보드 패널로 **직접 표면 전환(Hand-off)**하여, 타사 앱으로 포커스가 튀었다가 돌아오는 플리커 현상 원천 차단.

### 3.3 실시간 상태 동기화 (Reactive Binding)
- `AOMMenuBarPanelModel`이 수동 `refresh()`에만 의존하지 않고, `KeepAwakeService.shared` 및 `ClipboardStore.shared`의 변경 사항을 Combine(`cancellables`)으로 구독.
- 패널을 열어둔 상태에서 외부 단축키로 잠자기 방지가 켜지거나 시간이 경과해도 남은 시간(`keepAwakeMinutesLeft`) 및 토글 UI가 실시간으로 자동 갱신되어야 함.

### 3.4 패널 기하 구조 및 화면 하단 경계 클램핑
- 하위 메뉴가 전개되어 패널 높이가 증가할 때(`fitToContent()`), `screen.visibleFrame.minY` 경계를 확인하여 패널 하단이 화면 밑으로 잘려 나가지 않도록 오프셋 클램핑 보정.
- Bartender 7 벤치마크 반영: 장기적 플로팅 Bar 확장을 대비하여 모든 메뉴바 아이템에 고유 안정 식별자 `MenuBarItemID(bundleID: String, key: String)` 체계를 적용.

---

## 4. 메뉴바 아이콘 재클릭 닫기 — 이벤트 레이스 방지

### 4.1 트랙패드 탭(Tap-to-click) 및 초고속 클릭 레이스 해결 (Critical Bug Fix)
- **현상**: `AOMStatusPanelController.isIconPress`가 `buttonsDown != 0`을 필수로 요구하여, 트랙패드 탭 시 마우스 업이 먼저 일어나 마우스 버튼이 눌려있지 않은 상태(`buttonsDown == 0`)로 `close()`가 호출됨. 이로 인해 재오픈 차단(`reopenBlockedUntil`)이 설정되지 않아 패널이 닫히는 대신 **즉시 다시 열리는 플리커/재열림 결함** 발생.
- **해결 명세**:
  - `buttonsDown != 0` 조건을 필수로 요구하지 않고, 패널이 열려 있는 상태에서 '최근 마우스 위치가 AOM 아이콘 영역 내부'에 있었는지를 검사.
  - 탭 클릭으로 발생한 마우스 업/다운 시각 윈도우(0.3초) 내의 상태 전환을 추적하여, 탭 클릭으로 인한 `statusItemClicked` 트리거를 '닫기'로 정확히 흡수(`consumeIconPressClose`).

### 4.2 인접 메뉴바 아이콘 클릭 오인 방지
- `anchor.insetBy(dx: -3, dy: -3)` 좌표 확장 마진을 제거하거나 수평 마진을 0으로 축소하여, AOM 아이콘 바로 옆의 Control Center나 타 메뉴바 아이콘을 클릭했을 때 AOM 패널의 재열기가 부당하게 차단되는 오작동 방지.

### 4.3 메인 윈도우 포커스 탈취(Focus Stealing Bug) 완벽 차단
- **현상**: 패널이 닫힐 때 `panel.orderOut(nil)`을 호출하면 AppKit이 `NSApp.windows`에서 백그라운드에 남아있던 `AOMMainWindow`를 자동으로 다음 키 윈도우로 승격시켜 화면 전면으로 끌어올림.
- **해결 명세**:
  - 패널이 열릴 때 직전 활성 앱(`NSWorkspace.shared.frontmostApplication`)을 기억.
  - 패널이 닫힐 때 `AOMOverlayActivation.putBack`을 실행하여 직전 작업 중이던 타사 앱으로 포커스를 명시적으로 복원하고, AOM 메인 윈도우가 전면으로 튀어나오는 현상을 원천 억제.

### 4.4 `AOMOverlayCoordinator` 라이프사이클 누수 해결
- `close()` 시점에 반드시 `AOMOverlayCoordinator.shared.didDismiss(.menuBarPanel)`를 호출하여 오버레이 상태를 정상 해제.

---

## 5. 배터리 충전 제한 — 비SMC 범위 실현 가능성 및 예외 처리

### 5.1 비SMC 하위 상한(<80%) 실현 가능성 최종 판정 (Codex 명세 §5 준수)
- **판정 결과**: **미충족 (Unmet / Not Supported by macOS Non-SMC Native API)**
- **기술적 근거 (Oracle REA 분석 및 라이브 코드 검증 완료)**:
  1. **Apple Native PowerUI의 한계**: macOS 15 Sequoia / Apple Silicon 환경의 네이티브 충전 제한 프레임워크(`/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI`, `PowerUISmartChargeClient`)는 **80% 단일 프리셋만 지원**하며, 80% 미만의 임의 상한선(60%, 70% 등) 지정 시 `setMCLLimit:error:` API 수준에서 에러를 반환하며 거부됨.
  2. **AlDente의 80% 미만 및 Discharge 메커니즘**: AlDente가 제공하는 60/70% 임의 상한 및 강제 방전(Discharge)은 Apple의 네이티브 API가 아닌, root 권한으로 상주하는 특권 헬퍼(`com.apphousekitchen.aldente-pro.helper`)가 Apple Silicon의 Type-C Hardware Power Management (`AppleHPMDevice`) 컨트롤러 레지스터(0~255)를 직접 조작하거나 Intel SMC 키를 수정하기 때문에 가능한 것임.
  3. **AOM 제약 조건**: AOM은 사용자 공간에서 실행되는 비침습적 앱이며 root 데몬을 설치하지 않고 SMC를 직접 조작하지 않으므로, 80% 미만의 임의 충전 상한은 구현할 수 없음.
  4. Codex 명세 §5에 따라 슬라이더 범위 확장, 가짜 설정 저장, 일회성 방전을 완료로 포장하지 않고 **공식 '미충족'으로 보고**함.

### 5.2 AOM 제품화 방향 및 UI/로직 개편
- **단일 토글화**:
  - 50~100% 임의 슬라이더를 완전히 배제하고, **"80% 배터리 보호 제한 (macOS Native)" 단일 On/Off 스위치**로 단순화.
- **`HardwareCareModel` 모드 매핑 결함 수정 (Code Auditor 지적)**:
  - `current?.percent == 80` 하드코딩으로 인해 발생하는 상태 단절을 수정하고, `native.state().enabled` 여부를 기준으로 `limit80` 상태를 정확히 동기화.
- **`NativeChargeLimit.disableLimit()` 예외 처리 수정**:
  - `disableMCL:` 호출 후 `state()` 조회 시, 제한이 꺼진 상태에서 시스템이 반환하는 0 또는 255 값에 대해 `(80...100)` 가드가 throw를 발생시키지 않도록 가드 조건 완화 (`enabled == false`일 때는 percent 범위를 엄격 검사하지 않음).

### 5.3 비지원 환경 및 타사 앱 공존 예외 처리
- **미지원 하드웨어/OS 처리**:
  - `isMCLSupported == false`인 경우(M1/M2/M3 일부 모델 및 이전 OS) UI 스위치를 비활성화하고, "현재 Mac 기종 또는 macOS 버전에서는 네이티브 충전 제한을 지원하지 않습니다"라는 안내 툴팁 노출.
- **AlDente 공존 충돌 방지**:
  - 시스템에 AlDente 특권 헬퍼 프로세스(`com.apphousekitchen.aldente-pro.helper`)가 구동 중인지 확인하고, 감지 시 충돌 방지를 위해 안내 문구를 노출하고 AOM의 충전 제한을 양보(비활성화 권고).

---

## 6. 검증 체크리스트 및 실기 테스트 절차 (Verification & QA)

### 6.1 자동화 단위 / 회귀 테스트 항목
구현자는 아래 항목에 대한 단위 테스트(`AllOfMacOSTests`)를 작성하거나 통과시켜야 한다:
1. `PaletteProcessesTests`:
   - `bsdinfo` 바이트 배열의 안전한 문자열 변환 및 버퍼 오버런 방지 검증.
   - PID 숫자 검색어 매칭 검증 (`String(entry.pid)`).
   - PID 재사용(시작 시각 불일치) 시 `Outcome.changed` 반환 및 SIGKILL 차단 검증.
   - 보호 프로세스(AOM, Finder, Dock, WindowManager, cfprefsd, tccd, securityd 등) 종료 차단 검증.
2. `MenuBarWeatherTests`:
   - 섭씨 ↔ 화씨 상호 변환(`converted(to:)`) 수학적 정확성 (20°C ↔ 68°F, 0°C ↔ 32°F, 풍속 단위 변환).
   - 오프라인 상태에서 단위 변환 시 캐시 및 `reading`의 즉시 동기화 검증.
   - `line(..., limit: 30)` 긴 텍스트 생략 및 경계 조건(단일 항목 초과, 빈 도시 패딩) 검증.
3. `AOMStatusPanelControllerTests`:
   - 트랙패드 탭(`buttonsDown == 0`) 환경에서 `consumeIconPressClose`의 정확한 차단 플래그 검증.
   - 인접 메뉴바 아이콘 좌표 히트테스트 배제 검증.

### 6.2 항목별 실기 테스트 시나리오 및 판정 기준

| 절 | 테스트 항목 | 조작 절차 (사용자가 누르는 곳) | 기대 관찰 결과 (합격 기준) |
|---|---|---|---|
| **§1** | **Kill Process** | 1. 테스트용 GUI 앱 및 터미널 프로세스 2개 구동<br>2. 런처에 `kill` 또는 PID 입력<br>3. 목록에서 대상 선택 후 Return(↩) 1회 입력<br>4. 한글 검색어 입력 직후 Return 입력 | - 확인창 없이 선택 프로세스 즉시 SIGKILL 종료<br>- 검색창과 런처가 닫히지 않고 유지(`effect: .stay`)<br>- 종료된 행만 부드럽게 제거되고 다음 행으로 선택 자동 이동<br>- 한글 조합 완료 Return으로 인한 오종료가 전혀 없을 것 |
| **§2** | **날씨 메뉴바** | 1. 설정 > Menu Bar > Weather 진입<br>2. 단위 °C ↔ °F 전환<br>3. 표시 필드 체크 및 순서(↑↓) 변경<br>4. 네트워크 Wi-Fi 끄고 단위 변경 | - 메뉴바에 실시간 포맷 반영 (`☀ 20°C · 습도 64%`)<br>- 순서 변경 시 설정 UI 버튼이 튀지 않음<br>- 오프라인에서도 변환된 단위가 즉시 메뉴바와 캐시에 반영됨<br>- 빈 도시일 때 메뉴바 아이콘 앞뒤 불필요한 패딩이 없음 |
| **§3** | **AOM 하위 메뉴** | 1. AOM 본체 메뉴바 아이콘 좌클릭<br>2. 패널 내 '화면 캡처', '잠자기 방지', '클립보드' 본문 클릭<br>3. '잠자기 방지 > 30분' 선택<br>4. '화면 캡처 > 창 캡처' 선택 | - 본문 클릭 시 하위 메뉴만 펼쳐지고 기능이 오작동하지 않음<br>- 잠자기 방지 30분 실행 시 잔여 시간이 즉시 패널에 표시됨<br>- 캡처 선택 시 200ms 지체 없이 패널이 닫히며 즉시 캡처 크로스헤어 전환<br>- 외부 단축키로 상태 변경 시 패널이 열려있어도 실시간 갱신 |
| **§4** | **아이콘 재클릭 닫기** | 1. AOM 메뉴바 아이콘 좌클릭 (패널 열림)<br>2. 같은 아이콘을 트랙패드 탭으로 다시 클릭<br>3. 외부 앱(Safari, Xcode 등) 작업 중 아이콘 클릭 닫기 10회 반복 | - 두 번째 클릭 시 패널이 잠깐 닫혔다 다시 뜨는 플리커 없이 깔끔하게 닫힘<br>- 3회 연속 클릭 시 '열림 → 닫힘 → 열림'으로 1회 클릭=1회 전환 정확 일치<br>- 패널이 닫힐 때 백그라운드의 AOM 메인 창이 포커스를 가로채지 않고 직전 앱 유지 |
| **§5** | **배터리 충전 제한** | 1. 시스템 설정/AOM 배터리 패널 진입<br>2. 네이티브 80% 제한 스위치 On/Off<br>3. `isMCLSupported` 비지원 환경 확인 | - 80% 단일 스위치로 정확한 네이티브 MCL 호출 및 확인<br>- 비SMC 하위 상한(<80%)은 미지원으로 정직하게 표기<br>- 비지원 기종/OS에서 스위치 비활성화 및 명확한 안내 문구 표시 |

### 6.3 릴리즈 빌드, 서명, DMG 패키징 및 최종 검수
1. **테스트 및 빌드**:
   ```bash
   bash scripts/run-tests.sh
   bash build-and-sign.sh
   ```
2. **DMG 패키징 및 설치**:
   ```bash
   bash scripts/publish-dmg.sh --from-build
   ```
3. **설치본 검증**:
   - `/Applications/All of MacOS.app`을 업데이트하고 실행.
   - 프로세스 경로, 버전(`7.11.0`), 빌드 번호, AOM Dev 서명 및 소스 리비전을 최종 확인.
   - 1~5절 대표 시나리오를 설치본 환경에서 최종 실기 검수.

---
*본 명세서는 Codex의 작업 기준과 Oracle 상용 앱 역공학 실측치 및 AOM 코드 감사를 완벽히 조화시킨 최종 지침이며, 구현자는 즉시 착수하여 코드 수정 및 검증을 완료할 것.*
