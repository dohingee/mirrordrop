# App Store 제출 문구 — 한국어 (+ 심사 메모)

App Store Connect에 넣을 한국어 글과 심사 메모를 이 파일 한 곳에 모은다. 영어 글은 `docs/store/en.md`. 누가 언제 어느 화면에 넣는지, 연령 등급·App Privacy 답은 `docs/RELEASE.md`에만 있다.

- 앱 버전 1.0, 광고(AdMob) 포함 첫 출시. 광고 조건은 `docs/MONETIZATION.md`와 같아야 한다(배너는 보내지 않을 때만, 시작 전 전면 광고는 하루 최대 1번, 보내는 중 광고 없음).
- 숫자는 실제 동작과 같아야 한다: 지연 약 4초(`docs/PLAN.md` 목표), 720p(`FrameScaler` 1280x720), iOS 17 이상(`ios/project.yml`). 바뀌면 이 파일과 `en.md`를 함께 고친다.
- 공개 웹 주소(Firebase Hosting, `web/hosting/`). 주소의 앞부분(`mirrordrop-app`)은 Firebase 프로젝트 ID라 만들 때 바뀔 수 있다. 바뀌면 여기, `en.md`, 앱의 `AppLinks`(`ios/MirrorDrop/UI/AdvancedView.swift`)를 함께 고친다.
  - 개인정보 처리방침 URL: `https://mirrordrop-app.web.app/privacy.html`
  - 지원 URL: `https://mirrordrop-app.web.app/support.html`
  - 마케팅 URL: `https://mirrordrop-app.web.app/` (AdMob이 이 주소의 도메인에서 `app-ads.txt`를 찾는다. 비워 두지 않는다)
