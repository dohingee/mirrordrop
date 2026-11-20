import SwiftUI

/// "고급·진단": the PoC test tools (sample stream, audio and latency experiments, manual cast,
/// TV playback state) plus links to diagnostics and the latency clock.
struct AdvancedView: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor
    @State private var includeAudio = AppGroup.defaults?.bool(forKey: AppGroup.includeAudioKey) ?? false
    @State private var latencyPreset = LatencyPreset.load()
    @State private var sampleURL = SampleStream.fmp4.url

    var body: some View {
        List {
            Section {
                NavigationLink("진단 (메모리 · 요청 기록 · 로그)", value: LaunchScreen.diagnostics)
                NavigationLink("지연 측정 시계", value: LaunchScreen.clock)
                ProblemReportLink()
            }
            mirrorSection
            tvSection
            sampleSection
        }
        .navigationTitle("고급·진단")
    }

    private var mirrorSection: some View {
        Section {
            Toggle("앱 소리 포함 (실험)", isOn: $includeAudio)
                .disabled(monitor.isLive)
                .onChange(of: includeAudio) { _, value in
                    AppGroup.defaults?.set(value, forKey: AppGroup.includeAudioKey)
                }
            Picker("지연 실험", selection: $latencyPreset) {
                ForEach(LatencyPreset.allCases) { Text($0.label).tag($0) }
            }
            .disabled(monitor.isLive)
            .onChange(of: latencyPreset) { _, value in value.save() }
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
            Text("내 화면 보내기 (실험 설정)")
        } footer: {
            Text("소리·지연 실험 설정은 다음 방송 시작부터 적용됩니다. 화면이 준비되면 TV에 자동으로 띄웁니다.")
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

    private var sampleSection: some View {
        Section("테스트 A · 인터넷 샘플 영상") {
            Picker("샘플", selection: $sampleURL) {
                ForEach(SampleStream.allCases) { Text($0.title).tag($0.url) }
            }
            TextField("HLS 주소", text: $sampleURL, axis: .vertical)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("TV로 보내기") {
                guard let url = URL(string: sampleURL) else { return }
                let format: CastManager.SegmentFormat = sampleURL == SampleStream.ts.url ? .ts : .fmp4
                cast.load(url: url, title: "테스트 A 샘플", live: false, format: format)
            }
            .disabled(!cast.isConnected)
        }
    }
}

enum SampleStream: String, CaseIterable, Identifiable {
    case fmp4, ts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fmp4: return "Apple bipbop (fMP4)"
        case .ts: return "Apple bipbop (TS)"
        }
    }

    var url: String {
        switch self {
        case .fmp4: return "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
        case .ts: return "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
        }
    }
}
