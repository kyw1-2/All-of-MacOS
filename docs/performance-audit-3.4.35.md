# AOM 3.4.35 CPU / wake-up 독립 감사

기준: `01ed7e1da590551f61d2142e1314d1da83974838` (3.4.35 / 2026110805).
작업 브랜치: `fix/cpu-audit-3.4.35`. 검토 기준은 설치된 3.4.35, 배포 대상은 3.4.36 / 2026110806.

## 확인 범위와 근거

- 전체 Swift 소스의 타이머, 반복 애니메이션, 입력 resolver 호출을 검색하고 주요 경로를 직접 검토했다. 변경 후 앱 Swift 파일은 450개다. 모든 기능의 실제 장치 동작이나 모든 CPU 병목을 검증했다는 뜻은 아니다.
- GitHub latest가 3.4.35임을 확인했다. 릴리즈 태그 자체는 재현 가능한 소스 출처를 보장하지 않는다고 명시한다. 별도로 설치 앱 Info.plist의 `AOMSourceRevision`이 위 커밋이고 `AOMSourceDirty=false`임을 확인했다.
- 설치 프로세스 PID 6675를 10초간 `sample`로 관찰했다. 보고서 헤더는 3.4.35 / 2026110805이며 main thread 관측은 2,902개였다. `AppAudioEngine.syncActiveProcesses`, `processObjectsByOwner`/`resolveOwner`, `WindowPinningService.tick`, `MissionControlOverlayService.poll` 경로가 관측되었다. 창 고정 캡처도 실행 중이었다. 이는 통제된 유휴 벤치마크가 아니며 프레임별 표본 수를 합산해 CPU 비율로 해석하지 않는다.
- 사용자가 제공한 257개 xctrace 표본의 원본 trace는 이 작업에 제공되지 않았다. 실행 중 스레드만 수집하는 Time Profiler에서는 적은 표본 수가 짧은 녹화 시간과 같은 의미가 아니다. 녹화 구간, 스키마, 이벤트 수를 함께 확인해야 한다.

## 후보별 판정과 수정

| 후보 | 독립 확인 | 반영 |
|---|---|---|
| SystemToolsModel 4초 | 빠른 경로에도 디스플레이, CoreAudio, 환경설정, 파일 속성 조회가 있다. 느린 subprocess 경로는 이미 30초 throttle이므로 4초마다 모두 실행된다는 해석은 틀리다. | 창별 가시성으로 수명 제어. 오디오·화면·접근성·전원·앱 활성화·외관 알림을 150ms 단위로 합쳐 갱신. 오디오 알림은 오디오 항목만 읽어 볼륨 변경 중 전체 디스플레이 조회가 반복되지 않게 함. 미지원 알림 항목은 15초 보조 폴링, tolerance 3초. 화면 이탈 시 알림·보조 폴링·지연 재조회 취소. |
| HardwareCareModel 3초 | 센서는 worker queue에서 읽지만, 가려진 WindowGroup이 유지되면 onDisappear가 보장되지 않는다. 변하지 않은 battery 상태도 발행했다. | 실제 호스트 창이 보일 때만 수요를 유지. 8초 / tolerance 1.6초, 보일 때 즉시 읽기. 같은 battery 값 발행 제거, 종료 후 늦게 도착한 결과 폐기. 하드웨어 제어 lease 10초와 안전 정책은 유지. |
| Mission Control 0.5초 | idle fallback과 Dock 알림 기반 0.2초 burst가 이미 있다. | 시스템/디스플레이 절전 및 비활성 세션 중 타이머 자체를 중단. 여러 중단 조건을 모두 해제해야 재개. 평상시 0.5초 fallback은 유지하여 비공개 Dock 알림 누락으로 기능이 사라지지 않게 했다. |
| MicMute 0.25초 | 상시 타이머가 아니다. 실제 push-to-talk 중 누락된 key-up을 보완한다. | 간격과 안전 동작 유지. CPU 주범으로 분류하지 않는다. |
| 트리거 목록 / material | 목록은 이미 SwiftUI List다. `displayedTriggers`가 body에서 여러 번 필터·정렬되며 카테고리마다 재계산된다. material의 GPU 기여율은 미측정이다. | body당 한 번 계산한 결과 재사용. 선택/삭제 실행 시에는 최신 모델을 읽는다. material은 근거 없이 제거하지 않았다. |
| 키 입력 / Set | 일반 key-down은 등록 목록 전체를 resolver에 전달한다. 지적된 Set 생성은 일반 key-down이 아니라 Secure Input의 후보 계산 경로다. | 등록/편집 시 chord 인덱스를 구축. key-down은 해당 chord만 resolve하며 앱/그룹 우선순위는 계속 실시간 평가. Secure Input도 chord별 후보만 확인하므로 chord 수 × 전체 등록 수의 반복 필터를 제거. |
| 계측 | 실행 시간과 빈도를 분리할 표식이 없었다. | opt-in signpost 추가. 입력 내용, 창 제목, 앱 ID는 기록하지 않는다. |

## 추가 발견과 수정

