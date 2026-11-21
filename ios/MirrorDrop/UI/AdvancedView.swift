import SwiftUI

/// "고급·진단": links to diagnostics and the delay clock, the stream state, a manual "send to TV
/// again", the TV playback state, and the privacy policy / support pages.
/// Build 17 (first App Store release) removed the PoC tools: "테스트 A · 인터넷 샘플 영상" (it played
/// Apple's sample streams from the internet) and the "지연 실험" picker (L3 is the fixed setting,
/// docs/PLAN.md 2단계). Reviewers should see no unfinished or experimental features (guideline 2.1).
struct AdvancedView: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor

    var body: some View {
        List {
            Section {
                NavigationLink("진단 (메모리 · 요청 기록 · 로그)", value: LaunchScreen.diagnostics)
                NavigationLink("지연 측정 시계", value: LaunchScreen.clock)
                ProblemReportLink()
            }
            mirrorSection
            tvSection
            Section("정보") {
                Link("개인정보 처리방침", destination: AppLinks.privacyPolicy)
                Link("문의·도움말 (웹)", destination: AppLinks.support)
                LabeledContent("버전", value: AppLinks.versionText)
            }
        }
        .navigationTitle("고급·진단")
    }

    private var mirrorSection: some View {
        Section {
            LabeledContent("공유 상태", value: monitor.stateText)
            LabeledContent("만든 조각", value: "\(monitor.status.segmentsProduced)개")
            if let url = monitor.status.url, monitor.isLive {
                // Token masked: people share screenshots of this screen.
                Text(DiagnosticsReport.redact(url: url)).font(.caption2.monospaced())
            }
            Button("지금 TV에 띄우기") {
                if let url = monitor.readyURL { cast.castMirror(url, revision: monitor.status.urlRevision, force: true) }
            }
            .disabled(!cast.isConnected || monitor.readyURL == nil)
        } header: {
            Text("내 화면 보내기")
        } footer: {
            Text("화면이 준비되면 TV에 자동으로 띄웁니다. TV에 안 나올 때만 \"지금 TV에 띄우기\"를 눌러 보세요. 소리 나오는 곳(TV·휴대폰)은 첫 화면에서 보내는 중에도 바꿀 수 있어요.")
        }
    }

    private var tvSection: some View {
        Section("TV 재생 상태") {
            LabeledContent("TV", value: cast.deviceName ?? cast.stateText)
            LabeledContent("상태", value: cast.mediaText)
            if let error = cast.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("TV 재생 멈추기", role: .destructive) { cast.stopMedia() }
                .disabled(!cast.isConnected)
        }
    }
}

/// Public web pages (Firebase Hosting, web/hosting/) and the version line. The host must match the
/// deployed Firebase project (docs/RELEASE.md "웹 페이지"): change it here and in docs/store/ko.md together.
enum AppLinks {
    static let site = URL(string: "https://mirrordrop-app.web.app/")!
    static let privacyPolicy = URL(string: "https://mirrordrop-app.web.app/privacy.html")!
    static let support = URL(string: "https://mirrordrop-app.web.app/support.html")!

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
    }
}
