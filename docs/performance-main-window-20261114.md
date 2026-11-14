# 메인 윈도우 버벅임 근본 원인 — 2026-11-14 (3.8.0)

기준: 설치된 3.7.0 / `ff5a152`. 증상: 페이지를 옮길 때마다 멈칫하고, 일부 페이지는 연 직후 스크롤이 끊긴다.

## 측정 방법

1. **설치본 + 접근성 드라이버**: 사이드바 행을 AX로 선택하고, 이어서 AOM 프로세스에만 스크롤 이벤트를 보내면서
   창 제목을 AX로 읽는 데 걸린 시간을 메인 스레드 정지 시간으로 썼다. 페이지 전환 직후 0.3~1.5 s 이상
   멈췄고(1.5 s는 AX 응답 상한), Audio는 전환 직후 스크롤이 최대 1.9 s 멈췄다. 이 방식은 SwiftUI가
   접근성 트리까지 만들게 해서 비용을 부풀린다.
2. **앱 내부 벤치 (`--aom-preview-bench <out.json>`)**: 격리 프리뷰(사용자 프리셋 사본)에서 12개 페이지를
   3회 돌며, 선택을 바꾼 순간부터 메인 런루프가 다시 대기에 들어갈 때까지를 잰다. 접근성은 켜지지 않는다.
   `--aom-preview-bench-only <페이지>`로 한 페이지만 반복할 수 있다. 같은 조건의 릴리즈 빌드끼리 비교했다.
3. 두 방식 모두 `sample`로 메인 스레드 호출 트리를 수집했다.

## 원인

전환 비용의 대부분은 SwiftUI가 새 페이지 전체를 만들고 배치하는 데 쓰였다. 그 위에 AOM 코드가 얹은 부분:

| 원인 | 근거 (메인 스레드 샘플) | 수정 |
|---|---|---|
| Audio 페이지 `SoundEffectsRow`가 화면을 열 때 `NSAppleScript`를 컴파일·실행해 알림 음량을 읽고, 슬라이더 틱마다 AppleScript로 썼다 | AOM 코드 중 최대 942 | 전역 설정 `com.apple.sound.beep.volume`을 읽고, 쓰기는 백그라운드 직렬 큐에서 마지막 값만 반영 |
| Audio Unit 목록을 메인 스레드에서 열거 (번들 로딩 포함) | 103 (+ `CFBundleLoadExecutable` 148) | 백그라운드 `Task.detached` |
| `HardwareCareModel.refreshHelper()`가 `SMAppService.status`(XPC 왕복)를 동기 호출 | 134 | 워커 큐에서 조회 후 메인에 반영 |
| 쓰이지 않는 튜토리얼 앵커가 사이드바·자동화 페이지의 프레임을 계속 측정해 `MainWindow` 상태에 기록 | `TutorialFramePreferenceKey.reduce` 99 + 창 전체 재렌더 | 메커니즘 제거 |
| `MainWindow`와 셸이 뒤로/앞으로 기록을 관찰 → 전환 중 기록 갱신이 창 전체를 중첩 재렌더 | `AOMNavigationHistory.record` 310 (릴리즈) | `MainWindow`는 관찰 안 함, 툴바 버튼만 관찰하는 하위 뷰, 빈 배열 재할당 생략 |
| 새 스크롤뷰마다 `AOMScrollChromePolicy`가 스크롤러를 끄며 페이지 전체를 다시 배치 (전환 1 s 뒤 끊김) | `NSScrollView tile` 122 | 페이지 스크롤뷰를 처음부터 `.scrollIndicators(.never)`로 생성 |
| 자동화 행 64개가 모두 AppState를 관찰 + 행마다 컨텍스트 메뉴 | 선택·검색·토글마다 전 행 재렌더 | 행은 상태를 읽지 않고 `Equatable`, 목록 하나에 `contextMenu(forSelectionType:)` |
| 사이드바가 AppState 전체를 관찰 | `OutlineListCoordinator` 327 | 그리는 값만 받는 `Equatable` 사이드바 |
| 권한 상태(TCC IPC)를 뷰 init·렌더마다 조회 (`@State` 초기값 포함) | `AOMPermission.status` 152 | `AOMPermissionCache` (첫 조회만 동기, 이후 2 s 주기 백그라운드 갱신) |
| `keyCodeToString`이 호출마다 90개 항목 사전을 생성 | 단축키 표시 행마다 | 정적 상수 |
| 페이지가 화면 밖 섹션의 스위치·팝업까지 전부 생성 | `ScrollViewLayoutComputer` 1,209, `AppKitPlatformViewHost` 852 | `AOMPage`와 Window Tiling을 `LazyVStack`으로 |

## 결과

앱 내부 벤치, 릴리즈 빌드, 사용자 프리셋 사본, 빌드 등 다른 부하가 없는 상태. 페이지별 2·3회차 ms.

| 페이지 | 3.7.0 | 수정 후 |
|---|---|---|
| Automation | 465 / 921 | 163 / 437 |
| Window Tiling | 591 / 718 | 231 / 237 |
| Capture | 421 / 496 | 330 / 333 |
| Audio | 290 / 283 | 288 / 295 |
| System Tools | 284 / 287 | 180 / 172 |
| Files | 303 / 297 | 246 / 244 |
| Focus | 347 / 362 | 275 / 281 |
| Workspace | 830 / 374 | 237 / 262 |
| 12페이지 합계 | 9,193 (다른 실행 8,554) | 6,000 |

합계는 같은 조건 실행 기준 35% 감소(3.7.0 두 실행 평균 대비 약 32%). 프리뷰 모드는 오디오·하드웨어 조회를
건너뛰므로 Audio·System Tools의 I/O 수정 효과(설치본에서 Audio 스크롤 1.9 s 정지의 원인)는 이 표에 포함되지 않는다.
Workspace는 측정 빌드에서 지연 스택이었지만, 지연 로딩 전후 차이가 없고 첫 표시 때 스크롤 위치가 한 번 튀어
일반 스택으로 되돌렸다. Workspace 수치 변화는 사이드바·히스토리·권한 조회 수정에서 온 것이다.

## 남은 비용

전환당 150~400 ms는 SwiftUI가 새 페이지와 그 AppKit 컨트롤(스위치, 팝업, 테이블)을 만드는 비용이다.
방문한 페이지를 숨겨 두고 재사용하면 더 줄지만, 페이지마다 선언한 툴바가 합쳐지고 숨은 페이지의 폴링이
계속 돌기 때문에 이번에는 하지 않았다. 다른 앱이 접근성으로 AOM 창을 읽는 동안에는 SwiftUI가 접근성
트리도 만들어 전환 비용이 늘어난다(측정 방법 1).