- **SystemStatusMonitor**: 2초 CPU/메모리 갱신과 10초 디스크/네트워크/배터리 조회도 창을 숨겼을 때 중단하도록 연결했다.
- **VPN sheet**: 2초 scutil/4초 Tailscale 상태 조회 역시 실제 창 가시성을 따른다. 연결·해제 작업 자체의 완료 확인은 지속한다.
- **오디오 앱 소유자 탐색**: 5초 owner cache의 miss마다 모든 실행 앱의 bundle ID/경로를 다시 읽었다. 한 sweep에서 첫 fallback 때만 앱 메타데이터 목록을 만들고 공유한다. 기존 TTL·소유자 우선순위·모호한 매칭 거부는 유지한다. 오디오 DSP, 버퍼, HomePod 전송, mute/tap 경로는 변경하지 않았다.
- **잘못된 전역 가시성 의존 방지**: 새 reader는 자기 창에만 연결된다. 다른 플로팅 패널이 보인다고 숨긴 시스템 도구 화면의 센서가 재개되지 않는다. 숨김·가림·최소화·분리 시 수요를 균형 있게 해제한다.

정적 주기만 보면 시스템 도구 보조 타이머는 분당 15회→4회, 센서는 분당 20회→7.5회다. 이는 이벤트·즉시 갱신·tolerance를 제외한 **예약 빈도**이며 CPU 감소율이 아니다.

## 검증

- 핵심 회귀 테스트: **54개 통과, 실패 0**. 새 6개 테스트가 포함된다. 128개 트리거를 240가지 chord/scope 조합으로 기존 resolver와 대조하고, 편집·해제 시 인덱스 무효화, 절전 조건 중첩, 호스트 창별 수요 해제, 숨겨진 모델의 무조회·무발행, 오디오 소유자 모호성 처리를 확인했다.
- signpost 스모크 검증: 실제 소스와 SHA-256이 같은 helper를 opt-in으로 실행하고 15초 attach trace를 수집했다. **930개 이벤트(Begin 465 / End 465)**가 export되었다. 캡처 경계가 interval 중간일 수 있으므로 완결된 interval 465개라는 뜻은 아니다. 첫 8초 launch trace에서는 유효 표식이 없었고 프로세스가 제한 시간 종료 시 SIGKILL로 끝났으며, 성공 근거로 세지 않는다.
- 빌드 과정에서 기존 `DoublePressGateTests`가 순수 함수 `AOMUIVisibility.isVisible`의 MainActor 격리 때문에 컴파일되지 않는 문제가 드러났다. 이 함수는 전달받은 Bool만 사용하므로 `nonisolated`로 명시했다.
- 전체 회귀 테스트: **2,556개 실행, 9개 건너뜀, 실패 0개** (205.419초; `work/full-tests.log`). 별도 DSP 9개 및 OCR 2개를 포함한 기존 제외 항목은 이번 전체 결과에 포함하지 않는다.
- 릴리즈 빌드: macOS `swift build -c release --scratch-path ../release-build -j 2` **성공 (403.74초)**. 컴파일 경고는 있으나 오류 없음 (`work/release-build.log`).

## 계측 사용법과 남은 검증

`AOM_PERFORMANCE_TRACE=1`로 테스트 빌드를 시작하고 Instruments의 Time Profiler에 Points of Interest를 추가한다. 일반 실행에서는 signpost 상태를 만들지 않는다. subsystem은 `com.kyw.allofmacos`, category는 `PointsOfInterest`다.

표식: `Keyboard.handleInput`, `Trigger.resolve`, `SystemTools.refresh`, `SystemTools.audioRefresh`, `SystemTools.slowRefresh`, `SystemStatus.sample`, `Hardware.sample`, `MissionControl.probe`, `Audio.sync`, `Audio.processOwners`, `WindowPin.snapshot`.

측정은 같은 프리셋·오디오 출력·창 고정 상태에서 숨김 60초, 시스템 도구 표시 60초, 트리거 스크롤 30초, 키 입력 구간으로 나눠 비교해야 한다. 표식의 횟수·duration과 Time Profiler의 실행 스레드 CPU를 함께 본다. GPU/WindowServer는 다른 앱의 영향도 있으므로 material 비교는 같은 화면/스크롤 조건으로 별도 검증해야 한다.

이 감사의 계측 시점에는 앱 설치 교체를 하지 않았으므로 변경된 전체 앱의 CPU 감소율, 실제 센서 수치, 오디오 외부 장치, Mission Control 절전 복귀의 대화형 검증은 주장하지 않는다. 남은 0.5초 Mission Control fallback, 0.25초 Secure Input 감지, 활성 창 고정의 0.15초 snapshot은 동작 보장을 위해 유지했다. 창 고정 경로는 이번에 표식만 추가했다.

## 공식 참고

- [3.4.35 릴리즈](https://github.com/kyw1-2/All-of-MacOS/releases/tag/aom-dev-v3.4.35-b2026110805-621007feaca6)
- [Apple: 창 가시성 변화에 맞춰 작업 줄이기](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html)
- [Apple: didChangeOcclusionStateNotification](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification)
- [Apple: 성능 데이터 기록](https://developer.apple.com/documentation/os/recording-performance-data)
