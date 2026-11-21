# MirrorDrop 계획

## 목표
- iPhone 화면을 같은 Wi-Fi의 Google Cast 기기(TV, 스틱)로 보여 주는 **무료 앱**. 첫 출시(1.0)부터 광고(AdMob)를 넣고, 한국어·영어로 세계에 낸다(`docs/RELEASE.md`).
- 주 용도: 사진·영상 보기. **1~3초 지연은 괜찮다**(게임·발표용 아님). 실측 약 4초가 나와 2026-11-21 사용자가 약 4초로 진행하기로 정함.
- 운영 환경: Mac 없음(Windows PC). 코드는 이 PC의 git + 공개 GitHub 저장소, 빌드는 GitHub Actions(macOS)를 일부러 시작할 때만 돌린다(`CLAUDE.md` "빌드"). Claude가 PC에서 시뮬레이터 캡처로 먼저 확인한 뒤, TestFlight + 실제 iPhone(iOS 27) + 실제 Cast 기기로 시험한다.
- 앱이 무엇이고 누구를 위한 것인지, App Store 심사 위험 점검: `docs/SPEC.md`.

## 단계
| 단계 | 할 일 | 끝났다고 보는 기준 |
|---|---|---|
| 0. 준비 | 심사 위험 점검(`docs/SPEC.md`), GitHub 저장소, Apple 번들 ID·App Group, App Store Connect 앱, GitHub 비밀값, 손 실행·태그 실행 빌드 (`docs/SETUP.md`) | 심사 위험 점검 결론이 "진행"이고, `testflight-` 태그로 TestFlight에 첫 빌드가 올라감 |
| 1. PoC (끝남, 2026-11-21) | 시험 화면: Cast 연결, 테스트 A(인터넷 샘플 영상), 테스트 B(내 화면 → TV), 진단 화면 | `docs/POC_TEST.md`의 핵심 항목(A, B, 메모리)이 통과하거나, 막히는 이유가 분명해짐 |
| 2. MVP (끝남, 빌드 16까지) | ~~iOS 27+ ScreenCaptureKit 캡처 경로 추가~~ → 1.0 뒤로 미룸(아래 2번 "1.0은 ReplayKit만"), 쓰기 쉬운 한 화면 UI, 연결 끊김·Wi-Fi 변경 처리, 화질/지연 설정(PoC 실측 약 6~6.5초. TARGETDURATION 반올림 수정은 효과 없었고, 재생기가 재생목록 맨 앞부터 재생하는 것으로 보여 빌드 13의 "지연 실험" L0~L3로 잼. 지연은 L0 4.0초·L3 4.3초로 비슷하고 그중 약 2.4초는 기본 수신기가 끝에서 뒤에 서는 몫. 시작 직후부터 바로 부드러운 L3를 기본값으로 함(`docs/POC_TEST.md`). 2026-11-21 사용자 결정: 약 4초로 진행, 커스텀 수신기는 나중에 필요할 때. 시작 직후 몇 초 부드럽지 않은 문제(L3 약 5초, L0·L1 10~20초)는 진단 맨 위 "시작 기록 (처음 30초)"로 원인을 가린다(`docs/POC_TEST.md` "시작 직후 끊김")), 소리 정리, 필요하면 커스텀 수신기 | 처음 쓰는 사람이 설명 없이 TV에 화면을 띄움 |
| **3. 출시 준비 (지금, 빌드 17 = 1.0 출시 후보)** | 출시 빌드 정리(PoC 시험 도구 빼기), AdMob(UMP 동의·ATT 포함), 영어 화면, 개인정보처리방침·지원 웹 페이지(한국어·영어), App Privacy 답안, 스토어 글(한국어·영어)·스크린샷·시연 영상, 심사 메모. 순서와 누가 하는지는 `docs/RELEASE.md` | 광고·영어가 들어간 빌드 17이 기기 시험과 정책 점검 통과 |
| 4. 출시 | 심사 제출 → 승인 → 수동 출시. 세계(EU 27개국·중국 본토 제외), 무료 + 광고 | App Store 출시 |
| 5. 출시 뒤 | iOS 27+ ScreenCaptureKit 경로, 여러 TV·스틱 기종 시험, 오래 켜 두기(발열·메모리), EU 추가(사업자 생긴 뒤), "광고 제거" 구매(사업자 생긴 뒤, `docs/MONETIZATION.md`) | 업데이트마다 |