- 글자 수 제한(App Store Connect 도움말 "Platform version information" 2026-11-22 확인): 이름·부제 30자, 홍보 문구 170자, 설명 4000자, 키워드 **100바이트**(한글 한 글자 = 3바이트), 새로운 기능 4000자.
- 쓰지 않는 말: "Chromecast", "Google"을 이름·부제·키워드에 넣지 않는다. "Google Cast"는 설명의 호환 문장과 상표 문장에서만 쓴다(Google Cast UX 가이드라인: 앱 이름에 Google Cast를 넣지 말 것, 마케팅 글에 "Google Cast is a trademark of Google LLC." 표기 — https://developers.google.com/cast/docs/ux_guidelines). 다른 미러링 앱 이름, "실시간·지연 없음", "넷플릭스도 됨", "게임용"은 쓰지 않는다(SPEC 5번).

## 1. 앱 이름 (30자)

```text
MirrorDrop
```
(10자) 홈 화면 이름(`CFBundleDisplayName`)과 같다. App Store Connect에 앱을 만들 때 이미 이 이름으로 잡았다(`docs/SETUP.md` 3번). 2026-11-22 웹 검색으로 같은 이름의 App Store 앱은 찾지 못했다.

## 2. 부제 (30자)

```text
iPhone 화면을 TV로 그대로 보기
```
(21자)

## 3. 홍보 문구 (170자, 심사 없이 언제든 바꿀 수 있음)

```text
버튼 두 번이면 iPhone 화면이 거실 TV에. 가입·구독 없이 무료로, 화면은 집 Wi-Fi 밖으로 나가지 않아요. 사진·영상을 가족과 큰 화면으로 함께 보세요.
```

## 4. 설명 (4000자 이내)

```text
MirrorDrop은 iPhone 화면을 같은 Wi-Fi에 있는 TV로 그대로 보여 주는 무료 앱이에요. 여행 사진, 아이 동영상, 웹에서 찾은 영상을 가족과 큰 화면으로 함께 보세요.

■ 이렇게 간단해요
① TV 고르기 → ② "TV로 보내기 시작" → "방송 시작"
이제 사진, 동영상, Safari 등 보고 싶은 앱을 열면 TV에 나와요. 처음이라면 앱 안의 "사용 방법"이 순서대로 알려 드려요.

■ 가입도 구독도 없어요
· 회원 가입·로그인이 없어요.
· 화면 보내기, 소리, TV 볼륨 등 모든 기능이 무료예요. 시간 제한, 워터마크, 구독 결제가 없어요.

■ 화면은 집 Wi-Fi 안에서만
· iPhone이 직접 TV에 영상을 건네요. 화면과 소리는 인터넷이나 다른 서버로 나가지 않고, 저장되지도 않아요.

■ 소리는 고르기 나름
· 소리 나오는 곳을 TV 또는 휴대폰 중에서 고를 수 있고, 보내는 중에도 바꿀 수 있어요.
· TV에 연결되면 앱에서 TV 볼륨과 음소거를 바꿀 수 있어요.

■ 멈추면 알려 드려요
· iPhone이 잠기면 iOS가 화면 공유를 끝내요. 알림을 허용하면 "TV 보내기가 멈췄어요"라고 알려 드리고, 알림을 누르면 바로 다시 시작할 수 있어요.

■ 꼭 알아 두세요
· Google Cast를 지원하는 TV와 스틱에서 쓸 수 있어요. iPhone과 TV가 같은 Wi-Fi에 있어야 해요(게스트 Wi-Fi·AP 격리에서는 TV를 찾지 못해요).
· TV 화면은 iPhone보다 약 4초 늦게 나와요(720p). 사진·영상 감상용이라 빠른 게임에는 맞지 않아요.
· 저작권 보호 영상(넷플릭스 등)은 iOS가 검게 보내요. 그런 앱은 앱 안의 TV 전송 버튼을 쓰세요.
· 보내는 동안 iPhone 화면에 보이는 것은 알림까지 모두 TV에 보여요.
· iOS 17 이상 iPhone에서 쓸 수 있어요.
· 무료 앱이라 광고가 나와요. TV로 보내는 동안에는 광고를 보여 주지 않아요.

Google Cast는 Google LLC의 상표입니다. MirrorDrop은 Google과 관계없는 독립 앱입니다.

문의: kimyeoware@gmail.com
```

## 5. 키워드 (100바이트)

```text
미러링,화면공유,화면미러링,티비연결,스마트TV,대화면,사진보기,동영상
```
(96바이트, 38자) 쉼표 뒤 띄어쓰기 없음. 앱 이름에 든 "MirrorDrop"은 넣지 않았다. 상표(Chromecast·Google·다른 앱 이름)는 넣지 않았다.

## 6. 새로운 기능 (첫 버전은 칸이 없을 수 있음. 있으면)

```text
MirrorDrop을 처음 선보여요. iPhone 화면을 같은 Wi-Fi의 TV로 보내 보세요.
```

## 7. 카테고리

- 기본: **사진 및 비디오**(Photo & Video)
- 보조: **유틸리티**(Utilities)

근거
- 기획서(`docs/SPEC.md`)의 주 용도가 "사진·영상을 가족과 큰 화면으로 같이 보기"다. 카테고리를 설명과 같은 용도로 두면 2.3(정확한 정보)과 맞고, 찾는 사람이 들어오는 곳과도 맞다.
- 유틸리티는 "도구"로 찾는 사람(화면 공유, TV 연결)을 받으려고 보조로 둔다. 기본을 유틸리티로 하면 계산기·VPN 같은 아주 넓은 분야와 섞인다.
- 둘 다 "어린이(Kids)" 카테고리가 아니다(광고 규칙, SPEC 10번).

## 8. 저작권

```text
2026 MirrorDrop
```
- "©"는 App Store가 붙인다. 판매자 이름은 Apple 개발자 계정 이름(개인 실명)으로 따로 나온다. 실명을 넣고 싶으면 `2026 <이름>`으로 바꾼다(사용자가 정함).

## 9. 심사 메모 (App Review Information → Notes)

App Store Connect → 버전 화면 → **앱 심사 정보**. 로그인 필요는 **끔**. 연락처(이름·전화·이메일)는 심사관만 보는 칸이고 `docs/RELEASE.md`에 누가 넣는지 적혀 있다. 메모는 언어별이 아니라 하나이므로 영어로 넣고, 아래 우리말은 사용자 확인용이다. `<VIDEO_URL>`은 시연 영상 주소로 바꾼다(`docs/RELEASE.md` "시연 영상").

### 9-1. 붙여 넣을 글 (영어)

```text
MirrorDrop mirrors the iPhone screen to a Google Cast TV or streaming stick on the same Wi-Fi network. There is no sign-in or account, so no demo account is needed.

DEMO VIDEO (iPhone + TV, start to stop)
<VIDEO_URL>
If you have no Google Cast device, please watch this video: the main feature needs a Google Cast receiver (for example Chromecast with Google TV, Google TV Streamer, or a TV with Google Cast built in). Without one, the app does not crash or go blank: after a few seconds it shows "TV를 찾지 못했어요" (TV not found) with a checklist (same Wi-Fi, guest Wi-Fi / AP isolation, Local Network permission) and a button to open Settings.

HOW IT WORKS
1. Tap the Cast button or "TV 고르기" (Choose TV) and pick the TV.
2. Tap the large blue card "TV로 보내기 시작" (Start sending to TV). This is Apple's system broadcast picker (RPSystemBroadcastPickerView) limited to our Broadcast Upload Extension; tap "Start Broadcast". iOS shows its own countdown and the red screen-recording indicator while sharing (guideline 2.5.14: started only by the user in the system sheet, clearly indicated by iOS).
3. The extension encodes the screen with VideoToolbox/AVAssetWriter into HLS segments kept in memory, and a small HTTP server on the iPhone (Network.framework) serves them only to devices with private (local) addresses, at a new random path for each broadcast. The app tells the TV, through the Google Cast SDK and Google's Default Media Receiver, to play that local URL. The TV fetches the video directly from the iPhone; the screen never leaves the home Wi-Fi and nothing is recorded.
4. Stop with the red card "보내기 멈추기" (Stop sending) or the red indicator at the top of the screen.

PERMISSIONS
- Local Network: needed to discover Google Cast devices (Bonjour _googlecast._tcp) and to let the TV fetch the stream from the iPhone. Asked when the user first looks for a TV.
- Notifications (optional): one local notification, "TV 보내기가 멈췄어요" (Sending stopped), when iOS ends the broadcast, e.g. when the iPhone locks. Asked when the first broadcast starts. No remote push, no marketing.
- No background modes are used. The app uses a short finite-length background task (beginBackgroundTask) only to finish sending the play request to the TV if the user leaves the app right after starting.

ADS
- Google AdMob: a banner at the bottom of the main screen, removed while the screen is being sent (the whole screen is visible on the TV), and at most one interstitial per day before a broadcast starts (never during the first 3 broadcasts, never within 10 minutes of an unexpected stop or after opening the stop notification). On that one tap a day the start card first shows the ad; after it is closed the card is Apple's broadcast picker again and says "이제 눌러서 시작하세요" (Tap to start now), so the ad always closes before sharing begins. The picker is never triggered programmatically. No ads while sending, no app-open or rewarded ads, no ads in the extension. Ads never cover the Start or Stop button.
- This review build shows Google TEST ads: the app checks the App Store environment (StoreKit AppTransaction) and requests live ads only in apps downloaded from the App Store, so TestFlight and App Review never touch live ads. Because the first 3 broadcasts never show the interstitial, you will most likely see only the banner.
- Consent and tracking: at launch the app only refreshes Google's consent status. After the first broadcast has ended, while the app is in front, it shows Google's UMP consent form where required (EEA/UK/Switzerland) and then the App Tracking Transparency prompt, so neither interrupts the first TV setup. In regions that require consent, no ad is requested before a choice is made. Everything works if the user declines. "광고 개인정보 설정" (Ad privacy settings, shown where Google requires it) and "광고 신고" (Report an ad, opens an email to the support address) are in "고급·진단" (Advanced & Diagnostics).

WHAT MAKES IT DIFFERENT (Guideline 4.3)
- Local only: the stream goes from the iPhone directly to the TV on the same Wi-Fi. No cloud relay, no account, no analytics SDK.
- Every feature is free: no subscription, no paywall, no time limit, no watermark. Ads are the only monetization and are kept away from the TV.
- Built for families watching photos and videos: one screen with numbered steps (1 choose TV, 2 start), sound output choice (TV or phone) that can be changed while sending, TV volume and mute, a stop alert when iOS ends the broadcast, and a step-by-step guide ("사용 방법").
- Honest limits stated in the app and the description: about 4 seconds of delay, 720p, copy-protected video appears black (no DRM workaround).

MirrorDrop is an independent app, not affiliated with Google. "Google Cast" is used only to describe compatibility, and the Cast button is the official one from the Google Cast SDK.

CONTACT
kimyeoware@gmail.com
Support: https://mirrordrop-app.web.app/en/support.html
Privacy policy: https://mirrordrop-app.web.app/en/privacy.html
```

- 버튼 이름은 앱 화면 글자와 같다(`ios/MirrorDrop/UI/ContentView.swift`, `AdvancedView.swift`). 영어 화면을 만든 뒤에는 괄호 안 영어를 실제 영어 버튼 글자로 맞춘다. 광고 줄은 광고 코드(`ios/MirrorDrop/App/AdsManager.swift`, `ios/Shared/AdPolicy.swift`)의 실제 동작대로 썼다(2026-11-22): 심사·TestFlight 빌드는 시험 광고, ATT는 첫 보내기가 끝난 뒤.
- "TV를 찾지 못했어요" 화면은 실제로 TV가 없을 때 5초 뒤에 나온다(`ContentView.noDevicesGrace`).

### 9-2. 우리말 요약 (사용자 확인용, 붙여 넣지 않음)
- 시연 영상 링크: Google Cast 기기가 없는 심사관을 위해. TV가 없을 때도 앱은 멈추지 않고 "TV를 찾지 못했어요"와 확인할 것을 보여 준다.
- 쓰는 법: TV 고르기 → 큰 카드(애플의 시스템 방송 선택기, 우리 확장만 보임) → "방송 시작". iOS가 숫자 세기와 빨간 표시를 띄운다(2.5.14).
- 원리: 확장이 화면을 메모리 안 HLS 조각으로 만들고, iPhone 안 작은 서버가 집 안 주소의 기기에만, 방송마다 새 비밀 주소로 준다. TV가 직접 가져간다. 화면은 집 Wi-Fi 밖으로 안 나가고 저장도 안 한다.
- 권한: 로컬 네트워크(TV 찾기·가져가기), 알림(멈춤 알림 하나, 로컬). 백그라운드 모드 없음(재생 요청을 마저 보내는 짧은 작업만).
- 광고: 배너는 보내는 중에 숨김(화면에서 뺌), 전면은 시작 전 하루 1번(처음 3번·뜻밖에 끝난 뒤 10분·멈춤 알림으로 연 때 제외). 그날 한 번은 카드를 누르면 광고 → 닫으면 카드가 "이제 눌러서 시작하세요"로 바뀌고 한 번 더 눌러 시작. 보내는 중 광고 없음. 심사·TestFlight 빌드는 Google 시험 광고(App Store에서 받은 앱만 진짜 광고). 동의(UMP) → 추적 허용(ATT)은 첫 보내기가 끝난 뒤 앱이 앞에 있을 때, 거부해도 모든 기능.
- 다른 점(4.3): 로컬 전용·가입 없음·분석 SDK 없음, 모든 기능 무료(구독·결제벽·시간 제한·워터마크 없음), 가족용 한 화면·소리 고르기·TV 볼륨·멈춤 알림·사용 방법, 한계(약 4초·720p·DRM 검게)를 솔직히 적음.
- Google과 관계없는 독립 앱, Cast 버튼은 SDK 공식 버튼.
