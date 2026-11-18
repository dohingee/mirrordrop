# 처음 설정하기 (Mac 없이 iPhone으로)

빌드·서명·업로드는 GitHub Actions의 macOS 서버가 합니다. 설치와 시험은 iPhone의 **TestFlight** 앱으로 합니다.
웹 관리 화면(Apple Developer, App Store Connect, GitHub 설정)의 입력은 Claude가 내장 브라우저로 직접 합니다.
이 문서가 빌드 순서·비밀값·비용을 적는 유일한 곳입니다. 다른 문서는 여기를 가리킵니다.

표시 안내
- 🤖 = Claude가 하는 일, ✋ = **사용자가 직접** 하는 일
- ✋는 Claude가 안전 규칙상 할 수 없는 것뿐입니다: **로그인·2단계 인증 코드**, **비밀 키 값 붙여 넣기**(API 키 `.p8` 파일 내용), 그리고 iPhone을 손에 들고 하는 일.
- 로그인할 계정
  - Apple(developer.apple.com, appstoreconnect.apple.com): **Apple 개발자 계정 주인의 Apple ID** (Bottlepost와 같은 팀)
  - GitHub: **`dohingee`** 계정
- Claude가 로그인 화면을 만나면 어느 계정인지 알려 드립니다. 로그인했다고 말해 주면 이어서 끝까지 합니다.
- 키 파일 내용·비밀번호는 채팅에 붙이지 마세요. GitHub 비밀값 화면에만 넣습니다.
- 팀 ID·키는 파일에 적지 않고 GitHub 저장소 설정(비밀값 Secrets·변수 Variables)에만 넣습니다(`CLAUDE.md` 규칙).
- 새로 만드는 것(앱 ID, 앱, API 키, 테스터 초대)은 이 설정을 해 달라는 요청 안에서 Claude가 바로 합니다. 요청에 없던 것이면 그 자리에서 한 번 묻습니다.

> 💰 **비용 안내 (Mac 시간)**
> - 저장소가 **비공개**라서 macOS 빌드 1분은 GitHub 무료 한도에서 10분으로 계산됩니다.
> - 무료 한도로 쓸 수 있는 macOS 시간은 한 달 약 200분이고, 이 계정의 앱 3개가 함께 씁니다.
> - 그래서 Mac은 **일부러 시작할 때만** 돕니다. 코드를 올리기(push)만 해서는 아무것도 돌지 않습니다.
>   - `iOS build`(`ios-build.yml`): Claude가 `ios-check-<날짜>` 태그를 올리면 시작(손 실행도 가능). 단위 테스트 + iPhone·iPad 시뮬레이터 실행 확인과 화면 캡처.
>   - `iOS TestFlight`(`ios-testflight.yml`): `testflight-<번호>` 태그로 시작(손 실행도 가능). 같은 앱 내용으로 이미 통과한 검사가 있으면 검사를 건너뛰고 업로드만 합니다.
>   - 실제 걸리는 시간은 첫 실행 뒤 이 줄에 적습니다.
> - 사용량: GitHub → **Settings** → **Billing**.

---

## 1. 🤖 팀 ID와 계약 확인
✋ 먼저 https://developer.apple.com/account 에 로그인합니다(Apple 개발자 계정 주인).

🤖 Claude가 합니다.
1. **Membership details**(멤버십 세부사항)에서 **Team ID**(영문·숫자 10자리)를 확인합니다. 5번에서 GitHub 저장소 변수에만 넣고, 파일에는 적지 않습니다.
2. App Store Connect → **비즈니스**에서 "무료 앱" 계약이 **활성**인지, 새 약관 동의 요청이 없는지 봅니다.
   - 새 약관 동의 요청이 있으면 내용을 알려 드리고 동의해도 되는지 한 번 묻습니다(동의하지 않으면 업로드가 막힙니다).

## 2. 🤖 App Group과 앱 ID 2개 등록
앱 본체와 화면 공유 확장(Broadcast Extension)은 서로 다른 앱 ID를 쓰고, **App Group**으로 상태를 주고받습니다.
자동 서명이 앱 ID는 스스로 만들 수 있지만 App Group 연결은 실패할 때가 있어 미리 만들어 둡니다.

🤖 Claude가 https://developer.apple.com/account/resources/identifiers/list 에서 만듭니다.

