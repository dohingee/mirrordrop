import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor
    @AppStorage("autoCast") private var autoCast = true
    @State private var includeAudio = AppGroup.defaults?.bool(forKey: AppGroup.includeAudioKey) ?? false
    @State private var sampleURL = SampleStream.fmp4.url
    @State private var sentURL: URL?

    var body: some View {
        NavigationStack {
            List {
                connectSection
                testASection
                testBSection
                tvSection
                Section {
                    NavigationLink("진단 (메모리 · 요청 기록 · 로그)") { DiagnosticsView() }
                    NavigationLink("지연 측정 시계") { ClockView() }
                }
            }
            .navigationTitle("MirrorDrop 테스트")
        }
        .onChange(of: monitor.readyURL) { _, url in sendMirrorIfNeeded(url) }
        .onChange(of: cast.isConnected) { _, _ in sendMirrorIfNeeded(monitor.readyURL) }
    }

    private var connectSection: some View {
        Section("1. TV 연결") {
            HStack(spacing: 12) {
                CastButtonView().frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text(cast.stateText).font(.headline)
                    Text(cast.deviceName ?? "왼쪽 버튼을 눌러 TV를 고르세요").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("처음 누르면 \"로컬 네트워크\" 허용 질문이 나옵니다. 꼭 허용하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testASection: some View {
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

    private var testBSection: some View {
        Section("테스트 B · 내 화면 보내기") {
            Toggle("앱 소리 포함 (실험)", isOn: $includeAudio)
                .disabled(monitor.isLive)
                .onChange(of: includeAudio) { _, value in
                    AppGroup.defaults?.set(value, forKey: AppGroup.includeAudioKey)
                }
            Toggle("준비되면 자동으로 TV에 띄우기", isOn: $autoCast)
            HStack(spacing: 16) {
                BroadcastPickerView().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("왼쪽 동그라미 → \"방송 시작\"").font(.subheadline)
                    Text("멈출 때도 같은 버튼(또는 상단 빨간 표시)을 누릅니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("공유 상태", value: monitor.stateText)
            LabeledContent("만든 조각", value: "\(monitor.status.segmentsProduced)개")
            if let url = monitor.status.url, monitor.isLive {
                Text(url).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Button("지금 TV에 띄우기") { sendMirror(force: true) }
                .disabled(!cast.isConnected || monitor.readyURL == nil)
            Text("TV에 화면이 뜰 때까지 이 앱에 머물러 주세요. 뜬 다음에는 다른 앱으로 가도 됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tvSection: some View {
        Section("TV 재생 상태") {
            LabeledContent("상태", value: cast.mediaText)
            if let error = cast.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("TV 재생 멈추기", role: .destructive) { cast.stopMedia() }
                .disabled(!cast.isConnected)
        }
    }

    private func sendMirrorIfNeeded(_ url: URL?) {
        guard autoCast, url != nil else { return }
        sendMirror(force: false)
    }

    private func sendMirror(force: Bool) {
        guard cast.isConnected, let url = monitor.readyURL else { return }
        if !force, sentURL == url { return }
        if cast.load(url: url, title: "내 iPhone 화면", live: true, format: .fmp4) {
            sentURL = url
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