- **단계를 바꾼 이유 (2026-11-22, 사용자 결정 "16 test 이후 최종 출시 준비", "광고를 출시 전에도", "해외용 출시도"):** 원래는 3단계(광고) → 4단계(안정화 + 출시) 순서였다. 빌드 16까지 핵심 기능이 기기에서 통과했고, 수익은 출시 첫날부터 내고 싶다는 결정에 따라 **광고와 영어를 1.0에 함께 넣어 바로 출시**한다. 여러 기종 시험·ScreenCaptureKit은 출시 뒤 업데이트로 옮겼다(출시를 늦출 만큼의 위험이 아니고, 지금 iPhone(iOS 27)에서 ReplayKit이 동작함).
- **1.0은 ReplayKit만 (2026-11-22):** iOS 27에서도 `RPBroadcastSampleHandler`가 아직 동작하고(빌드 16까지 기기 시험), ScreenCaptureKit 경로는 백그라운드 모드(`screen-capture`) 심사 위험(SPEC 8번)까지 새로 생긴다. 출시 뒤 따로 내면 1.0 심사가 단순해진다. 아래 2번의 "둘 다 지원" 결정은 그대로이고 시점만 1.0 뒤다.

## 지금까지 정한 것 (이유 포함)

### 1. 화면 → TV 전달 방식: iPhone 안에서 HLS 만들기
- Cast 기기는 "영상 주소(URL)를 받아서 스스로 가져가 재생"하는 구조다. 그래서 iPhone이 **작은 웹 서버**가 되어 영상 주소를 건넨다.
- 형식은 **HLS**(재생목록 `.m3u8` + 짧은 영상 조각, 기본 0.5초)다. Cast 기본 수신기가 가장 잘 지원하는 실시간 형식이기 때문이다.
- 조각은 **fMP4**(H.264, 1280x720, 30fps, 약 2.5Mbps)다. Apple의 `AVAssetWriter`가 `.mpeg4AppleHLS` 모드로 메모리 안에서 바로 만들어 준다. 파일을 디스크에 쓰지 않는다.
- 조각은 최근 10개(0.5초짜리)만 메모리에 두고, 재생목록에는 최근 6개만 적는다(슬라이딩 윈도, 기본값 L3. 빌드 13까지는 1초 조각 7개·4개). 메모리가 늘지 않는다.
- 처음 예상 지연은 2~4초(1초 조각 × 수신기가 모으는 2~3개 + 인코딩)였다. PoC 실측은 약 4초(L0 4.0초, L3 4.3초, 2026-11-21).
- 다른 방법과 비교:
  - WebRTC: 지연은 짧지만 Cast 기본 수신기가 지원하지 않아 커스텀 수신기 + 큰 라이브러리가 필요하다. 확장 메모리(50MB)도 빠듯하다.
  - MPEG-TS HLS: 가능하지만 직접 TS 묶음(mux)을 짜야 한다. fMP4는 Apple이 대신 해 준다.

