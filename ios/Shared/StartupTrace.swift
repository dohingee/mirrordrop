import CoreMedia
import Foundation

/// Monotonic host clock (mach time) shared by the app and the extension, so the app's load request
/// can be placed on the extension's timeline (both processes read the same clock).
enum HostClock {
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// "시작 기록": the first 30 s of a broadcast as the extension saw it, counted from the first
/// ReplayKit video frame. Fixed-size (every list is capped) so it stays tiny in memory and in the
/// App Group status. Holds no paths or tokens: requests are kept only as a kind and a number.
struct StartupTrace: Codable, Equatable {
    static let window: Double = 30
    static let maxSegments = 64
    static let maxRequests = 200

    /// Video frames in one second of the window.
    struct Second: Codable, Equatable {
        /// Frames delivered by ReplayKit.
        var input = 0
        /// Frames handed to the encoder (repeated ones included).
        var encoded = 0
        /// Of `encoded`: the last frame repeated because ReplayKit sent nothing (static screen).
        var repeated = 0
        /// Frames the scaler or the encoder could not take.
        var dropped = 0

        enum CodingKeys: String, CodingKey { case input = "i", encoded = "e", repeated = "r", dropped = "d" }
    }

    struct Segment: Codable, Equatable {
        var sequence: Int
        /// Seconds since the first frame when the server could hand it out.
        var at: Double
        var duration: Double
        var bytes: Int

        enum CodingKeys: String, CodingKey { case sequence = "s", at = "t", duration = "d", bytes = "b" }
    }

    enum RequestKind: String, Codable {
        case master, media, initSegment = "init", segment, other
    }

    struct Request: Codable, Equatable {
        var at: Double
        var kind: RequestKind
        /// Nil for GET.
        var method: String?
        /// Segment sequence, or init segment version.
        var sequence: Int?
        var status: Int
        /// Segments: seconds between becoming available and being requested (nil if unknown).
        var waited: Double?
        /// Media playlist: newest segment listed in the response.
        var newestListed: Int?

        enum CodingKeys: String, CodingKey {
            case at = "t", kind = "k", method = "m", sequence = "n", status = "c", waited = "w", newestListed = "l"
        }
    }

    enum FrameEvent {
        case input
        case encoded(repeated: Bool)
        case dropped
    }

    /// HostClock seconds of the first video frame; nil before it.
    var origin: Double?
    /// Seconds since `origin` of the latest event seen, at most `window`.
    var elapsed: Double = 0
    var seconds: [Second] = []
    var segments: [Segment] = []
    var requests: [Request] = []
    /// Requests inside the window that did not fit in `requests`.
    var requestsLeftOut = 0

    mutating func recordFrame(_ event: FrameEvent, now: Double) {
        if case .input = event, origin == nil { origin = now }
        guard let t = time(now) else { return }
        let index = min(Int(t), Int(Self.window) - 1)
        while seconds.count <= index { seconds.append(Second()) }
        switch event {
        case .input: seconds[index].input += 1
        case .encoded(let repeated):
            seconds[index].encoded += 1
            if repeated { seconds[index].repeated += 1 }
        case .dropped: seconds[index].dropped += 1
        }
    }

    /// `now` should be taken before the segment is put in the store, so no request can come earlier.
    mutating func recordSegment(sequence: Int, duration: Double, bytes: Int, now: Double) {
        guard let t = time(now), segments.count < Self.maxSegments else { return }
        segments.append(Segment(sequence: sequence, at: Self.ms(t), duration: Self.ms(duration), bytes: bytes))
    }

    /// `path` is only classified here, never stored (it holds the stream token).
    mutating func recordRequest(method: String, path: String, status: Int, body: Data, now: Double) {
        guard let t = time(now) else { return }
        guard requests.count < Self.maxRequests else {
            requestsLeftOut += 1
            return
        }
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        var entry = Request(at: Self.ms(t), kind: .other, method: method == "GET" ? nil : String(method.prefix(8)),
                            sequence: nil, status: status)
        if name == HLSPlaylist.masterName {
            entry.kind = .master
        } else if name == HLSPlaylist.mediaName {
            entry.kind = .media
            if status == 200 { entry.newestListed = Self.newestListedSequence(inPlaylist: body) }
        } else if let version = HLSPlaylist.initVersion(fromName: name) {
            entry.kind = .initSegment
            entry.sequence = version
        } else if let sequence = HLSPlaylist.sequence(fromSegmentName: name) {
            entry.kind = .segment
            entry.sequence = sequence
            if let segment = segments.first(where: { $0.sequence == sequence }) {
                entry.waited = Self.ms(t - segment.at)
            }
        }
        requests.append(entry)
    }

