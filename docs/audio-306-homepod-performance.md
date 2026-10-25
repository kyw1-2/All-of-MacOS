# AOM 3.0.6 — HomePod 경로와 메뉴 반응 개선

기준 커밋은 `170fc35`이며 설치본 `3.0.6`의 AOMSourceRevision도 이 리비전과 일치했다. 이미 들어간 안정화 변경을 유지한 상태에서 수정했다. 설치본 진단과 소스 추적을 수행했으며, 수정 후 빌드·테스트·설치·배포는 수행하지 않았다.

## HomePod의 EQ·앱별 볼륨이 동작하지 않는 이유

현재 구현은 기본 출력이나 앱별 목적지가 AirPlay이면 캡처를 우회한다. 따라서 EQ·앱별 음량·음소거·부스트 설정이 저장되어도 HomePod 소리에 적용되지 않는 것이 코드상 의도된 동작이다.

이전 설치본의 2026-10-25 15:52:42.635 기록에서 Chrome이 Playing으로 바뀐 뒤, 15:52:43.484에 `com.apple.AirPlayXPCHelper`가 전달한 `Pause` 명령의 발신 장치가 HomePod로 기록되어 있다. 15:52:43.622에는 Chrome이 Paused로 바뀐다. 이 실행에서 AOM의 기본 장치 aggregate 생성은 15:53:51로, 해당 Pause보다 늦다. 따라서 이 사례를 AOM의 1초 타이머가 영상을 직접 멈췄다고 단정할 수 없다. HomePod가 왜 Pause를 보냈는지는 이 로그만으로 확정되지 않는다.

또한 과거 로그에는 AOM의 AVAudioEngine 초기화가 기본 마이크와 AirPlay 출력을 묶은 `CADefaultDeviceAggregate`를 생성한 기록이 있다. 이는 장치 생성 관찰이며, 그 자체가 Pause의 원인이라는 증거는 아니다.

### 안정성을 우선하는 적용 방식

| 경로 | 적용 가능 범위 | 판단 |
|---|---|---|
| 현재 native AirPlay 직통 | macOS/HomePod의 실제 음량 제어; AOM 효과는 저장만 | 이번 변경의 기본 경로. HomePod 선택과 원격 Pause를 가로채지 않는다. |
| 재생 앱 자체의 음량/EQ | 해당 앱이 자체 제공하는 기능 | 별도 캡처/재전송이 없어 가장 적은 라우팅 개입. 모든 앱에 공통 적용할 수는 없다. |
| 가상 로컬 출력 + DSP + 전담 AirPlay 송신 서비스 | 구현·검증 후 앱별 음량/EQ를 전송 전에 적용할 후보 | 장기 설계. 기존 bypass 조건 하나를 끄는 방식으로 대체할 수 없다. |

마지막 방식은 앱 → 안정적인 로컬 캡처/가상 장치 → 앱별 DSP → 단일 믹스 → 한 개의 장기 유지 송신 세션 → HomePod로 분리하는 것이 적절하다. UI 재생성, 앱 목록 변경, 효과 토글로 송신 세션을 다시 열어서는 안 된다. 캡처 시계와 네트워크 시계 사이의 버퍼·드리프트, HomePod 연결 복구, 원격 제어 소유권, 지연 측정, 실패 시 원음 복구를 각각 다뤄야 한다. 가상 장치 배포/서명과 실제로 사용 가능한 송신 인터페이스를 먼저 확정해야 한다. 이 방식의 HomePod 안정성은 아직 구현·검증한 사실이 아니며, 이번 커밋에는 새 드라이버나 비공개 AirPlay API를 넣지 않았다.

## 이번 수정