### 2. 화면 캡처: ReplayKit 방송 확장 (Broadcast Upload Extension)
- 다른 앱(사진, Safari 등) 화면까지 잡으려면 iOS 17~26에서는 이 방법뿐이다.
- 확장은 **메모리 약 50MB**를 넘으면 iOS가 강제로 끈다. 그래서 확장에는 Cast SDK를 넣지 않고, 버퍼 수에 상한을 둔다. 진단 화면에 현재·최고 메모리를 보여 준다.
- **새로 알게 된 점**: Apple 문서에 따르면 iOS 27부터 `RPBroadcastSampleHandler`가 "곧 지원 중단(deprecated)"으로 표시되고, iOS용 **ScreenCaptureKit**이 생겼다. 앱 본체가 `SCContentSharingPicker`로 전체 화면을 잡고, 백그라운드 모드 `screen-capture`로 계속 돌 수 있다고 한다. 확장이 필요 없으니 50MB 제한과 앱↔확장 통신이 사라질 수 있다.
  - PoC는 ReplayKit로 만든다. iOS 27에서도 아직 동작하고, iOS 17~26 기기도 지원하기 때문이다.
  - 인코딩·HLS·서버 코드(`FrameScaler`, `HLSSegmenter`, `StreamStore`, `HTTPServer`)는 ReplayKit에 묶이지 않게 만들어서, 2단계에서 ScreenCaptureKit 경로를 추가할 때 그대로 쓸 수 있다.
  - **화면 잠금 (2026-11-21, 빌드 15 기기 시험):** iPhone이 잠기면 iOS가 방송을 끝내고, 잠금을 풀어도 이어지지 않는다. 다시 시작은 사용자가 시작 버튼(시스템 방송 선택기)을 눌러야 하고 앱이 대신 할 수 없다. 확장은 이때 끝났다는 신호(`broadcastFinished`)를 못 받을 수 있다(개발자 보고, 우리 기기에서는 미확인).
    - 대응: **멈춤 알림(데드맨 방식).** 보내는 동안 확장이 "6초 뒤 알림" 하나를 예약해 두고 2초마다 같은 식별자로 다시 넣어 뒤로 민다(같은 식별자면 예약된 것을 바꿔 넣는다, Apple 문서). 확장이 꺼지거나 멈추면 더 못 밀어서 알림이 뜬다. 사용자가 직접 멈추면 예약과 표시된 알림을 지운다. 알림을 누르면 앱 첫 화면의 ② 시작 버튼으로 간다. 권한은 처음 보내기를 시작할 때 한 번 묻고(알림만, 소리·배지 없음), 앱이 앞에 있을 때는 띄우지 않는다(상태 카드가 같은 말을 함). 코드: `Shared/StopAlert.swift`(언제 다시 넣을지, 단위 테스트), `MirrorDropBroadcast/StopAlertArmer.swift`, `MirrorDrop/App/StopAlertCenter.swift`.
    - 한계: 잠금 뒤에도 확장이 살아서 계속 돈다면 알림은 뜨지 않는다. 기기 시험으로 확인한다(`docs/POC_TEST.md` "멈춤 알림").
    - 첫 화면 안내도 "iPhone이 잠기면 TV 보내기가 끝나요"로 고쳤다. 오래 볼 때는 자동 잠금을 '안 함'으로 바꾸도록 안내한다.
  - **결정 (2026-10-25): 둘 다 지원한다.** iOS 17~26은 ReplayKit 방송 확장, iOS 27 이상은 ScreenCaptureKit. 무료·광고 앱이라 지원 기기 수가 중요하고, ReplayKit은 deprecated일 뿐 아직 동작하기 때문이다. ScreenCaptureKit 경로는 2단계에서 추가하고, iOS 17~26 기기가 충분히 줄면 ReplayKit 경로를 걷어낸다.
  - **문서 확인 (2026-11-21, developer.apple.com 원문과 개발자 포럼):**
    - `RPBroadcastSampleHandler`·`RPSystemBroadcastPickerView`는 iOS 27.0까지로 표시(지원 중단 예정). ScreenCaptureKit 문서: "ScreenCaptureKit replaces ReplayKit for screen streaming and mirroring."
    - 다른 앱까지 포함한 전체 화면: `SCContentSharingPicker.shared.present()` → 관찰자 `contentSharingPicker(_:didUpdateWith:for:)`로 받은 `SCContentFilter`로 `SCStream` 시작(`@available(iOS 27.0, *)`). 사용자가 멈추면 `SCStreamError.Code.userStopped`.
    - 백그라운드: `UIBackgroundModes`에 `screen-capture`. 없으면 백그라운드로 갈 때 `missingBackgroundMode`(-3824). 무음 오디오로 버티기는 통하지 않는다는 보고가 있다(SPEC 8번 방향과 같음). App Store Connect가 이 값을 거절하던 문제는 2026-08 해결.
    - 엔타이틀먼트는 필요 없다(Apple 답변, 포럼 856067). `NSScreenCaptureUsageDescription`은 iOS에서 꼭 필요한지 확인 못 해 넣어 둔다.
    - 프레임레이트: `minimumFrameInterval`·`queueDepth`는 iOS SDK에서 쓸 수 없다(포럼 848296). 최대 60fps이므로 지금처럼 우리 코드에서 프레임을 버린다. 방향 값은 `SCStreamFrameInfo.videoOrientation`(CGImagePropertyOrientation과 같은 뜻).
    - 확인 못 함: 백그라운드에서 앱 본체의 `NWListener`가 계속 도는지(앱이 멈춤 상태가 아니면 돌 것으로 추론), 백그라운드 메모리 한도, 보호 영상이 검게 나오는지, 스토어·TestFlight 판 실측 보고. → iPhone(iOS 27)에서 화면 잠금·다른 앱 앞에 둔 상태로 TV가 조각을 계속 받아 가는지 실측해야 한다.
    - 만드는 순서: 앱 화면·안정성 작업이 끝난 뒤, 인코딩·HLS·서버 코드를 앱 본체에서도 쓰도록 옮기고 ScreenCaptureKit 경로를 붙인다.

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
- **바뀐 이유 (2026-11-21 사용자 요청):** TV를 연결하면 TV와 휴대폰에서 소리가 같이 나고, TV 쪽은 약 4초 늦어서 헷갈린다. AirPlay처럼 **소리 나오는 곳을 고를 수 있게** 한다.
- **첫 화면 "소리 나오는 곳": TV(기본) / 휴대폰.** 보내는 중에도 바꿀 수 있고, 방송을 다시 시작할 필요가 없다. 옛 "앱 소리 포함(실험)" 스위치는 없앴다(옛 설정 값 `includeAppAudio`는 앱이 켜질 때 지운다).
  - **TV:** 휴대폰의 앱 소리(`.audioApp`)를 TV로 보낸다.
  - **휴대폰:** TV로는 무음을 보낸다. 소리는 휴대폰에서만 난다.