    /// Newest segment the server had made by `t` (seconds since the first frame).
    func newestSegment(at t: Double) -> Int? {
        segments.last(where: { $0.at <= t })?.sequence
    }

    /// Whole seconds of the window that are over, missing ones counted as zero.
    var completeSeconds: [Second] {
        let count = min(Int(elapsed), Int(Self.window))
        return (0..<count).map { $0 < seconds.count ? seconds[$0] : Second() }
    }

    static func newestListedSequence(inPlaylist body: Data) -> Int? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if let sequence = HLSPlaylist.sequence(fromSegmentName: line.trimmingCharacters(in: .whitespaces)) {
                return sequence
            }
        }
        return nil
    }

    /// Seconds since the first frame while inside the window; nil before the first frame and after.
    private mutating func time(_ now: Double) -> Double? {
        guard let origin else { return nil }
        let t = now - origin
        guard t >= 0 else { return nil }
        elapsed = max(elapsed, min(t, Self.window))
        return t < Self.window ? t : nil
    }

    static func ms(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// The TV side of "시작 기록", kept by the app: from the mirror load request, for 30 s, every
/// receiver player state change and the receiver's live lag once a second.
struct PlaybackTrace: Equatable {
    static let window: Double = 30
    static let maxChanges = 60
    static let maxLags = 40

    enum Phase: String {
        case idle = "IDLE", loading = "LOADING", buffering = "BUFFERING", playing = "PLAYING",
             paused = "PAUSED", unknown = "UNKNOWN"
    }

    struct Change: Equatable {
        /// Seconds since the load request.
        var at: Double
        var phase: Phase
        /// Only for IDLE, e.g. "ERROR".
        var idleReason: String?
        /// Receiver media session; a new load gets a new one.
        var session: Int
    }

    struct LagSample: Equatable {
        var at: Double
        /// Live seekable range end minus position; nil while not playing or unknown.
        var lag: Double?
    }

    /// HostClock seconds when the load request was sent.
    let origin: Double
    var elapsed: Double = 0
    var changes: [Change] = []
    var lags: [LagSample] = []

    init(origin: Double) {
        self.origin = origin
    }

    func isRecording(at now: Double) -> Bool {
        let t = now - origin
        return t >= 0 && t < Self.window
    }

    mutating func recordState(_ phase: Phase, idleReason: String?, session: Int, now: Double) {
        guard let t = time(now) else { return }
        if let last = changes.last, last.phase == phase, last.idleReason == idleReason, last.session == session { return }
        guard changes.count < Self.maxChanges else { return }
        changes.append(Change(at: StartupTrace.ms(t), phase: phase, idleReason: idleReason, session: session))
    }

    mutating func recordLag(_ lag: Double?, now: Double) {
        guard let t = time(now), lags.count < Self.maxLags else { return }
        lags.append(LagSample(at: StartupTrace.ms(t), lag: lag.map(StartupTrace.ms)))
    }

    /// State changes of this load. Right after a new load the receiver can still report the
    /// previous media as playing; such leading PLAYING/PAUSED entries of an earlier session are left out.
    var relevantChanges: [Change] {
        guard let latest = changes.last?.session else { return [] }
        var result = changes
        while let first = result.first, first.session != latest, first.phase == .playing || first.phase == .paused {
            result.removeFirst()
        }
        return result
    }

    private mutating func time(_ now: Double) -> Double? {
        let t = now - origin
        guard t >= 0 else { return nil }
        elapsed = max(elapsed, min(t, Self.window))
        return t < Self.window ? t : nil
    }
}

/// Turns the two traces into the Korean text of the "시작 기록 (처음 30초)" diagnostics section and
/// the shared problem report (one source for both).
enum StartupReport {
    static func summary(trace: StartupTrace, playback: PlaybackTrace?) -> [String] {
        var lines: [String] = []
        if trace.origin == nil {
            lines.append("확장 기록 없음 (방송을 시작하면 첫 화면부터 30초를 기록합니다)")
        } else {
            lines += extensionSummary(trace)
        }
        if let playback, let origin = trace.origin {
            let loadAt = playback.origin - origin
            if loadAt >= 0, loadAt < 3600 {
                let ready = trace.segments.filter { $0.at <= loadAt }.count
                let count = loadAt < StartupTrace.window ? "\(ready)개" : "기록 밖"
                lines.append("TV에 재생 요청: 첫 화면 뒤 \(f1(loadAt))초 (그때 조각 \(count))")
            }
        }
        if let playback {
            lines += playbackSummary(playback)
        } else {
            lines.append("TV 재생 기록 없음 (앱이 TV에 화면 재생을 요청하면 그때부터 30초를 기록합니다)")
        }
        return lines
    }

    private static func extensionSummary(_ trace: StartupTrace) -> [String] {
        var lines: [String] = []
        let full = trace.completeSeconds
        let early = Array(full.prefix(5))
        let later = Array(full.dropFirst(5))
        func perSecond(_ values: (StartupTrace.Second) -> Int) -> String {
            var text = "초당 " + range(early.map(values)) + " (첫 5초)"
            if !later.isEmpty { text += ", 그 뒤 " + range(later.map(values)) }
            return text
        }
        lines.append("화면 그림(ReplayKit): " + perSecond { $0.input })
        lines.append("인코딩: " + perSecond { $0.encoded }
                     + "; 첫 5초 반복 \(early.reduce(0) { $0 + $1.repeated }), 버림 \(early.reduce(0) { $0 + $1.dropped })")

        let segments = trace.segments
        if let first = segments.first {
            var gaps: [(at: Double, gap: Double)] = []
            for index in segments.indices.dropFirst() {
                gaps.append((segments[index].at, segments[index].at - segments[index - 1].at))
            }
            let earlyGaps = gaps.filter { $0.at < 5 }.map(\.gap)
            let laterGaps = gaps.filter { $0.at >= 5 }.map(\.gap)
            lines.append("첫 조각 \(f1(first.at))초. 조각 간격: " + secondsRange(earlyGaps) + " (첫 5초), 그 뒤 "
                         + secondsRange(laterGaps))
            lines.append("조각 길이: " + secondsRange(segments.map(\.duration)) + ", 크기 "
                         + range(segments.map { $0.bytes / 1024 }, unit: "KB"))
        } else {
            lines.append("조각 아직 없음")
        }

        let requests = trace.requests
        let segmentRequests = requests.filter { $0.kind == .segment }
        if let firstRequest = requests.first {
            var text = "TV 첫 요청 \(f1(firstRequest.at))초"
            if let firstSegment = segmentRequests.first, let sequence = firstSegment.sequence {
                text += ", 처음 가져간 조각 seg\(sequence)"
                if let newest = trace.newestSegment(at: firstSegment.at) { text += " (그때 최신 seg\(newest))" }
            }
            lines.append(text)
        } else {
            lines.append("TV 요청 아직 없음")
        }
        let waits = segmentRequests.filter { $0.status == 200 }.compactMap(\.waited)
        if let low = waits.min(), let high = waits.max() {
            lines.append("TV가 조각을 요청한 시점: 만들어진 뒤 평균 \(f1(average(waits)))초 (최소 \(f1(low)) / 최대 \(f1(high)))")
        }
        let playlists = requests.filter { $0.kind == .media }
        if !playlists.isEmpty {
            var text = "재생목록 요청 \(playlists.count)번"
            let gaps = zip(playlists.dropFirst(), playlists).map { $0.at - $1.at }
            if let high = gaps.max() { text += ", 간격 평균 \(f1(average(gaps)))초 (최대 \(f1(high))초)" }
            lines.append(text)
        }
        let missing = segmentRequests.filter { $0.status == 404 }
        let notYet = missing.filter { request in
            guard let sequence = request.sequence else { return false }
            return sequence > (trace.newestSegment(at: request.at) ?? -1)
        }.count
        var text = "없는 조각 요청(404) \(missing.count)번"
        if !missing.isEmpty { text += " (아직 안 만든 것 \(notYet), 이미 지운 것 \(missing.count - notYet))" }
        let otherFailures = requests.filter { $0.status >= 400 && !($0.kind == .segment && $0.status == 404) }.count
        if otherFailures > 0 { text += ", 그 밖의 실패 응답 \(otherFailures)번" }
        lines.append(text)
        if trace.requestsLeftOut > 0 { lines.append("요청 기록이 가득 차 \(trace.requestsLeftOut)개는 빠짐") }
        return lines
    }

    private static func playbackSummary(_ playback: PlaybackTrace) -> [String] {
        var lines: [String] = []
        let changes = playback.relevantChanges
        if let playIndex = changes.firstIndex(where: { $0.phase == .playing }) {
            lines.append("첫 재생까지 \(f1(changes[playIndex].at))초 (재생 요청부터)")
            var count = 0
            var countFirst10 = 0
            var total = 0.0
            for index in changes.indices where index > playIndex && changes[index].phase == .buffering {
                let start = changes[index].at
                let end = index + 1 < changes.count ? changes[index + 1].at : max(playback.elapsed, start)
                count += 1
                total += end - start
                if start < 10 { countFirst10 += 1 }
            }
            lines.append("첫 재생 뒤 버퍼링 \(count)번, 합계 \(f1(total))초 (처음 10초 안 \(countFirst10)번)")
        } else {
            let now = changes.last.map { $0.phase.rawValue } ?? "상태 받기 전"
            lines.append("아직 재생 안 됨 (지금 \(now))")
        }
        if let failure = changes.first(where: { $0.phase == .idle && $0.idleReason == "ERROR" }) {
            lines.append("TV 재생 실패(IDLE/ERROR) \(f1(failure.at))초")
        }
        let marks: [Double] = [2, 5, 10, 20]
        let values = marks.map { mark -> String in
            let near = playback.lags.filter { abs($0.at - mark) <= 1.0 }
                .min { abs($0.at - mark) < abs($1.at - mark) }
            return "\(Int(mark))초 " + (near?.lag.map(f1) ?? "-")
        }
        lines.append("라이브 끝에서 뒤: " + values.joined(separator: " / "))
        return lines
    }

    /// Row-by-row records under the summary (diagnostics details and the shared report).
    static func details(trace: StartupTrace, playback: PlaybackTrace?) -> [String] {
        var lines: [String] = []
        lines.append("[초별 프레임] 초: 받음 / 인코딩 (반복, 버림)")
        for (index, second) in trace.seconds.enumerated() {
            lines.append("\(index)초: \(second.input) / \(second.encoded) (반복 \(second.repeated), 버림 \(second.dropped))")
        }
        lines.append("[조각] 번호: 나온 때, 길이, 크기 (첫 화면부터)")
        for segment in trace.segments {
            lines.append("seg\(segment.sequence): \(f2(segment.at))초, \(f2(segment.duration))초, \(segment.bytes / 1024)KB")
        }
        lines.append("[TV 요청] 때, 종류 → 상태 (첫 화면부터)")
        for request in trace.requests {
            lines.append("\(f2(request.at))초 \(describe(request))")
        }
        if trace.requestsLeftOut > 0 { lines.append("(가득 차서 \(trace.requestsLeftOut)개 빠짐)") }
        if let playback {
            lines.append("[TV 상태] (재생 요청부터)")
            for change in playback.changes {
                var text = "\(f2(change.at))초 \(change.phase.rawValue)"
                if let reason = change.idleReason { text += "/\(reason)" }
                lines.append(text + " (세션 \(change.session))")
            }
            lines.append("[라이브 끝에서 뒤] (재생 요청부터)")
            var row: [String] = []
            for sample in playback.lags {
                row.append("\(f1(sample.at))초 " + (sample.lag.map(f1) ?? "-"))
                if row.count == 5 {
                    lines.append(row.joined(separator: ", "))
                    row = []
                }
            }
            if !row.isEmpty { lines.append(row.joined(separator: ", ")) }
        }
        return lines
    }

    private static func describe(_ request: StartupTrace.Request) -> String {
        var text: String
        switch request.kind {
        case .master: text = "마스터 목록"
        case .media: text = "재생목록" + (request.newestListed.map { "(최신 seg\($0))" } ?? "")
        case .initSegment: text = "init" + (request.sequence.map { $0 == 0 ? "" : "\($0)" } ?? "")
        case .segment: text = "seg" + (request.sequence.map(String.init) ?? "?")
        case .other: text = "기타"
        }
        if let method = request.method { text = method + " " + text }
        text += " → \(request.status)"
        if let waited = request.waited { text += " (만든 뒤 \(f2(waited))초)" }
        return text
    }

    private static func range(_ values: [Int], unit: String = "") -> String {
        guard let low = values.min(), let high = values.max() else { return "-" }
        return "최소 \(low)\(unit) / 최대 \(high)\(unit)"
    }

    private static func secondsRange(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return "-" }
        return "최소 \(f2(low)) / 최대 \(f2(high))초"
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func f1(_ value: Double) -> String { String(format: "%.1f", value) }
    static func f2(_ value: Double) -> String { String(format: "%.2f", value) }
}
