# MirrorDrop 계획

## 목표
- iPhone 화면을 같은 Wi-Fi의 Google Cast 기기(TV, 스틱)로 보여 주는 **무료 앱**. 나중에 광고(AdMob)를 붙인다.
- 주 용도: 사진·영상 보기. **1~3초 지연은 괜찮다**(게임·발표용 아님).
- 운영 환경: Mac 없음. 빌드는 GitHub Actions(macOS), 시험은 TestFlight + 실제 iPhone(iOS 27) + 실제 Cast 기기.

## 단계
| 단계 | 할 일 | 끝났다고 보는 기준 |
|---|---|---|
| 0. 준비 | 저장소, Apple 번들 ID·App Group, App Store Connect 앱, GitHub 비밀값 (`docs/SETUP.md`) | TestFlight에 첫 빌드가 올라감 |
| **1. PoC (지금)** | 시험 화면: Cast 연결, 테스트 A(인터넷 샘플 영상), 테스트 B(내 화면 → TV), 진단 화면 | `docs/POC_TEST.md`의 핵심 항목(A, B, 메모리)이 통과하거나, 막히는 이유가 분명해짐 |
| 2. MVP | iOS 27+ ScreenCaptureKit 캡처 경로 추가(17~26은 ReplayKit 유지), 쓰기 쉬운 한 화면 UI, 연결 끊김·Wi-Fi 변경 처리, 화질/지연 설정, 소리 정리, 필요하면 커스텀 수신기 | 처음 쓰는 사람이 설명 없이 TV에 화면을 띄움 |
| 3. 광고 + 정책 | AdMob(UMP 동의 포함), 개인정보처리방침, App Privacy 답안, 심사 메모 | 광고 켠 빌드가 정책 점검 통과 |
| 4. 안정화 + 출시 | 여러 TV·스틱 기종 시험, 오래 켜 두기(발열·메모리), 스토어 자료, 심사 제출 | App Store 출시 |

## 지금까지 정한 것 (이유 포함)

### 1. 화면 → TV 전달 방식: iPhone 안에서 HLS 만들기
- Cast 기기는 "영상 주소(URL)를 받아서 스스로 가져가 재생"하는 구조다. 그래서 iPhone이 **작은 웹 서버**가 되어 영상 주소를 건넨다.
- 형식은 **HLS**(재생목록 `.m3u8` + 1초짜리 영상 조각)다. Cast 기본 수신기가 가장 잘 지원하는 실시간 형식이기 때문이다.
- 조각은 **fMP4**(H.264, 1280x720, 30fps, 약 2.5Mbps)다. Apple의 `AVAssetWriter`가 `.mpeg4AppleHLS` 모드로 메모리 안에서 바로 만들어 준다. 파일을 디스크에 쓰지 않는다.
- 조각은 최근 7개만 메모리에 두고, 재생목록에는 최근 4개만 적는다(슬라이딩 윈도). 메모리가 늘지 않는다.
- 예상 지연: 조각 길이(1초) × 수신기가 모으는 조각 수(보통 2~3개) + 인코딩 ≈ **2~4초**. 목표(1~3초)의 끝자락이다. PoC에서 실제로 잰다.
- 다른 방법과 비교:
  - WebRTC: 지연은 짧지만 Cast 기본 수신기가 지원하지 않아 커스텀 수신기 + 큰 라이브러리가 필요하다. 확장 메모리(50MB)도 빠듯하다.
  - MPEG-TS HLS: 가능하지만 직접 TS 묶음(mux)을 짜야 한다. fMP4는 Apple이 대신 해 준다.

### 2. 화면 캡처: ReplayKit 방송 확장 (Broadcast Upload Extension)
- 다른 앱(사진, Safari 등) 화면까지 잡으려면 iOS 17~26에서는 이 방법뿐이다.
- 확장은 **메모리 약 50MB**를 넘으면 iOS가 강제로 끈다. 그래서 확장에는 Cast SDK를 넣지 않고, 버퍼 수에 상한을 둔다. 진단 화면에 현재·최고 메모리를 보여 준다.
- **새로 알게 된 점**: Apple 문서에 따르면 iOS 27부터 `RPBroadcastSampleHandler`가 "곧 지원 중단(deprecated)"으로 표시되고, iOS용 **ScreenCaptureKit**이 생겼다. 앱 본체가 `SCContentSharingPicker`로 전체 화면을 잡고, 백그라운드 모드 `screen-capture`로 계속 돌 수 있다고 한다. 확장이 필요 없으니 50MB 제한과 앱↔확장 통신이 사라질 수 있다.
  - PoC는 ReplayKit로 만든다. iOS 27에서도 아직 동작하고, iOS 17~26 기기도 지원하기 때문이다.
  - 인코딩·HLS·서버 코드(`FrameScaler`, `HLSSegmenter`, `StreamStore`, `HTTPServer`)는 ReplayKit에 묶이지 않게 만들어서, 2단계에서 ScreenCaptureKit 경로를 추가할 때 그대로 쓸 수 있다.
  - **결정 (2026-10-25): 둘 다 지원한다.** iOS 17~26은 ReplayKit 방송 확장, iOS 27 이상은 ScreenCaptureKit. 무료·광고 앱이라 지원 기기 수가 중요하고, ReplayKit은 deprecated일 뿐 아직 동작하기 때문이다. ScreenCaptureKit 경로는 2단계에서 추가하고, iOS 17~26 기기가 충분히 줄면 ReplayKit 경로를 걷어낸다.

