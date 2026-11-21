import SwiftUI
import UIKit

/// "사용 방법": step-by-step guide a middle-school student can follow. Button and label names are
/// copied from the real screens (ContentView, the notification in Shared/StopAlert.swift); keep them
/// in sync when those change. Texts of iOS's own screens (broadcast sheet, permission prompts,
/// Settings paths, the red indicator) are written from Apple's Korean UI as far as known and are
/// NOT yet checked on a device (docs/POC_TEST.md "사용 방법").
struct UsageGuideView: View {
    /// UserDefaults.standard flag: the guide was opened once (hides the main screen's "처음이세요?" row).
    static let seenKey = "usageGuideSeen"
    @AppStorage(UsageGuideView.seenKey) private var seen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iPhone 화면을 TV에 그대로 보여 주는 앱이에요. 아래 순서대로 하면 돼요.")
                    .font(.body)
                    .padding(.horizontal, 4)
                prepare
                connectTV
                startSending
                goToApp
                sound
                stopSending
                goodToKnow
                troubleshooting
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("사용 방법")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seen = true }
    }

    // MARK: - Sections

    private var prepare: some View {
        card("준비") {
            step(nil, "tv", "TV를 켜요. Google Cast를 지원하는 TV나, TV에 꽂은 Google Cast 스틱이어야 해요.")
            step(nil, "wifi", "iPhone과 TV를 **같은 Wi-Fi**에 연결해요.")
            step(nil, "lock.shield", "MirrorDrop을 처음 켜면 iPhone이 **로컬 네트워크** 사용을 허용할지 물어요. **허용**을 눌러야 TV를 찾을 수 있어요.")
            step(nil, "gear", "실수로 \"허용 안 함\"을 눌렀다면: **설정 → MirrorDrop → 로컬 네트워크**를 켜세요.")
            settingsButton
        }
    }

    private var connectTV: some View {
        card("① TV 연결") {
            step(1, "hand.tap", "첫 화면의 **① TV 연결** 칸에서 **TV 고르기** 버튼(또는 그 왼쪽의 TV 모양 버튼)을 눌러요.")
            step(2, "list.bullet", "나온 목록에서 내 TV 이름을 눌러요.")
            step(3, "checkmark.circle", "TV 이름 아래에 **연결됨**이 보이면 끝이에요. 다른 TV로 바꾸려면 **바꾸기**를 눌러요.")
            note("TV를 찾기 전에는 TV 고르기 버튼을 누를 수 없어요. 몇 초 기다려 주세요. 계속 못 찾으면 아래 \"안 될 때\"를 보세요.")
        }
    }

    private var startSending: some View {
        card("② 화면 보내기") {
            step(1, "hand.tap", "첫 화면 아래쪽 **② 화면 보내기** 칸의 큰 버튼 **TV로 보내기 시작**을 눌러요.")
            step(2, "rectangle.on.rectangle", "iPhone이 아래에서 창을 하나 띄워요. **MirrorDrop**이 골라져 있는지 보고(아니면 MirrorDrop을 눌러요), **방송 시작**을 눌러요.")
            step(3, "timer", "버튼에 3, 2, 1 숫자가 나온 뒤 보내기가 시작돼요. 창 바깥을 눌러 창을 닫아요.")
            step(4, "tv", "몇 초 뒤 TV에 iPhone 화면이 나와요. 첫 화면 맨 위에 **TV에 보내는 중**이 보이면 잘 되고 있는 거예요.")
            step(nil, "bell", "처음 보낼 때 알림을 허용할지 물어요. **허용**하면 보내기가 멈췄을 때 알려 줘요.")
        }
    }

    private var goToApp: some View {
        card("보고 싶은 앱으로 가기") {
            step(nil, "apps.iphone", "보내기를 시작했으면 홈 화면으로 나가서 사진, 영상, 게임 등 보고 싶은 앱을 열어요. TV가 나오기 전에 나가도 돼요.")
            step(nil, "eye", "iPhone 화면에 보이는 것은 **모두** TV에도 보여요. 알림·메시지도 보일 수 있으니 조심하세요.")
        }
    }

    private var sound: some View {
        card("소리") {
            step(nil, "speaker.wave.2", "첫 화면의 **소리 나오는 곳**에서 고를 수 있어요. 보내는 중에도 바꿀 수 있어요.")
            step(nil, "tv", "**TV**: 소리가 TV로 가요. 그런데 iPhone에서도 소리가 같이 나요. TV에서만 들으려면 iPhone 옆 볼륨 버튼으로 **iPhone 볼륨을 끝까지 내리세요.** 볼륨 버튼은 언제나 iPhone 소리만 바꿔요. TV 소리는 바뀌지 않아요.")
            step(nil, "slider.horizontal.3", "TV 소리 크기는 **TV 리모컨**으로 바꾸거나, TV에 연결돼 있을 때 MirrorDrop의 **TV 볼륨** 막대로 바꿔요. 스피커 버튼을 누르면 TV 소리가 꺼져요.")
            step(nil, "iphone", "**휴대폰**: TV에는 화면만 나오고 소리는 iPhone에서만 나요.")
        }
    }

    private var stopSending: some View {
        card("멈추기") {
            step(nil, "record.circle", "화면 맨 위의 **빨간 표시**를 누르고, 멈출지 묻는 창에서 **중단**을 눌러요.")
            step(nil, "stop.circle", "또는 MirrorDrop 첫 화면의 빨간 버튼 **보내기 멈추기**를 누르고 **방송 중단**을 눌러요.")
            step(nil, "switch.2", "제어 센터에 **화면 기록** 버튼을 넣어 두었다면 그 버튼을 눌러도 멈춰요.")
        }
    }

    private var goodToKnow: some View {
        card("알아 두세요") {
            step(nil, "clock", "TV 화면은 iPhone보다 **약 4초 늦게** 나와요. 빠르게 반응해야 하는 게임에는 맞지 않아요.")
            step(nil, "waveform.path", "보내기를 시작하고 처음 몇 초는 화면이 덜 부드러울 수 있어요. 곧 괜찮아져요.")
            step(nil, "lock", "**iPhone이 잠기면 TV 보내기가 끝나요.** 알림을 허용했다면 \"TV 보내기가 멈췄어요\" 알림이 와요. 알림을 누르고 ② 버튼으로 다시 시작하세요.")
            step(nil, "lock.open", "오래 볼 때는 **설정 → 디스플레이 및 밝기 → 자동 잠금 → 안 함**으로 바꾸세요. (저전력 모드가 켜져 있으면 바꿀 수 없어요.)")
            step(nil, "film", "저작권 보호 영상(넷플릭스 등)은 TV에 **검게** 나와요. iPhone이 막는 것이라 고칠 수 없어요.")
            step(nil, "play.tv", "유튜브처럼 앱 안에 **TV 전송(Cast) 버튼**이 있으면 그 버튼을 쓰세요. 폰을 잠그거나 다른 앱으로 가도 TV에서 계속 나와요.")
            step(nil, "house", "화면은 집 Wi-Fi 안에서만 TV로 가요. 인터넷으로 나가지 않아요.")
        }
    }

    private var troubleshooting: some View {
        card("안 될 때") {
            Text("TV를 못 찾을 때").font(.subheadline.bold())
            step(nil, "wifi", "iPhone과 TV가 같은 Wi-Fi에 연결돼 있나요?")
            step(nil, "tv", "TV(또는 TV에 꽂은 스틱)가 켜져 있나요?")
            step(nil, "person.2.slash", "게스트 Wi-Fi나 공유기의 \"AP 격리\"(기기끼리 서로 못 보게 막는 설정)가 켜져 있으면 TV를 찾을 수 없어요.")
            step(nil, "lock.shield", "설정 앱에서 MirrorDrop의 \"로컬 네트워크\"가 켜져 있어야 해요.")
            settingsButton
            Text("TV에 화면이 안 나올 때").font(.subheadline.bold()).padding(.top, 4)
            step(nil, "checkmark.circle", "첫 화면 **① TV 연결**에 **연결됨**이 보이는지 확인해요.")
            step(nil, "arrow.clockwise", "첫 화면에 **다시 TV에 띄우기** 버튼이 보이면 눌러요.")
            step(nil, "arrow.triangle.2.circlepath", "그래도 안 되면 보내기를 멈췄다가 다시 시작해요.")
            step(nil, "square.and.arrow.up", "계속 안 되면 **문제 보내기**로 기록을 보내 주세요. 화면 내용은 들어가지 않아요.")
            ProblemReportLink()
                .font(.subheadline)
        }
    }

    // MARK: - Building blocks

    private var settingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("설정 열기", systemImage: "gear").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// One step: an optional number, an SF Symbol and a short sentence (`**bold**` works).
    private func step(_ number: Int?, _ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
            }
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