- 전역 AirPlay뿐 아니라 **이미 실행 중인 앱 세션의 개별 AirPlay 경로 변경**에도 우회 정책을 적용한다. 생성 시에만 있던 보호를 실행 중 전환까지 확장했다.
- HomePod 직통 상태를 오디오 화면·앱 상태·사이드바·작은 믹서에 표시한다. 효과가 적용 중인 것처럼 보이던 혼동을 줄인다.
- 하드웨어 음량 제어가 없고 캡처도 우회되는 AirPlay에서는 작동하지 않는 소프트웨어 음량을 성공으로 보고하지 않는다.
- AirPlay/비활성 조기 반환도 동기화 시각을 갱신하고, 엔진 비활성 시 주기 스캔을 멈춘다. 장치 변경 이벤트를 합쳐 처리하고 장치 목록과 앱 표시 메타데이터를 짧게 캐시한다.
- 10 Hz 레벨 갱신을 앱 목록과 분리한다. 오디오 화면 전체가 아닌 레벨 표시만 갱신하고, 창/패널이 보일 때 공유 타이머 하나만 사용한다.
- 변하지 않은 앱 목록·오류·엔진 설정을 재게시하지 않고 중복 UI 갱신을 합친다. 효과 슬라이더의 재계산 뒤 전체 세션 탐색을 다음 이벤트 루프로 넘긴다.
- 녹화 시간·클립보드 상태 갱신이 전체 사이드바 목록을 다시 그리지 않도록 해당 상태 배지만 관찰한다.
- Mission Control의 반복 AX 조회를 전용 직렬 큐로 옮기고, 한 번에 하나만 조회한다. 중지/화면 잠금 뒤 도착한 결과를 무시하고 타임아웃을 제한한다.
- Mission Control 타일이 같은 인덱스에서 바뀔 때 닫기 버튼이 이전 창을 가리키던 문제, 패널의 hover 클로저 순환 참조를 수정한다. 제목이 모호한 경우 무관한 첫 창을 닫는 fallback을 제거한다.
- 전체 앱 부스트만 켰을 때 캡처 시작 조건에서 누락되던 문제, 앱별 부스트 비활성화가 이전 강도를 남기던 문제를 수정한다. 오디오 프로세스가 없는 앱까지 aggregate를 만드는 것도 막는다.
- 부스트의 샘플별 tanh 왜곡을 지속 상태가 있는 스테레오 연동 압축·메이크업 게인으로 바꾼다. 레벨 전환은 attack/release로 완화하고 무음에 과도한 게인을 주지 않는다. AOM 자체 구현이며 SoundSource 알고리즘의 복제라는 의미는 아니다.
- 지연 실행되는 출력 보호 작업이 실제 실행 시점의 사용자 설정과 장치 UID를 다시 확인한다. A→B→C 연속 전환에서도 복원 대상 A를 유지한다.

## 분석 근거와 한계

3.0.6 설치본의 3초 샘플에서 메인 스레드는 대부분 대기 중이었다. 따라서 이 샘플로 모든 메뉴 지연을 재현했다고 말할 수 없다. 다만 Mission Control의 주기 호출에서 메인 스레드가 LaunchServices 동기 IPC에 들어가는 스택은 관찰했다. 실제 메뉴 클릭 전후 지연 수치나 개선율은 측정하지 않았다.

SoundSource 설치본 SSAudio의 심볼에는 `SSAudioDummyTapRunner`, Bluetooth 자동 전환 호환 모드, Tahoe sample-rate matching, `captureBoostSmoother`, `AHCompressorNode` 관련 항목이 있다. 심볼은 기능 경계의 근거이며, 정확한 정책/알고리즘을 설명하는 충분한 근거는 아니다. REA/Ghidra의 `setIsTahoeCompatibilityModeActive:` 분석(`ev_b7d61fac1d523a6b8171dcbc8673fff1e5c997027159ad866797c7bac2c26328`, SHA-256 `39e2292cdf21ba1e2fdc470247dffa58b82b30732574e7ac947a4ab5d0c1900a`)은 해당 setter가 플래그를 저장함을 보여준다. 이것만으로 ARK의 HomePod 지원 방식을 재현할 수 없다.

공식 자료:
- SoundSource 내장 효과: https://rogueamoeba.com/support/manuals/soundsource/?page=built-in-effects
- ARK 오디오 처리 설명: https://rogueamoeba.com/support/knowledgebase/?product=SoundSource&showArticle=Misc-ARK-Plugin-Audio-Capture-Details
- Apple Core Audio taps: https://developer.apple.com/documentation/coreaudio/catapdescription

앱 전체 무결함, HomePod 효과 지원 완료, SoundSource 전체 기능 동등성을 주장하지 않는다. 이번 작업은 확인한 코드 결함 수정·성능 부담 축소와 HomePod 후속 설계까지이며, 수정 후 검증과 릴리스는 남아 있다.
