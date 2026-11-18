# MirrorDrop

iOS 앱. iPhone 화면을 Google Cast 수신기(TV·스틱)로 미러링한다. 지금은 Phase 1 PoC(가능성 확인)다. 계획: `docs/PLAN.md`.

기획서와 App Store 심사 위험 점검: `docs/SPEC.md`.

## 구조 (`ios/`, XcodeGen `ios/project.yml` → `.xcodeproj`는 생성물, 커밋 안 함)
- `MirrorDrop/` 앱 (SwiftUI, 한국어 UI)
  - `App/CastManager.swift`: Google Cast SDK(SPM `GoogleCastDynamic` 4.8.6). 기본 미디어 수신기 `CC1AD845`, 재생 요청·상태·SDK 로그.
  - `App/BroadcastMonitor.swift`: App Group에서 확장 상태를 읽음(Darwin 알림 + 1초 폴링).
  - `UI/`: 테스트 화면(`ContentView`), 진단(`DiagnosticsView`), 지연 측정 시계, Cast 버튼·방송 선택기 래퍼.
- `MirrorDropBroadcast/` Broadcast Upload Extension (`RPBroadcastSampleHandler`)
  - `MirrorPipeline`: ReplayKit 프레임 → `FrameScaler`(VideoToolbox, 1280x720 레터박스, 가로 화면 회전) → `HLSSegmenter`(AVAssetWriter `.mpeg4AppleHLS`, 1초 fMP4 조각, 메모리에서만) → `StreamStore` → `HTTPServer`(Network.framework `NWListener`).
  - 정지 화면에서는 ReplayKit이 프레임을 안 주므로 마지막 프레임을 반복해 조각이 계속 나오게 한다.
  - `StatusPublisher`: 상태·메모리·요청 기록을 App Group UserDefaults에 쓰고 Darwin 알림을 보낸다.
- `Shared/` 앱·확장·테스트가 함께 컴파일: App Group 상수와 상태 모델, HLS 재생목록, HTTP 파서·라우터, 조각 링버퍼, IP·메모리 측정.
- `MirrorDropTests/` 순수 로직 단위 테스트(호스트 앱 없음, `Shared/`를 직접 컴파일).

스트림 주소: `http://<Wi-Fi IPv4>:8765/<방송마다 새 랜덤 토큰>/live.m3u8` (마스터) → `media.m3u8` → `init.mp4`, `segN.m4s`.

## 꼭 지킬 규칙 (불변식)
- **화면 데이터는 로컬 네트워크 밖으로 나가지 않는다.** 서버는 사설·링크로컬 주소 클라이언트만 받는다(`NetworkInfo.isPrivate`). 외부 서버·클라우드 중계·분석 SDK로 화면을 보내지 않는다. 진단 로그에도 토큰을 남기지 않는다.
- **DRM 우회를 하지 않는다.** FairPlay 등 보호 콘텐츠가 검게 나오는 것은 iOS 정상 동작이다. 이를 피하는 기능을 만들지 않는다.
- **앱 이름·표시 이름에 "Chromecast"·"Google"을 쓰지 않는다.** "Google Cast"는 설명·기술 문장에서만 쓴다.
- **확장 메모리 예산: 약 50MB 한도, 목표 최고 30MB 이하.** 확장에 큰 프레임워크(Cast SDK, UI 등)를 넣지 않는다. 버퍼는 고정 크기 풀(`FrameScaler.maxBuffers`)과 조각 링버퍼(`StreamStore`)로만 늘어난다. 바꾸면 진단 화면의 최고 메모리로 확인한다.
- 팀 ID·키·인증서를 파일에 적거나 커밋하지 않는다(저장소가 비공개여도). 키는 GitHub Actions secrets(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`), 팀 ID는 저장소 변수(`APPLE_TEAM_ID`).
- **앱 사용자에게 보이는 메일**(App Store 연락처, 앱 안 문의, 개인정보처리방침)은 지금은 `kimyeoware@gmail.com`이다. 앱 개발자 전용 아이디가 생기면 이 줄과 그 자리들을 함께 바꾼다. 개발자 계정·심사 연락용 메일은 사용자에게 보이는 곳(앱·스토어·공개 문서)에 쓰지 않는다.
- 앱과 확장의 `CFBundleVersion`은 같아야 한다(둘 다 `CURRENT_PROJECT_VERSION`).

## 빌드 (GitHub)
- Mac이 없다(이 PC는 Windows). 여기서는 컴파일할 수 없으므로 Apple·Google API 서명을 문서로 확인하고 쓴다.
- 코드는 이 PC의 git과 비공개 저장소 `dohingee/mirrordrop`에 둔다. GitHub은 iOS 빌드에 Mac이 필요해서만 쓴다(GitHub Actions의 macOS 서버).
- push만으로는 아무것도 돌지 않는다(Mac 시간 절약). Mac 실행은 일부러 시작할 때만:
  - `ios-build.yml`: Claude가 `ios-check-<날짜>` 태그를 push하면 시작(손 실행, 같은 저장소의 PR도 가능). 단위 테스트 + iPhone·iPad 시뮬레이터 실행 확인과 화면 캡처.
  - `ios-testflight.yml`: Claude가 이 PC에서 `testflight-<번호>` 태그를 push하면 시작(손 실행도 가능). 같은 앱 내용의 통과한 검사가 있으면 다시 하지 않고, 출시용 빌드(archive) → TestFlight 업로드.
  - 캡처·결과는 `ci-results` 브랜치에 올라오므로 Claude가 PC에서 git으로 받아 본다.
- 비용·비밀값·웹 관리 화면(Apple Developer, App Store Connect, GitHub 설정) 순서와 누가 하는지(🤖/✋)는 `docs/SETUP.md`에만 적는다.
- iPhone에 설치하기 전에 Claude가 공통 스킬 `ios-pc-test`로 PC에서 먼저 화면·로직을 확인하고(이 앱은 `ios-build.yml` 시뮬레이터 캡처), 사용자에게는 iPhone에서만 볼 것을 짧게 추려 준다.
- 기기 시험 절차: `docs/POC_TEST.md`.