- **휴대폰 소리는 앱이 끌 수 없다.** 다른 앱의 소리를 끄는 공개 기능이 없다. 시스템 볼륨을 몰래 바꾸는 방법(MPVolumeView 슬라이더 조작)이나 무음 재생·`audio` 백그라운드 모드는 쓰지 않는다(심사 위험, SPEC 2.5.4). 그래서 "TV에서만"은 "TV로 소리를 보내고, 사용자가 휴대폰 볼륨을 끝까지 내리도록 안내"하는 뜻이다. 앱이 앞에 있을 때는 휴대폰 볼륨(`AVAudioSession.outputVolume`)을 읽기만 해서 0이면 "휴대폰 소리 꺼짐 ✓"을 보여 준다. 이때 다른 앱 소리를 끊지 않도록 섞어 재생하는 종류(`.ambient`)일 때만 오디오 세션을 켠다.
  - ReplayKit의 앱 소리는 휴대폰 볼륨을 적용하기 전에 잡히는 것으로 보인다. 그러면 휴대폰 볼륨이 0이어도 TV에는 소리가 간다. 2026-11-21 빌드 15에서 기기로 확인했다: 휴대폰 볼륨 0에도 TV 소리 남, 보내는 중 TV/휴대폰 바꾸기, 무음 화면 20초 넘게 안 멈춤, TV 볼륨·음소거, 10분 최고 메모리 15.5MB 모두 통과(`docs/POC_TEST.md` "소리"). 진단 화면의 "소리 크기"로 확인할 수 있다.
