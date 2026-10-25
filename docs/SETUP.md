# 처음 설정하기 (Mac 없이 iPhone으로)

빌드·서명·업로드는 GitHub Actions의 macOS 서버가 합니다. 설치와 시험은 iPhone의 **TestFlight** 앱으로 합니다.

표시 안내
- ✋ = **직접** 하는 일, 🤖 = Claude·자동화가 하는 일
- 키 파일 내용·비밀번호는 채팅에 붙이지 마세요. GitHub 비밀값 화면에만 넣습니다.
- 이 저장소는 **공개**입니다. 팀 ID·키는 절대 파일에 적지 않고 GitHub 비밀값(Secrets)에만 넣습니다.

> 💰 공개 저장소라서 GitHub Actions의 macOS 빌드 시간은 **무료**입니다(비공개 저장소처럼 10배로 계산되지 않음).

이미 Bottlepost에서 Apple 개발자 계정·API 키를 만들었다면 1번과 4번은 그 값을 그대로 써도 됩니다.

---

## 1. ✋ 팀 ID 확인
1. https://developer.apple.com/account 에 로그인합니다.
2. **Membership details**(멤버십 세부사항)에서 **Team ID**(영문·숫자 10자리)를 메모합니다. 5번에서 씁니다.
3. App Store Connect → **비즈니스**에서 "무료 앱" 계약이 **활성**인지, 새 약관 동의 요청이 없는지 확인합니다.

## 2. ✋ App Group과 앱 ID 2개 등록
앱 본체와 화면 공유 확장(Broadcast Extension)은 서로 다른 앱 ID를 쓰고, **App Group**으로 상태를 주고받습니다.
자동 서명이 앱 ID는 스스로 만들 수 있지만, App Group 연결은 실패하는 경우가 있어 미리 손으로 만들어 둡니다.

https://developer.apple.com/account/resources/identifiers/list 에서:

**(1) App Group 만들기**
1. **＋** → **App Groups** → Continue
2. Description: `MirrorDrop group`, Identifier: `group.com.mirrordrop.app` → Continue → Register

**(2) 앱 본체 ID**
1. **＋** → **App IDs** → **App** → Continue
2. Description: `MirrorDrop`, Bundle ID: **Explicit** → `com.mirrordrop.app`
3. Capabilities에서 **App Groups** 체크 → 옆 **Configure** → `group.com.mirrordrop.app` 체크 → Continue
4. Continue → Register

**(3) 화면 공유 확장 ID**
1. **＋** → **App IDs** → **App** → Continue
2. Description: `MirrorDrop Broadcast`, Bundle ID: **Explicit** → `com.mirrordrop.app.broadcast`
3. **App Groups** 체크 → **Configure** → `group.com.mirrordrop.app` 체크 → Continue
4. Continue → Register

> "이미 사용 중"이라고 나오면 Claude에게 알려 주세요. 🤖 Claude가 `ios/project.yml`, 워크플로, 코드의 ID를 함께 바꿉니다.

## 3. ✋ App Store Connect에 앱 만들기
1. https://appstoreconnect.apple.com → **앱** → **＋** → **신규 앱**
2. 입력
   - 플랫폼: **iOS**
   - 이름: `MirrorDrop` (이미 있으면 `MirrorDrop - TV 화면 공유`처럼 부제를 붙입니다)
     - 이름에 **Chromecast, Google**은 넣지 않습니다(상표 문제로 심사 거절 위험).
   - 기본 언어: **한국어**
   - 번들 ID: `com.mirrordrop.app`
   - SKU: `mirrordrop-ios` (아무 값이나 됩니다)
   - 사용자 액세스: **전체 액세스**
3. **생성**을 누릅니다. 스토어 설명·스크린샷은 나중(4단계)에 합니다.

