import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor
    @State private var selfTest = "-"
    @State private var copied = false

    /// Broadcast upload extensions are killed at roughly this footprint.
    private let memoryLimitMB = 50.0

    var body: some View {
        let s = monitor.status
        let startup = StartupReport.summary(trace: s.startup, playback: cast.startupPlayback)
        List {
            Section {
                ForEach(Array(startup.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption)
                }
                DisclosureGroup("자세한 기록 (초별·조각·요청·TV 상태)") {
                    ForEach(Array(StartupReport.details(trace: s.startup, playback: cast.startupPlayback).enumerated()),
                            id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
            } header: {
                Text("시작 기록 (처음 30초)")
            } footer: {
                Text("확장 쪽 시간은 첫 화면 프레임부터, TV 상태와 재생 위치는 TV에 재생을 요청한 때부터 잽니다. 방송을 시작하고 30초 뒤에 이 부분을 캡처해 주세요.")
            }
            Section("확장 메모리 (한도 약 \(Int(memoryLimitMB))MB)") {
                LabeledContent("지금", value: String(format: "%.1f MB", s.memoryMB))
                LabeledContent("최고", value: String(format: "%.1f MB", s.peakMemoryMB))
                ProgressView(value: min(s.peakMemoryMB / memoryLimitMB, 1))
                    .tint(s.peakMemoryMB > 40 ? .red : .green)
            }
            Section("영상 만들기") {
                LabeledContent("상태", value: monitor.stateText)
                LabeledContent("받은 화면 프레임", value: "\(s.framesIn)")
                LabeledContent("인코딩한 프레임", value: "\(s.framesEncoded) (반복 \(s.framesRepeated))")
                LabeledContent("건너뜀 / 버림", value: "\(s.framesSkipped) / \(s.framesDropped)")
                LabeledContent("만든 조각 / 보관 중", value: "\(s.segmentsProduced) / \(s.segmentsInWindow)")
                LabeledContent("마지막 조각", value: String(format: "%.2f초, %ld KB", s.lastSegmentDuration, s.lastSegmentBytes / 1024))
                LabeledContent("코덱", value: s.codecs ?? "-")
                LabeledContent("화면 방향 값", value: "\(s.orientation)")
                LabeledContent("지연 실험 (확장이 쓴 값)", value: Self.presetText(s.latencyPreset))
            }
            Section {
                LabeledContent("소리 나오는 곳 (확장이 쓰는 값)", value: Self.audioOutputText(s.audioOutput))
                LabeledContent("받은 앱 소리 묶음", value: "\(s.audioSamplesIn)")
                LabeledContent("받은 소리 형식", value: s.audioSourceFormat ?? "-")
                LabeledContent("소리 크기 (최근 1초 / 최고)",
                               value: String(format: "%.3f / %.3f", s.audioPeakRecent, s.audioPeakMax))
                LabeledContent("TV로 보낸 소리", value: Self.seconds(s.audioRealFrames))
                LabeledContent("채운 무음", value: Self.seconds(s.audioSilentFrames))
                LabeledContent("버린 소리", value: Self.seconds(s.audioDroppedFrames))
            } header: {
                Text("소리")
            } footer: {
                Text("소리 크기는 휴대폰 볼륨과 관계없이 앱에서 받은 소리의 크기입니다(0은 무음, 1은 가장 큼). \"휴대폰\"을 고르면 TV로는 무음을 보냅니다.")
            }
            Section("서버 요청 (TV가 iPhone에서 가져갔는지)") {
                LabeledContent("총 요청 수", value: "\(s.requestCount)")
                ForEach(s.clients.keys.sorted(), id: \.self) { client in
                    LabeledContent(client, value: "\(s.clients[client] ?? 0)회")
                }
                ForEach(s.recentRequests.reversed()) { entry in
                    Text("\(Self.time(entry.time)) \(entry.client) \(entry.method) \(entry.path) → \(entry.status) (\(entry.bytes)B)")
                        .font(.caption2.monospaced())
                }
                Button("iPhone 안에서 서버 점검") { runSelfTest() }
                    .disabled(s.url == nil || !monitor.isLive)
                Text(selfTest).font(.caption.monospaced())
            }
            Section("최근 오류") {
                if s.errors.isEmpty && cast.lastError == nil { Text("없음").foregroundStyle(.secondary) }
                if let error = cast.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                ForEach(Array(s.errors.reversed().enumerated()), id: \.offset) { _, line in
                    Text(DiagnosticsReport.redact(url: line)).font(.caption2.monospaced()).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("지금", value: cast.liveLagText)
            } header: {
                Text("TV 재생 위치")
            } footer: {
                Text("TV가 아는 가장 새 조각의 끝에서 얼마나 뒤를 재생하는지입니다. 인코딩 시간은 들어 있지 않습니다.")
            }
            Section("Cast 기록") {
                ForEach(Array(cast.events.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced())
                }
            }
            Section {
                ProblemReportLink(selfTest: selfTest)
                Button(copied ? "복사했어요" : "로그 전체 복사") {
                    UIPasteboard.general.string = report()
                    copied = true
                }
            } footer: {
                Text("\"문제 보내기\"를 누르면 메일·메시지 등 보낼 곳을 직접 고를 수 있습니다. 앱이 저절로 어디로 보내지는 않습니다. 접속 주소의 비밀 부분은 가려져 있습니다. 문의 메일: \(DiagnosticsReport.supportEmail)")
            }
        }
        .navigationTitle("진단")
    }

    private func runSelfTest() {
        guard let text = monitor.status.url, let url = URL(string: text) else { return }
        selfTest = "확인 중…"
        let started = Date()
        URLSession.shared.dataTask(with: url) { data, response, error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let result: String
            if let error {
                result = "실패: \(error.localizedDescription)"
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = "HTTP \(code), \(data?.count ?? 0)B, \(ms)ms"
            }
            DispatchQueue.main.async { selfTest = result }
        }.resume()
    }

    private func report() -> String {
        DiagnosticsReport.make(cast: cast, monitor: monitor, selfTest: selfTest)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String { formatter.string(from: date) }

    private static func audioOutputText(_ code: String?) -> String {
        guard let code else { return "-" }
        return AudioOutput(rawValue: code)?.label ?? code
    }

    /// 48 kHz frames as seconds.
    private static func seconds(_ frames: Int) -> String {
        String(format: "%.1f초", Double(frames) / Double(AudioTrackFormat.sampleRate))
    }

    private static func presetText(_ code: String?) -> String {
        guard let code else { return "-" }
        return LatencyPreset(rawValue: code)?.label ?? code
    }
}

/// "문제 보내기": hands the diagnostics text to the share sheet; the user picks where it goes.
struct ProblemReportLink: View {
    @EnvironmentObject private var cast: CastManager
    @EnvironmentObject private var monitor: BroadcastMonitor
    private let selfTest: String

    init(selfTest: String = "-") {
        self.selfTest = selfTest
    }

    var body: some View {
        ShareLink(item: DiagnosticsReport.make(cast: cast, monitor: monitor, selfTest: selfTest),
                  subject: Text("MirrorDrop 문제 보고"),
                  message: Text("받는 곳: \(DiagnosticsReport.supportEmail)")) {
            Label("문제 보내기", systemImage: "square.and.arrow.up")
        }
    }
}

/// Plain-text diagnostics for copying or sharing. Stream tokens are masked (CLAUDE.md invariant).
enum DiagnosticsReport {
    /// User-facing support mail (CLAUDE.md: app users see kimyeoware@gmail.com for now).
    static let supportEmail = "kimyeoware@gmail.com"

    static func make(cast: CastManager, monitor: BroadcastMonitor, selfTest: String) -> String {
        let s = monitor.status
        var lines: [String] = []
        lines.append("MirrorDrop 진단 \(Date())")
        let info = Bundle.main.infoDictionary
        lines.append("앱 \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), iOS \(UIDevice.current.systemVersion)")
        lines.append("Cast: \(cast.stateText), 기기: \(cast.deviceName ?? "-"), TV 상태: \(cast.mediaText)")
        lines.append("TV 재생 위치: \(cast.liveLagText)")
        lines.append("Cast 오류: \(cast.lastError ?? "-")")
        lines.append("확장 상태: \(monitor.stateText), 소리 출력: \(s.audioOutput ?? "-"), 지연 실험: \(s.latencyPreset ?? "-")")
        lines.append(String(format: "소리: 묶음 %ld, 형식 %@, 크기 최근 %.3f 최고 %.3f, 보냄 %ld, 무음 %ld, 버림 %ld (48kHz 프레임)",
                            s.audioSamplesIn, s.audioSourceFormat ?? "-", s.audioPeakRecent, s.audioPeakMax,
                            s.audioRealFrames, s.audioSilentFrames, s.audioDroppedFrames))
        lines.append(String(format: "메모리: 지금 %.1fMB, 최고 %.1fMB", s.memoryMB, s.peakMemoryMB))
        lines.append("프레임: 입력 \(s.framesIn), 인코딩 \(s.framesEncoded), 반복 \(s.framesRepeated), 건너뜀 \(s.framesSkipped), 버림 \(s.framesDropped)")
        lines.append("조각: \(s.segmentsProduced), 보관 \(s.segmentsInWindow), 마지막 \(s.lastSegmentDuration)s/\(s.lastSegmentBytes)B, 코덱 \(s.codecs ?? "-"), 방향 \(s.orientation)")
        lines.append("요청: \(s.requestCount), 클라이언트: \(s.clients)")
        lines.append("서버 점검: \(selfTest)")
        lines.append("--- 시작 기록 (처음 30초)")
        lines += StartupReport.summary(trace: s.startup, playback: cast.startupPlayback)
        lines += StartupReport.details(trace: s.startup, playback: cast.startupPlayback)
        lines.append("--- 요청 기록")
        lines += s.recentRequests.map { "\(DiagnosticsView.time($0.time)) \($0.client) \($0.method) \($0.path) \($0.status) \($0.bytes)B" }
        lines.append("--- 확장 오류")
        lines += s.errors
        lines.append("--- 확장 로그")
        lines += s.log
        lines.append("--- Cast 기록")
        lines += cast.events
        lines.append("--- Cast SDK 로그 (최근 80줄)")
        lines += cast.sdkLog.suffix(80)

        var tokens = cast.mirrorTokens
        if let text = s.url, let url = URL(string: text), let token = CastManager.token(of: url) {
            tokens.insert(token)
        }
        return redact(lines.joined(separator: "\n"), tokens: tokens)
    }

    /// Masks stream tokens: every known token, plus the first path part of any URL whose host is
    /// an IPv4 address (the stream server), also in JSON-escaped form (`\/`) as SDK logs print it.
    static func redact(_ text: String, tokens: Set<String>) -> String {
        var result = text
        for token in tokens where !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "…")
        }
        // http://1.2.3.4:8765/<token>/  or  http:\/\/1.2.3.4:8765\/<token>\/  →  <token> becomes …
        let pattern = #"((?:\\?/){2}[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?::[0-9]+)?\\?/)[^/\\\s"'<>]+(?=\\?/)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1…")
    }

    /// For showing a stream URL on screen without its token.
    static func redact(url: String) -> String {
        redact(url, tokens: [])
    }
}