- **TV 볼륨:** TV에 연결되면 첫 화면에 TV 볼륨 막대와 음소거 버튼이 나온다(Google Cast의 기기 볼륨 기능 `GCKSession.setDeviceVolume`·`setDeviceMuted`). 휴대폰 옆 볼륨 버튼은 언제나 휴대폰 소리만 바꾼다(`GCKCastOptions.physicalVolumeButtonsWillControlDeviceVolume = false`, 빌드 16부터). 다른 앱에 있을 때는 버튼을 TV로 돌릴 방법이 iOS에 없어서, 앱 안에서도 같게 해 헷갈리지 않게 했다. "TV"를 고르면 첫 화면에 "볼륨 버튼 = 휴대폰 소리, TV 소리 = 리모컨·막대" 안내를 "알겠어요"를 누를 때까지 한 번 보여 준다.
- **소리 트랙은 항상 만든다.** 그래야 방송 중에 TV/휴대폰을 바로 바꿀 수 있다. "휴대폰"이면 진짜 소리 대신 같은 길이의 무음을 쓴다. 확장은 설정을 앱이 보내는 Darwin 알림으로 바로 읽고, 알림을 놓쳐도 0.5초마다 다시 읽는다. 바뀌면 확장 로그에 `audio output tv -> phone`처럼 남긴다.
- **무음 채우기와 형식 맞추기 (`MirrorDropBroadcast/AudioTrack.swift`, 판단 로직은 `Shared/AudioFill.swift`에 두고 단위 테스트):**
  - 문제: `AVAssetWriter`는 영상과 소리 트랙을 시간순으로 맞춰 쓰는데, 아무 소리도 안 나는 동안 ReplayKit은 소리 샘플을 보내지 않는다. 그대로 두면 조각이 늦게 나오거나 멈춘다. 또 받은 소리의 형식(44.1/48kHz, 모노/스테레오, 16비트 big-endian 정수 또는 32비트 실수)이 상황마다 다르다.
  - 받은 소리는 모두 한 형식(48kHz 스테레오 16비트)으로 바꾼다. 형식 해석과 샘플레이트 변환(직선 보간)은 직접 만든 순수 코드로 했다. `AVAudioConverter` 대신 쓴 이유: ReplayKit 소리가 big-endian으로 오는 경우가 있어 형식 처리를 확실히 하고, PC에서 단위 테스트로 확인하기 위해서다.
  - 소리 트랙의 시간은 영상과 같은 시계(영상 조각의 시작 시각부터 48kHz 프레임 수)로 끊김 없이 이어 붙인다. 진짜 소리의 시각이 트랙 끝보다 뒤면 그 사이를 무음으로 채우고, 조금(0.3초 이내) 앞이면 그대로 잇고, 더 앞이면 겹치는 부분만 버린다.
  - 진짜 소리가 0.3초 넘게 안 오면 영상 시각보다 0.2초 뒤까지 무음을 채운다. 소리가 오는 중에도 트랙이 1초 넘게 뒤지면 무음을 채워 영상이 기다리지 않게 한다.
  - 메모리: 줄을 세워 두지 않는다. 받은 소리는 바로 바꿔 인코더에 넘기고, 인코더가 바쁘면 버린다(진단의 "버린 소리"). 무음용 0 버퍼 하나(약 19KB)만 늘 들고 있다.
  - 인코더를 새로 만들면(오류 복구) 소리 트랙도 새 인코더의 시작 시각부터 다시 시작한다.
- 재생목록: 마스터 재생목록의 BANDWIDTH에 소리 128kbps를 더하고, CODECS에는 init 조각에서 읽은 `mp4a.40.2`가 들어간다.
- 진단 화면 "소리": 지금 쓰는 출력, 받은 소리 묶음 수·형식, 소리 크기(최근 1초·최고, 휴대폰 볼륨과 관계없는 값), TV로 보낸 소리·채운 무음·버린 소리(초).

### 6. 화면 방향
- TV 쪽 화면은 항상 1280x720(가로). 세로 화면은 양옆이 검은 띠, 가로로 돌린 영상은 꽉 차게 나온다.
- ReplayKit은 가로 화면도 세로 그림 + "방향 값"으로 준다. 방향 값이 6(right)/8(left)이면 90도 돌린다. 실제 iPhone에서 EXIF 뜻대로 돌렸더니 거꾸로 나와서(2026-11-20, 빌드 10) 두 방향 모두 반대로 돌린다(`FrameScaler`). 빌드 13에서 왼쪽·오른쪽 모두 바르게 나오는 것을 확인했다(2026-11-21).

### 7. 개인정보·정책 (3단계에서 자세히, 심사 지침별 대응은 `docs/SPEC.md`)
- 화면 데이터는 Wi-Fi 안에서 iPhone → TV로만 간다. 서버는 사설 IP에서 온 요청만 받고, 방송마다 새 랜덤 주소(토큰)를 쓴다.
- DRM(넷플릭스 등 FairPlay)이 걸린 화면은 iOS가 검게 보낸다. 우회하지 않는다.
- 앱 이름에 "Chromecast"·"Google"을 넣지 않는다.

### 8. 앱을 떠나도 TV에 띄우기 (2026-11-21, 시험하는 사람 보고)
- TV 재생 요청은 앱이 보내므로, 보내기 시작 직후 다른 앱으로 가도 요청을 보낼 때까지만 앱이 짧은 백그라운드 작업(`beginBackgroundTask`)으로 깨어 있고(`App/MirrorCastCoordinator.swift`, 판단은 `Shared/BackgroundCastHold.swift`), Cast 세션도 뒤에서 멈추지 않게 했다(`suspendSessionsWhenBackgrounded = false`). 백그라운드 모드는 쓰지 않는다(SPEC 2.5.4). 앱이 이미 잠든 뒤의 Wi-Fi 변경은 앱을 열어야 TV에 다시 보낸다.