### 3. 수신기: 먼저 Google의 기본 미디어 수신기(Default Media Receiver, `CC1AD845`)
- Cast 개발자 콘솔 등록(유료 5달러)이나 수신기 웹페이지 호스팅이 필요 없다.
- 재생 요청에 "실시간(LIVE)", "HLS", "fMP4 조각"을 표시한다.
- **위험: 혼합 콘텐츠(mixed content)**
  - 기본 수신기는 `https://` 웹페이지로 TV 안에서 실행된다. 그런데 iPhone 서버 주소는 `http://192.168.x.x`다.
  - 일반 웹 브라우저는 https 페이지가 http 영상을 가져오는 것을 막는다(혼합 콘텐츠 차단). Cast 기기가 이 규칙을 똑같이 적용하면 테스트 A는 되는데 테스트 B만 실패한다.
  - 실제로는 로컬 http 주소로 Cast하는 앱이 많아 될 가능성이 높지만, 기기·펌웨어마다 다를 수 있다. PoC 진단 화면의 "서버 요청 기록"으로 **TV가 iPhone에 요청을 보냈는지** 바로 알 수 있다.
    - 요청이 아예 없음 → 수신기가 주소를 열지 않음(혼합 콘텐츠 차단 의심, 또는 네트워크 분리).
    - `live.m3u8`만 오고 멈춤 → 재생목록·코덱 문제.
    - 조각까지 계속 오는데 화면이 안 나옴 → 영상 형식 문제.
- **대안 순서** (막히면):
  1. 커스텀 수신기(Cast 콘솔 등록, 자체 수신기 페이지). 같은 혼합 콘텐츠 규칙을 받지만, 수신기 쪽에서 재생 설정(Shaka 설정, 형식 지정)을 직접 고칠 수 있다. 개발 중에는 등록한 TV에서만 동작한다.
  2. iPhone 서버를 https로: 공인 인증서가 필요하다. 로컬 IP를 가리키는 도메인 + 와일드카드 인증서 방식(Plex 등이 씀)은 인증서·키 관리 부담이 크다. 마지막 수단.
  3. HLS 대신 다른 방식(예: 커스텀 수신기 + 다른 전송). 지연은 줄지만 일이 커진다.

### 4. Google Cast iOS SDK 설치: Swift Package Manager (공식)
- Google이 공식 SPM 패키지 `github.com/googlecast/google-cast-ios-sdk`(4.8.6)를 내놓았고, 설치 안내에서 SPM을 권장한다.
- XcodeGen의 `packages:`에 한 줄로 넣을 수 있어 CocoaPods(별도 도구·워크스페이스)나 수동 xcframework(저장소에 큰 바이너리)보다 CI가 단순하다. Bottlepost와 같은 방식이다.
- `GoogleCastDynamic` 제품을 쓴다. `Static`은 링커 옵션과 리소스 번들을 손으로 넣어야 해서 Cast 버튼 같은 UI가 깨질 수 있다.
- 바이너리는 빌드 때 `dl.google.com`에서 받는다(체크섬 고정).

### 5. 소리
- 기본은 **영상만**. "앱 소리 포함(실험)" 스위치를 켜면 `.audioApp`을 AAC로 같은 조각에 섞는다.
- 기본을 끈 이유: `AVAssetWriter`는 영상과 소리 트랙을 시간순으로 맞춰 쓰는데, 아무 소리도 안 나는 동안 ReplayKit은 소리 샘플을 보내지 않는다. 그러면 조각이 늦게 나오거나 멈출 수 있다. 또 소리 샘플의 형식(44.1/48kHz, 채널 수)이 상황마다 달라질 수 있다. PoC에서 켜고 끄며 확인한 뒤, 필요하면 2단계에서 무음 채우기를 넣는다.

### 6. 화면 방향
- TV 쪽 화면은 항상 1280x720(가로). 세로 화면은 양옆이 검은 띠, 가로로 돌린 영상은 꽉 차게 나온다.
- ReplayKit은 가로 화면도 세로 그림 + "방향 값"으로 준다. 방향 값이 6(right)/8(left)이면 90도 돌린다. 방향이 반대로 나오면 `FrameScaler`의 회전 방향 두 줄만 바꾸면 된다.

### 7. 개인정보·정책 (3단계에서 자세히)
- 화면 데이터는 Wi-Fi 안에서 iPhone → TV로만 간다. 서버는 사설 IP에서 온 요청만 받고, 방송마다 새 랜덤 주소(토큰)를 쓴다.
- DRM(넷플릭스 등 FairPlay)이 걸린 화면은 iOS가 검게 보낸다. 우회하지 않는다.
- 앱 이름에 "Chromecast"·"Google"을 넣지 않는다.