| 종류 | Description | Identifier | 켜는 기능 |
|---|---|---|---|
| App Group | `MirrorDrop group` | `group.com.mirrordrop.app` | — |
| App ID (앱 본체) | `MirrorDrop` | `com.mirrordrop.app` (Explicit) | **App Groups** → `group.com.mirrordrop.app` |
| App ID (화면 공유 확장) | `MirrorDrop Broadcast` | `com.mirrordrop.app.broadcast` (Explicit) | **App Groups** → `group.com.mirrordrop.app` |

- "이미 사용 중"이라고 나오면 🤖 Claude가 새 ID를 정하고 `ios/project.yml`, 워크플로, 코드의 ID를 함께 바꿉니다.

## 3. 🤖 App Store Connect에 앱 만들기
🤖 Claude가 https://appstoreconnect.apple.com → **앱** → **＋** → **신규 앱**에서 만듭니다.
- 플랫폼: **iOS**
- 이름: `MirrorDrop` (이미 있으면 `MirrorDrop - TV 화면 공유`처럼 부제를 붙임)
  - 이름에 **Chromecast, Google**은 넣지 않습니다(`docs/SPEC.md` 심사 위험 6번).
- 기본 언어: **한국어**, 번들 ID: `com.mirrordrop.app`, SKU: `mirrordrop-ios`, 사용자 액세스: **전체 액세스**

스토어 설명·스크린샷·연락처 메일은 4단계(출시)에서 넣습니다. 사용자에게 보이는 메일은 `CLAUDE.md`의 메일 규칙을 따릅니다.

## 4. App Store Connect API 키 (GitHub가 대신 업로드하는 열쇠)
같은 Apple 팀이므로 **Bottlepost가 쓰는 팀 API 키를 그대로 써도 됩니다.** 팀 키는 팀의 모든 앱에 쓸 수 있습니다.

- **Bottlepost 키를 다시 쓸 때**: ✋ 그 키의 `.p8` 파일을 보관한 곳에서 꺼내 둡니다(`.p8`은 처음 만들 때 한 번만 받을 수 있습니다). 🤖 Claude는 App Store Connect → **사용자 및 액세스** → **통합** → **App Store Connect API** → **팀 키**에서 그 키의 **키 ID**와 **Issuer ID**를 확인합니다.
- **`.p8`을 찾을 수 없을 때**: 새 키를 만듭니다.
  1. 🤖 같은 화면에서 **＋** → 이름 `GitHub Actions MirrorDrop`, 액세스 **관리자(Admin)** → 생성 (서명 인증서·프로파일을 자동으로 만들려면 관리자 권한이 필요합니다).
  2. ✋ **API 키 다운로드**를 눌러 `AuthKey_XXXXXXXXXX.p8`을 받고 안전한 곳(비밀번호 관리자 등)에 보관합니다. 비밀 키라 Claude가 받거나 열지 않습니다.
  3. 🤖 **키 ID**(10자리)와 **Issuer ID**(표 위의 긴 값)를 확인합니다.

## 5. GitHub 저장소와 비밀값
✋ https://github.com 에 **`dohingee`** 로 로그인합니다.

🤖 Claude가 `dohingee/mirrordrop`에서 확인합니다.
- 저장소가 **비공개(Private)** 인지, **Actions**가 켜져 있는지.

GitHub 비밀값은 **저장소마다 따로**입니다. Bottlepost에 넣은 값이 있어도 이 저장소에 다시 넣어야 합니다.
**Settings** → **Secrets and variables** → **Actions**

**Variables** 탭 → **New repository variable** (비밀이 아닌 값, Bottlepost와 같은 방식):

| Name | 넣을 값 | 누가 |
|---|---|---|
| `APPLE_TEAM_ID` | 1번의 Team ID | 🤖 |

**Secrets** 탭 → **New repository secret**:

| Name | 넣을 값 | 누가 |
|---|---|---|
| `ASC_KEY_ID` | 4번의 키 ID | 🤖 |
| `ASC_ISSUER_ID` | 4번의 Issuer ID | 🤖 |
| `ASC_KEY_P8` | `.p8` 파일을 메모장으로 열어 `-----BEGIN PRIVATE KEY-----`부터 `-----END PRIVATE KEY-----`까지 전부 | ✋ Claude가 이름 칸까지 채운 화면을 열어 두면 값만 붙여 넣고 **Add secret** |

