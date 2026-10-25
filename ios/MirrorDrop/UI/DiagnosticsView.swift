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
        List {
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
                LabeledContent("앱 소리", value: s.audioEnabled ? "켜짐 (샘플 \(s.audioSamplesIn))" : "꺼짐")
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
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.red)
                }
            }
            Section("Cast 기록") {
                ForEach(Array(cast.events.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced())
                }
            }
            Section {
                Button(copied ? "복사했어요" : "로그 전체 복사") {
                    UIPasteboard.general.string = report()
                    copied = true
                }
            } footer: {
                Text("복사한 내용을 그대로 Claude에게 붙여 넣으면 됩니다. 접속 주소의 비밀 토큰은 빠져 있습니다.")
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
        let s = monitor.status
        var lines: [String] = []
        lines.append("MirrorDrop 진단 \(Date())")
        let info = Bundle.main.infoDictionary
        lines.append("앱 \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), iOS \(UIDevice.current.systemVersion)")
        lines.append("Cast: \(cast.stateText), 기기: \(cast.deviceName ?? "-"), TV 상태: \(cast.mediaText)")
        lines.append("Cast 오류: \(cast.lastError ?? "-")")
        lines.append("확장 상태: \(monitor.stateText), 오디오: \(s.audioEnabled)")
        lines.append(String(format: "메모리: 지금 %.1fMB, 최고 %.1fMB", s.memoryMB, s.peakMemoryMB))
        lines.append("프레임: 입력 \(s.framesIn), 인코딩 \(s.framesEncoded), 반복 \(s.framesRepeated), 건너뜀 \(s.framesSkipped), 버림 \(s.framesDropped)")
        lines.append("조각: \(s.segmentsProduced), 보관 \(s.segmentsInWindow), 마지막 \(s.lastSegmentDuration)s/\(s.lastSegmentBytes)B, 코덱 \(s.codecs ?? "-"), 방향 \(s.orientation)")
        lines.append("요청: \(s.requestCount), 클라이언트: \(s.clients)")
        lines.append("서버 점검: \(selfTest)")
        lines.append("--- 요청 기록")
        lines += s.recentRequests.map { "\(Self.time($0.time)) \($0.client) \($0.method) \($0.path) \($0.status) \($0.bytes)B" }
        lines.append("--- 확장 오류")
        lines += s.errors
        lines.append("--- 확장 로그")
        lines += s.log
        lines.append("--- Cast 기록")
        lines += cast.events
        lines.append("--- Cast SDK 로그 (최근 80줄)")
        lines += cast.sdkLog.suffix(80)
        return lines.joined(separator: "\n")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func time(_ date: Date) -> String { formatter.string(from: date) }
}
