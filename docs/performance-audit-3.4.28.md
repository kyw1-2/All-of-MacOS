# 3.4.28 — 메인 창 전면 노출 제거 + 유휴 폴링 감축

대상: 설치본 3.4.27 (build 2026110709) → 3.4.28 (build 2026110710)

## 1. 신고 증상

- 캡처·퀵액세스·텍스트 캡처 같은 오버레이 동작을 시키면 **AOM 메인 창이 앞으로 튀어나온다**.
- 앱이 전반적으로 무겁게 느껴진다.

## 2. 측정 (설치본 3.4.27, 수정 전)

`sample <pid> 5` 로 유휴 상태 메인 스레드를 5초 샘플링했다. 메인 스레드에서 반복적으로 관측된 AOM 프레임:

```
MissionControlOverlayService.start() 의 0.25s 타이머
  → poll()
  → mayProbe()
  → ScreenLock.isLocked   (CGSessionCopyCurrentDictionary)
```

유휴 CPU는 5초 간격 3회 측정에서 **1.2% / 3.3% / 0.7%**였다. 즉 Mission Control 오버레이가 켜져 있으면
앱이 아무 것도 하지 않아도 초당 4회 윈도우 서버 프로브 + 세션 질의를 계속한다.
3.4.26 감사 문서가 "Mission Control 폴링은 이 패치 범위 밖"이라고 남긴 항목이 그대로 남아 있었다.

메인 창 노출의 원인은 `NSApp.activate(ignoringOtherApps: true)` 다. `windowShouldClose` 는 메인 창을
`orderOut` 할 뿐 파괴하지 않으므로 SwiftUI `WindowGroup` 의 창이 살아 있고, 앱 활성화 시 AppKit/SwiftUI 가
그 창을 다시 앞으로 정렬할 수 있다. 같은 원인을 `WindowSwitcherOverlay` 는 이미 주석으로 기록하고
회피하고 있었지만(3.4.10), 캡처·클립보드·파일·알림 경로에는 30곳이 남아 있었다.

## 3. 변경

### 3.1 오버레이 활성화 가드 (신규 `Services/AOMOverlayActivation.swift`)

- `activateForOverlay()`: 활성화 **직전** 메인 창의 가시성을 기록하고, 활성화로 가려져 있던 메인 창이
  드러나면 같은 런루프 턴에서 `orderOut`, 디스플레이 사이클 이후 한 번 더 확인해 되돌린다.
- 판정은 순수 함수 `shouldRestoreHiddenMainWindow(wasVisible:isVisibleNow:)` 로 분리해 창 서버 없이 테스트한다.
- `AppDelegate` 가 관리 창을 `registerMainWindow` 로 등록하므로 "어느 창이 메인인가"를 추측하지 않는다.
- 적용 지점 30곳: SelectionOverlay, QuickAccessOverlay, TextCaptureHUD, ScreenRulerOverlay, PinnedScreenshot,
  AnnotationEditor, RecordingExportEditor, CapturePrintView, ClipboardPanel, ClipboardTextEditorWindow,
  FilesShelf(Panel), FolderRules, FocusModule, MicMuteSection, WindowPicker, FloatingMenus, PaletteLinkRouter,
  ShortcutConflicts, ActionExtended, ActionControlFlow.
- **의도적으로 남긴 곳**: `AppDelegate.showMainWindow()` / `openSettings()` — 사용자가 메인 창을 요청한 경로.

### 3.2 Mission Control 폴링

- 유휴 주기 0.25s → **0.5s**, `tolerance = 주기 × 0.25`.
- Dock 의 `com.apple.spaces.shows-before` 알림을 받으면 4초간 **0.2s 버스트**로 전환해, ✕ 버튼이
  Mission Control 등장 애니메이션과 함께 뜨는 체감을 유지한다.
- 알림이 오지 않는 환경에서도 유휴 0.5s 폴링이 최대 0.5초 안에 발견한다.
- `stop()` 에서 분산 알림 옵저버를 해제한다.

## 4. 검증

- 단위 테스트 `AllOfMacOSTests/OverlayActivationTests.swift`: 가시성 조합 4종 + 폴링 주기 2종.
- 빌드/설치 후 확인: 버전·빌드 번호, 실행 유지, 유휴 CPU 재측정, 캡처 실행 시 메인 창 미노출(수동).

## 5. 이번에 고치지 않은 것 (정직한 범위)

- `@Published` 325개로 인한 SwiftUI 무효화 범위(구조 개편 필요).
- 414파일/148k줄 구조와 대형 파일(`TitleBarWindowSnap` 4,017줄 등)로 인한 빌드 시간.
- 전역 이벤트 모니터 77곳의 단일 멀티플렉스 통합.
- 2026-11-07 17:49 크래시(`EXC_BREAKPOINT`, `_updateConstraintsForSubtreeIfNeeded` 중 AppKit 예외):
  `.ips` 에 예외 메시지가 남지 않아 원인 미확정. 별도 조사 필요.
