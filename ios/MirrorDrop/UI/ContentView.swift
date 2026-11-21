import SwiftUI
import UIKit

/// The one screen a first-time user needs: ① pick a TV, ② start sending, see what is happening.
struct ContentView: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor
    @EnvironmentObject private var stopAlert: StopAlertCenter
    @State private var path = LaunchScreen.fromArguments?.navigationPath ?? []
    @StateObject private var phoneVolume = PhoneVolumeMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var audioOutput = AudioOutput.load()
    @AppStorage("volumeTipSeen") private var volumeTipSeen = false
    /// Slider position while dragging; the TV's reported volume otherwise.
    @State private var tvVolumeDraft: Float?
    /// Briefly outlines the start card after the "TV 보내기가 멈췄어요" notification was tapped.
    @State private var highlightStartCard = false
    /// Hides the "처음이세요?" row once the guide was opened (the footer link stays).
    @AppStorage(UsageGuideView.seenKey) private var usageGuideSeen = false
    private static let startCardID = "startCard"

    /// Discovery needs a few seconds after launch before "no devices" means anything.
    private let noDevicesGrace: TimeInterval = 5

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard
                        if !usageGuideSeen { guideRow }
                        if showsNoTVHelp { noTVHelpCard }
                        tvCard
                        soundCard
                        broadcastCard.id(Self.startCardID)
                        noticeCard
                        footer
                    }
                    .padding(16)
                }
                // The user tapped the notification (also when it launched the app).
                .onAppear { showStartCardIfAsked(proxy) }
                .onChange(of: stopAlert.wantsStartCard) { _, _ in showStartCardIfAsked(proxy) }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("MirrorDrop")
            .navigationDestination(for: LaunchScreen.self) { screen in
                switch screen {
                case .advanced: AdvancedView()
                case .guide: UsageGuideView()
                case .diagnostics: DiagnosticsView()
                case .clock: ClockView()
                }
            }
        }
        // Casting when the stream is ready (and clearing the TV when it ends) is done by
        // MirrorCastCoordinator, which also runs while the app is in the background.
        .onAppear { phoneVolume.start() }
        .onChange(of: scenePhase) { _, phase in
            // Only while the app is in front (KVO needs an active audio session).
            if phase == .active { phoneVolume.start() } else { phoneVolume.stop() }
            // The user is here now; the main screen says the same thing.
            if phase == .active { stopAlert.clearDelivered() }
        }
        .onChange(of: monitor.isLive) { _, live in
            if live {
                // Asked here, not at launch: now the user knows what the notification is for.
                stopAlert.requestPermissionIfNeeded()
                stopAlert.clearDelivered()
            }
        }
    }

    /// Back to the main screen, scroll to the start card and outline it for a moment.
    private func showStartCardIfAsked(_ proxy: ScrollViewProxy) {
        guard stopAlert.wantsStartCard else { return }
        stopAlert.wantsStartCard = false
        path = []
        // After a pop from another screen has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { proxy.scrollTo(Self.startCardID, anchor: .center) }
            withAnimation { highlightStartCard = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { highlightStartCard = false }
            }
        }
    }

    // MARK: - Status

    private enum Tone { case action, progress, ok, problem }

    private struct Status {
        var text: String
        var detail: String?
        var tone: Tone
        var offersRecast = false
    }

    private var status: Status {
        if cast.connection == .connecting {
            return Status(text: "TV에 연결하는 중…", tone: .progress)
        }
        if monitor.stoppedUnexpectedly {
            return Status(text: "TV 보내기가 멈췄어요",
                          detail: "아래 ② 버튼으로 다시 시작하세요. (iPhone이 잠기면 TV 보내기가 끝나요.)",
                          tone: .problem)
        }
        if monitor.failedRecently && !monitor.isLive {
            return Status(text: "화면 보내기를 시작하지 못했어요",
                          detail: "② 버튼을 눌러 다시 시작해 주세요.", tone: .problem)
        }
        guard cast.isConnected else {
            let ready = monitor.isLive ? " 화면은 준비됐어요." : ""
            if showsNoTVHelp {
                return Status(text: "TV를 찾지 못했어요", detail: "아래 확인할 것을 봐 주세요.", tone: .problem)
            }
            if cast.connection == .noDevices {
                return Status(text: "TV를 찾는 중…", detail: "같은 Wi-Fi에 있는 TV를 찾고 있어요.", tone: .progress)
            }
            return Status(text: "① TV를 골라 주세요", detail: "TV 버튼을 눌러 화면을 보낼 TV를 고르세요." + ready, tone: .action)
        }
        guard monitor.isLive else {
            return Status(text: "② 보내기를 시작하세요", detail: "아래 큰 버튼을 누른 다음 \"방송 시작\"을 누르세요.", tone: .action)
        }
        guard let ready = monitor.readyURL else {
            return Status(text: "화면을 준비하는 중…", detail: "몇 초 뒤 TV에 나와요. 다른 앱으로 가도 돼요.", tone: .progress)
        }
        guard cast.loadedMirrorURL == ready else {
            // Not sent to this TV (another video was played, or the request could not be sent).
            return Status(text: "TV에 내 화면이 나오지 않고 있어요", detail: "\"다시 TV에 띄우기\"를 눌러 주세요.",
                          tone: .problem, offersRecast: true)
        }
        switch cast.tvPlayback {
        case .playing:
            return Status(text: "TV에 보내는 중", detail: "이제 다른 앱으로 가도 됩니다. 멈출 때는 ② 버튼을 누르세요.", tone: .ok)
        case .failed:
            return Status(text: "TV가 화면을 틀지 못했어요", detail: "\"다시 TV에 띄우기\"를 눌러 보세요.",
                          tone: .problem, offersRecast: true)
        case .ended, .paused:
            return Status(text: "TV 재생이 멈췄어요", detail: "\"다시 TV에 띄우기\"를 누르면 다시 나옵니다.",
                          tone: .problem, offersRecast: true)
        case .none, .loading:
            return Status(text: "TV에 띄우는 중…", detail: "몇 초 걸려요. 다른 앱으로 가도 돼요.", tone: .progress)
        }
    }

    private var showsNoTVHelp: Bool {
        guard cast.connection == .noDevices, let since = cast.noDevicesSince else { return false }
        return monitor.now.timeIntervalSince(since) >= noDevicesGrace
    }

    private var statusCard: some View {
        let status = self.status
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon(status.tone)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.text).font(.title3.bold())
                    if let detail = status.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if status.offersRecast, let url = monitor.readyURL {
                Button {
                    cast.castMirror(url, revision: monitor.status.urlRevision, force: true)
                } label: {
                    Label("다시 TV에 띄우기", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusIcon(_ tone: Tone) -> some View {
        switch tone {
        case .action:
            Image(systemName: "hand.point.right.fill").font(.title2).foregroundStyle(.tint)
        case .progress:
            ProgressView().controlSize(.regular).frame(width: 28, height: 28)
        case .ok:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        }
    }

    /// First-time users: a way into the guide, until it was opened once.
    private var guideRow: some View {
        NavigationLink(value: LaunchScreen.guide) {
            HStack(spacing: 12) {
                Image(systemName: "book.fill").font(.title3).foregroundStyle(.tint)
                Text("처음이세요? 사용 방법 보기").font(.body.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - ① TV

    private var tvCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("① TV 연결").font(.headline)
            HStack(spacing: 12) {
                // The SDK's own Cast button (not redrawn).
                CastButtonView().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cast.isConnected ? (cast.deviceName ?? "TV") : tvStateText).font(.body.weight(.semibold))
                    // The Cast button hides itself while no TV is found, so do not point at it then.
                    Text(cast.isConnected ? "연결됨"
                         : cast.connection == .noDevices ? "TV를 찾으면 여기에 버튼이 나타나요"
                         : "왼쪽 버튼을 눌러 TV를 고르세요")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(cast.isConnected ? "바꾸기" : "TV 고르기") { cast.presentDeviceChooser() }
                    .buttonStyle(.bordered)
                    .disabled(cast.connection == .noDevices)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var tvStateText: String {
        switch cast.connection {
        case .noDevices: return "TV를 찾지 못함"
        case .notConnected: return "TV를 고르지 않음"
        case .connecting: return "연결하는 중…"
        case .connected: return "연결됨"
        }
    }

    // MARK: - Sound

    /// AirPlay-like: choose where the sound comes out, changeable at any time (also while sending).
    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("소리 나오는 곳").font(.headline)
            Picker("소리 나오는 곳", selection: $audioOutput) {
                ForEach(AudioOutput.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: audioOutput) { _, value in
                value.save()
                AudioOutput.postChanged()
            }
            switch audioOutput {
            case .tv:
                if !volumeTipSeen {
                    volumeTip
                } else if phoneVolume.isSilent {
                    Label("휴대폰 소리 꺼짐 ✓", systemImage: "speaker.slash.fill")
                        .font(.subheadline).foregroundStyle(.green)
                } else {
                    Text("iPhone 옆 볼륨 버튼으로 휴대폰 볼륨을 끝까지 내리면 TV에서만 소리가 나요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if cast.isConnected, let volume = cast.tvVolume {
                    tvVolumeRow(volume)
                }
            case .phone:
                Text("TV는 화면만 보여 주고 소리는 휴대폰에서 나요.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Shown once (until "알겠어요"): most people press the side volume buttons, which always change
    /// the phone's own volume (CastManager keeps them off the TV volume so they act the same everywhere).
    private var volumeTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("볼륨 버튼 = 휴대폰 소리. 끝까지 내려 두면 TV에서만 소리가 나요.",
                  systemImage: "speaker.wave.1")
            Label("TV 소리 = TV 리모컨으로, 또는 TV에 연결되면 아래에 나오는 TV 볼륨 막대로 바꿔요.", systemImage: "tv")
            Button("알겠어요") { volumeTipSeen = true }
                .buttonStyle(.bordered)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// TV volume slider and mute button (the TV's own volume, through Google Cast).
    private func tvVolumeRow(_ volume: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    cast.setTVMuted(!cast.tvMuted)
                } label: {
                    Image(systemName: cast.tvMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28)
                }
                .accessibilityLabel(cast.tvMuted ? "TV 소리 켜기" : "TV 소리 끄기")
                Slider(value: Binding(get: { Double(tvVolumeDraft ?? volume) },
                                      set: { value in
                                          tvVolumeDraft = Float(value)
                                          cast.setTVVolume(Float(value))
                                      }),
                       in: 0...1, step: 0.05,
                       onEditingChanged: { editing in
                           if !editing { tvVolumeDraft = nil }
                       })
                .accessibilityLabel("TV 볼륨")
            }
            Text(cast.tvMuted ? "TV 소리 꺼짐" : "TV 볼륨")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var noTVHelpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이것을 확인해 주세요").font(.headline)
            helpRow("wifi", "iPhone과 TV가 같은 Wi-Fi에 연결돼 있나요?")
            helpRow("tv", "TV(또는 TV에 꽂은 스틱)가 켜져 있나요?")
            helpRow("person.2.slash", "게스트 Wi-Fi나 공유기의 \"AP 격리\"(기기끼리 서로 못 보게 막는 설정)가 켜져 있으면 TV를 찾을 수 없어요.")
            helpRow("lock.shield", "설정 앱에서 MirrorDrop의 \"로컬 네트워크\"가 켜져 있어야 해요.")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("설정 열기", systemImage: "gear").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("Google Cast를 지원하는 TV·스틱에서 쓸 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func helpRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    // MARK: - ② Broadcast

    private var broadcastCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("② 화면 보내기").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(monitor.isLive ? Color.red : Color.accentColor)
                VStack(spacing: 4) {
                    Spacer()
                    Text(monitor.isLive ? "보내기 멈추기" : "TV로 보내기 시작").font(.title3.bold())
                    Text(monitor.isLive ? "누른 다음 \"방송 중단\"을 누르세요" : "누른 다음 \"방송 시작\"을 누르세요")
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .padding(.bottom, 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // On top so the system picker itself receives the tap (its button fills the card).
                BroadcastPickerView(glyphColor: .white)
                    .accessibilityLabel(monitor.isLive ? "보내기 멈추기" : "TV로 보내기 시작")
            }
            .frame(height: 160)
            Text("멈출 때는 이 버튼이나 화면 위쪽의 빨간 표시를 누릅니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange, lineWidth: 3)
                .opacity(highlightStartCard ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("TV로 보낼 때 iPhone 화면 전체가 TV에 보입니다. 알림·메시지도 함께 보일 수 있어요.",
                  systemImage: "eye")
            Label("저작권 보호 영상(넷플릭스 등)은 TV에 검게 나옵니다.", systemImage: "film")
            Label("화면은 집 Wi-Fi 안에서만 TV로 갑니다. 인터넷으로 나가지 않아요.", systemImage: "house")
            Label("iPhone이 잠기면 TV 보내기가 끝나요. 오래 볼 때는 설정 → 디스플레이 및 밝기 → 자동 잠금을 '안 함'으로 바꾸세요. (저전력 모드가 켜져 있으면 바꿀 수 없어요.)",
                  systemImage: "lock")
            Label("유튜브처럼 앱 안에 TV 전송(Cast) 버튼이 있으면 그 버튼을 쓰세요. 폰을 잠그거나 다른 앱으로 가도 TV에서 계속 나와요.",
                  systemImage: "play.tv")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                ProblemReportLink()
                Spacer()
                NavigationLink("사용 방법", value: LaunchScreen.guide)
                Text("·").foregroundStyle(.secondary)
                NavigationLink("고급·진단", value: LaunchScreen.advanced)
            }
            .font(.subheadline)
            Text("Google Cast 지원 TV에서 쓸 수 있습니다. MirrorDrop은 Google과 관계없는 독립 앱입니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Screens reachable from the main screen. `-MDScreen diagnostics|clock|advanced|guide` opens one at
/// launch for CI screenshots (.github/scripts/ios-launch-check.sh); any other value, e.g. `main`,
/// keeps the main screen. Launch arguments land in UserDefaults' volatile argument domain, so a
/// normal launch has no value here and the path starts empty.
enum LaunchScreen: String, Hashable {
    case advanced, diagnostics, clock, guide

    static var fromArguments: LaunchScreen? {
        UserDefaults.standard.string(forKey: "MDScreen").flatMap(LaunchScreen.init(rawValue:))
    }

    /// Diagnostics and the clock live under the advanced screen, so Back leads there; the guide
    /// opens straight from the main screen.
    var navigationPath: [LaunchScreen] {
        switch self {
        case .advanced, .guide: return [self]
        case .diagnostics, .clock: return [.advanced, self]
        }
    }
}