## 4. ✋ App Store Connect API 키 (GitHub가 대신 업로드하는 열쇠)
1. App Store Connect → **사용자 및 액세스** → **통합** → **App Store Connect API** → **팀 키**
2. **＋** → 이름 `GitHub Actions MirrorDrop`, 액세스 **관리자(Admin)** → 생성
   - 서명 인증서·프로파일을 자동으로 만들려면 관리자 권한이 필요합니다.
3. **API 키 다운로드** → `AuthKey_XXXXXXXXXX.p8` (한 번만 받을 수 있으니 안전한 곳에 보관)
4. **Issuer ID**(표 위의 긴 값)와 **키 ID**(10자리)를 메모합니다.

## 5. ✋ GitHub 비밀값 등록
GitHub `dohingee/mirrordrop` → **Settings** → **Secrets and variables** → **Actions** → **Secrets** 탭 → **New repository secret**으로 4개를 만듭니다.

| Name | 넣을 값 |
|---|---|
| `ASC_KEY_ID` | 4번의 키 ID |
| `ASC_ISSUER_ID` | 4번의 Issuer ID |
| `ASC_KEY_P8` | `.p8` 파일을 메모장으로 열어 `-----BEGIN PRIVATE KEY-----`부터 `-----END PRIVATE KEY-----`까지 전부 |
| `APPLE_TEAM_ID` | 1번의 Team ID |

> Team ID는 비밀번호는 아니지만, 공개 저장소의 빌드 기록에 그대로 찍히지 않도록 **Secrets**에 넣습니다(Variables 아님).

## 6. TestFlight에 빌드 올리기
1. ✋ GitHub → **Actions** → 왼쪽 **iOS TestFlight** → **Run workflow** → 초록 버튼
   - Claude에게 "TestFlight 빌드 돌려 줘"라고 해도 됩니다.
2. 🤖 15~25분 동안: 프로젝트 생성 → Cast SDK 받기 → 앱과 확장 둘 다 서명 → 업로드
   - 실패하면 실행 화면 위쪽에 원인이 나옵니다. 예: `GitHub secret ASC_KEY_P8 is not set`, `App Group` 관련 오류(→ 2번 확인).
3. ✋ 5~30분 뒤 App Store Connect → 앱 → **TestFlight** 탭에 빌드가 "처리 완료"로 보입니다.
   - 암호화(수출 규정) 질문은 앱에 "면제"로 적혀 있어 나오지 않습니다.

## 7. ✋ iPhone에 설치
1. App Store Connect → 앱 → **TestFlight** → **내부 테스트** 옆 **＋** → 그룹 이름 `운영자`
2. 그룹에 본인(App Store Connect 계정 이메일)을 테스터로 추가하고, **빌드** 탭에서 6번 빌드를 추가합니다.
3. iPhone에 **TestFlight** 앱을 설치하고 같은 Apple 계정으로 로그인 → MirrorDrop **설치**

## 8. ✋ 첫 실행 때 허용할 것
- TV 버튼을 처음 누르면 **"로컬 네트워크의 기기를 찾고 연결하려고 합니다"** → **허용**
  - 실수로 거부했다면: 설정 → 개인정보 보호 및 보안 → **로컬 네트워크** → MirrorDrop 켜기
- iPhone과 TV(Cast 기기)는 **같은 Wi-Fi**에 있어야 합니다. 공유기의 "게스트 Wi-Fi"나 "AP 격리"가 켜져 있으면 서로 보이지 않습니다.
- 이제 `docs/POC_TEST.md` 순서대로 시험합니다.

---

## 업데이트할 때마다
1. 🤖 Claude가 코드를 고쳐 push → **iOS build**가 시뮬레이터 빌드·테스트를 자동으로 돌립니다.
2. ✋ 기기에서 볼 빌드가 필요할 때 **iOS TestFlight**를 실행합니다. 빌드 번호는 실행할 때마다 1씩 커집니다.
3. ✋ iPhone의 TestFlight 앱에서 **업데이트**를 누릅니다.