## 6. 🤖 TestFlight에 첫 빌드 올리기
1. 🤖 Claude가 이 PC에서 올릴 커밋에 태그를 붙여 GitHub에 올립니다. 사람이 버튼을 누를 필요가 없습니다.
   ```bash
   t=testflight-$(date +%Y%m%d-%H%M) && git tag $t && git push origin $t
   ```
   - 손으로 하려면: GitHub → **Actions** → **iOS TestFlight** → **Run workflow**.
2. 🤖 GitHub의 Mac이 차례로 합니다. 하나라도 실패하면 올리지 않습니다.
   - 같은 앱 내용으로 통과한 검사가 없으면: 단위 테스트 → 시뮬레이터 실행 확인
   - 프로젝트 생성 → Cast SDK 받기 → 앱과 확장 둘 다 서명 → 출시용 빌드(archive) → TestFlight 업로드
3. 🤖 결과와 캡처는 `ci-results` 브랜치에 올라옵니다. 받는 명령(결과는 `ios/build/ci-results/<커밋 앞 7자리>/`, git이 무시하는 폴더):
   ```bash
   git fetch origin ci-results && rm -rf ios/build/ci-results && mkdir -p ios/build/ci-results && git archive origin/ci-results | tar -x -C ios/build/ci-results
   ```
   Claude가 PC에서 git으로 받아 확인하고, 실패하면 원인을 고칩니다. 예: `GitHub secret ASC_KEY_P8 is not set`(→ 5번), `App Group` 관련 오류(→ 2번).
4. 🤖 5~30분 뒤 빌드가 "처리 완료"인지 확인합니다. App Store Connect 화면에서 보거나, Mac 시간이 들지 않는 상태 읽기(`ios-asc-status.yml`)를 씁니다.
   ```bash
   t=asc-status-$(date +%Y%m%d-%H%M) && git tag $t && git push origin $t
   ```
   결과는 `ci-results` 브랜치의 `asc-status/status.txt`에 올라옵니다.
   - 암호화(수출 규정) 질문은 앱에 "면제"로 적혀 있어 나오지 않습니다.

## 7. iPhone에 설치
1. 🤖 App Store Connect → 앱 → **TestFlight** → **내부 테스트** 옆 **＋** → 그룹 `운영자`를 만들고, App Store Connect 계정 주인을 테스터로 넣고, 6번 빌드를 추가합니다.
2. ✋ iPhone에 **TestFlight** 앱을 설치하고 같은 Apple ID로 로그인 → MirrorDrop **설치**

## 8. ✋ 첫 실행 때 허용할 것 (iPhone)
- TV 버튼을 처음 누르면 **"로컬 네트워크의 기기를 찾고 연결하려고 합니다"** → **허용**
  - 실수로 거부했다면: 설정 → 개인정보 보호 및 보안 → **로컬 네트워크** → MirrorDrop 켜기
- iPhone과 TV(Cast 기기)는 **같은 Wi-Fi**에 있어야 합니다. 공유기의 "게스트 Wi-Fi"나 "AP 격리"가 켜져 있으면 서로 보이지 않습니다.
- 이제 `docs/POC_TEST.md` 순서대로 시험합니다.

---

## 업데이트할 때마다
1. 🤖 Claude가 코드를 고쳐 이 PC의 git에 기록하고 GitHub에 올립니다(push). 이것만으로는 Mac이 돌지 않습니다.
2. 🤖 화면이나 동작이 바뀌었으면 공통 스킬 `ios-pc-test`로 먼저 PC에서 확인합니다: `ios-check-$(date +%Y%m%d-%H%M)` 태그를 올려 `iOS build` 실행 → `ci-results` 브랜치의 시뮬레이터 캡처·테스트 결과를 받아 확인 → 문제를 고칩니다.
3. 🤖 iPhone에서 볼 빌드가 필요하면 `testflight-<번호>` 태그를 올립니다. 2번에서 통과한 같은 내용이면 검사를 다시 하지 않아 Mac 시간이 줄어듭니다. 빌드 번호는 실행할 때마다 1씩 커집니다.
4. ✋ iPhone의 TestFlight 앱에서 **업데이트**를 누르고, Claude가 준 짧은 "iPhone에서만 볼 것" 목록을 확인합니다.
