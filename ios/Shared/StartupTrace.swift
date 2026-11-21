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

/// The TV side of "시작 기록", kept by the app: from a mirror load request, for 30 s, every
/// receiver player state change and the receiver's live lag about once a second. The app keeps two:
/// the FIRST load of a broadcast (the startup record) and the latest re-load ("다시 보내기 기록").
struct PlaybackTrace: Equatable {
    static let window: Double = 30
    static let maxChanges = 60
    static let maxLags = 60
    /// Samples closer together than this are not kept (the timer and status updates both sample).
    static let minLagSpacing: Double = 0.5

    enum Phase: String {
        case idle = "IDLE", loading = "LOADING", buffering = "BUFFERING", playing = "PLAYING",
             paused = "PAUSED", unknown = "UNKNOWN"
    }

    /// Why a live-lag sample has no value. Raw values are short English codes (logs).
    enum LagGap: String, Equatable {
        case notConnected = "not connected"
        case notPlaying = "not playing"
        /// The receiver reported no live seekable range (approximateLiveSeekableRangeEnd invalid or 0).
        case noLiveRange = "no live range"
        case noPosition = "no position"

        var label: String {
            switch self {
            case .notConnected: return String(localized: "TV 연결 안 됨")
            case .notPlaying: return String(localized: "재생 중 아님")
            case .noLiveRange: return String(localized: "TV가 라이브 범위를 안 알려 줌")
            case .noPosition: return String(localized: "재생 위치 모름")
            }
        }
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
        /// Live seekable range end minus position; nil when it could not be measured (see `gap`).
        var lag: Double?
        /// Why `lag` is nil.
        var gap: LagGap?
    }

    /// HostClock seconds when the load request was sent.
    let origin: Double
    /// Why the load was sent (nil in tests that do not care).
    var reason: CastReason?
    var elapsed: Double = 0
    var changes: [Change] = []
    var lags: [LagSample] = []

    init(origin: Double, reason: CastReason? = nil) {
        self.origin = origin
        self.reason = reason
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

    /// `gap` says why `lag` is nil. A sample less than `minLagSpacing` after the previous one is
    /// dropped, unless it has a value and the previous one had none.
    mutating func recordLag(_ lag: Double?, gap: LagGap? = nil, now: Double) {
        guard let t = time(now), lags.count < Self.maxLags else { return }
        if let last = lags.last, t - last.at < Self.minLagSpacing, !(lag != nil && last.lag == nil) { return }
        lags.append(LagSample(at: StartupTrace.ms(t), lag: lag.map(StartupTrace.ms), gap: lag == nil ? gap : nil))
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

    /// The measured lag nearest to `mark` within one second (samples without a value are skipped,
    /// so a value 0.8 s away beats an unmeasured sample 0.1 s away).
    func lag(near mark: Double) -> Double? {
        lags.filter { $0.lag != nil && abs($0.at - mark) <= 1.0 }
            .min { abs($0.at - mark) < abs($1.at - mark) }?.lag
    }

    private mutating func time(_ now: Double) -> Double? {
        let t = now - origin
        guard t >= 0 else { return nil }
        elapsed = max(elapsed, min(t, Self.window))
        return t < Self.window ? t : nil
    }
}

/// The app's two TV-side records: the FIRST mirror load of a broadcast (`startup`, kept until a load
/// of another broadcast) and the latest re-load of the same broadcast (`resend`). Build 16 kept only
/// the last load, so a reload two minutes in replaced the startup record. Broadcasts are told apart
/// by the stream token (a new one per broadcast; a Wi-Fi change keeps it). App side: CastManager.
struct PlaybackRecords: Equatable {
    private(set) var startup: PlaybackTrace?
    private(set) var resend: PlaybackTrace?
    /// Stream token of the broadcast `startup` belongs to.
    private(set) var token: String?

    /// A mirror load request was sent at `origin` (HostClock seconds).
    mutating func loadSent(token: String?, origin: Double, reason: CastReason) {
        if startup == nil || token != self.token {
            startup = PlaybackTrace(origin: origin, reason: reason)
            resend = nil
            self.token = token
        } else {
            resend = PlaybackTrace(origin: origin, reason: reason)
        }
    }

    /// True while either record is inside its 30 s window.
    func isRecording(at now: Double) -> Bool {
        (startup?.isRecording(at: now) ?? false) || (resend?.isRecording(at: now) ?? false)
    }

    mutating func recordState(_ phase: PlaybackTrace.Phase, idleReason: String?, session: Int, now: Double) {
        if startup?.isRecording(at: now) == true {
            startup?.recordState(phase, idleReason: idleReason, session: session, now: now)
        }
        if resend?.isRecording(at: now) == true {
            resend?.recordState(phase, idleReason: idleReason, session: session, now: now)
        }
    }

    mutating func recordLag(_ lag: Double?, gap: PlaybackTrace.LagGap?, now: Double) {
        if startup?.isRecording(at: now) == true { startup?.recordLag(lag, gap: gap, now: now) }
        if resend?.isRecording(at: now) == true { resend?.recordLag(lag, gap: gap, now: now) }
    }
}

/// Turns the traces into the text of the "시작 기록 (처음 30초)" and "다시 보내기 기록" diagnostics
/// sections and the shared problem report (one source for both). Localized with String(localized:):
/// Korean is the key, the app's String Catalog has English. Without a catalog (unit tests: the
/// main bundle is the test runner) the Korean text is used as is.
enum StartupReport {
    static func summary(trace: StartupTrace, playback: PlaybackTrace?) -> [String] {
        var lines: [String] = []
        if trace.origin == nil {
            lines.append(String(localized: "확장 기록 없음 (방송을 시작하면 첫 화면부터 30초를 기록합니다)"))
        } else {
            lines += extensionSummary(trace)
        }
        if let playback {
            if let line = loadLine(trace: trace, playback: playback) { lines.append(line) }
            if let reason = playback.reason { lines.append(String(localized: "보낸 까닭: \(reason.label)")) }
            lines += playbackSummary(playback)
        } else {
            lines.append(String(localized: "TV 재생 기록 없음 (앱이 TV에 화면 재생을 요청하면 그때부터 30초를 기록합니다)"))
        }
        return lines
    }

    /// "다시 보내기 기록": the latest re-load of the same broadcast (any load after the first one).
    static func resendSummary(trace: StartupTrace, playback: PlaybackTrace) -> [String] {
        var lines: [String] = []
        if let origin = trace.origin {
            let at = playback.origin - origin
            if at >= 0, at < 24 * 3600 {
                lines.append(String(localized: "다시 보낸 때: 첫 화면 뒤 \(f1(at))초"))
            }
        }
        lines.append(String(localized: "보낸 까닭: \(playback.reason?.label ?? "-")"))
        lines += playbackSummary(playback)
        return lines
    }

    private static func loadLine(trace: StartupTrace, playback: PlaybackTrace) -> String? {
        guard let origin = trace.origin else { return nil }
        let loadAt = playback.origin - origin
        guard loadAt >= 0, loadAt < 3600 else { return nil }
        let ready = trace.segments.filter { $0.at <= loadAt }.count
        let count = loadAt < StartupTrace.window ? String(localized: "\(ready)개") : String(localized: "기록 밖")
        return String(localized: "TV에 재생 요청: 첫 화면 뒤 \(f1(loadAt))초 (그때 조각 \(count))")
    }

    private static func extensionSummary(_ trace: StartupTrace) -> [String] {
        var lines: [String] = []
        let full = trace.completeSeconds
        let early = Array(full.prefix(5))
        let later = Array(full.dropFirst(5))
        func perSecond(_ values: (StartupTrace.Second) -> Int) -> String {
            let first = range(early.map(values))
            if later.isEmpty { return String(localized: "초당 \(first) (첫 5초)") }
            let rest = range(later.map(values))
            return String(localized: "초당 \(first) (첫 5초), 그 뒤 \(rest)")
        }
        let input = perSecond { $0.input }
        lines.append(String(localized: "화면 그림(ReplayKit): \(input)"))
        let encoded = perSecond { $0.encoded }
        let repeated = early.reduce(0) { $0 + $1.repeated }
        let dropped = early.reduce(0) { $0 + $1.dropped }
        lines.append(String(localized: "인코딩: \(encoded); 첫 5초 반복 \(repeated), 버림 \(dropped)"))

        let segments = trace.segments
        if let first = segments.first {
            var gaps: [(at: Double, gap: Double)] = []
            for index in segments.indices.dropFirst() {
                gaps.append((segments[index].at, segments[index].at - segments[index - 1].at))
            }
            let earlyGaps = secondsRange(gaps.filter { $0.at < 5 }.map(\.gap))
            let laterGaps = secondsRange(gaps.filter { $0.at >= 5 }.map(\.gap))
            lines.append(String(localized: "첫 조각 \(f1(first.at))초. 조각 간격: \(earlyGaps) (첫 5초), 그 뒤 \(laterGaps)"))
            let durations = secondsRange(segments.map(\.duration))
            let sizes = range(segments.map { $0.bytes / 1024 }, unit: "KB")
            lines.append(String(localized: "조각 길이: \(durations), 크기 \(sizes)"))
        } else {
            lines.append(String(localized: "조각 아직 없음"))
        }

        let requests = trace.requests
        let segmentRequests = requests.filter { $0.kind == .segment }
        if let firstRequest = requests.first {
            var text = String(localized: "TV 첫 요청 \(f1(firstRequest.at))초")
            if let firstSegment = segmentRequests.first, let sequence = firstSegment.sequence {
                text += String(localized: ", 처음 가져간 조각 seg\(sequence)")
                if let newest = trace.newestSegment(at: firstSegment.at) {
                    text += String(localized: " (그때 최신 seg\(newest))")
                }
            }
            lines.append(text)
        } else {
            lines.append(String(localized: "TV 요청 아직 없음"))
        }
        let waits = segmentRequests.filter { $0.status == 200 }.compactMap(\.waited)
        if let low = waits.min(), let high = waits.max() {
            let mean = f1(average(waits))
            lines.append(String(localized: "TV가 조각을 요청한 시점: 만들어진 뒤 평균 \(mean)초 (최소 \(f1(low)) / 최대 \(f1(high)))"))
        }
        let playlists = requests.filter { $0.kind == .media }
        if !playlists.isEmpty {
            var text = String(localized: "재생목록 요청 \(playlists.count)번")
            let gaps = zip(playlists.dropFirst(), playlists).map { $0.at - $1.at }
            if let high = gaps.max() {
                let mean = f1(average(gaps))
                text += String(localized: ", 간격 평균 \(mean)초 (최대 \(f1(high))초)")
            }
            lines.append(text)
        }
        let missing = segmentRequests.filter { $0.status == 404 }
        let notYet = missing.filter { request in
            guard let sequence = request.sequence else { return false }
            return sequence > (trace.newestSegment(at: request.at) ?? -1)
        }.count
        var text = String(localized: "없는 조각 요청(404) \(missing.count)번")
        if !missing.isEmpty {
            let gone = missing.count - notYet
            text += String(localized: " (아직 안 만든 것 \(notYet), 이미 지운 것 \(gone))")
        }
        let otherFailures = requests.filter { $0.status >= 400 && !($0.kind == .segment && $0.status == 404) }.count
        if otherFailures > 0 { text += String(localized: ", 그 밖의 실패 응답 \(otherFailures)번") }
        lines.append(text)
        if trace.requestsLeftOut > 0 {
            lines.append(String(localized: "요청 기록이 가득 차 \(trace.requestsLeftOut)개는 빠짐"))
        }
        return lines
    }

    private static func playbackSummary(_ playback: PlaybackTrace) -> [String] {
        var lines: [String] = []
        let changes = playback.relevantChanges
        if let playIndex = changes.firstIndex(where: { $0.phase == .playing }) {
            lines.append(String(localized: "첫 재생까지 \(f1(changes[playIndex].at))초 (재생 요청부터)"))
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
            lines.append(String(localized: "첫 재생 뒤 버퍼링 \(count)번, 합계 \(f1(total))초 (처음 10초 안 \(countFirst10)번)"))
        } else {
            let now = changes.last.map { $0.phase.rawValue } ?? String(localized: "상태 받기 전")
            lines.append(String(localized: "아직 재생 안 됨 (지금 \(now))"))
        }
        if let failure = changes.first(where: { $0.phase == .idle && $0.idleReason == "ERROR" }) {
            lines.append(String(localized: "TV 재생 실패(IDLE/ERROR) \(f1(failure.at))초"))
        }
        let marks = [2, 5, 10, 20]
        let values = marks.map { mark -> String in
            let value = playback.lag(near: Double(mark)).map(f1) ?? "-"
            return String(localized: "\(mark)초 \(value)")
        }
        let joined = values.joined(separator: " / ")
        lines.append(String(localized: "라이브 끝에서 뒤: \(joined)"))
        if let line = lagCoverage(playback) { lines.append(line) }
        return lines
    }

    /// Why "라이브 끝에서 뒤" has holes: how many samples had no value and why, and the longest
    /// stretch without any sample (the app was suspended in the background: no code runs, nothing is
    /// measured). Nil when every sample had a value and there is no such stretch.
    static func lagCoverage(_ playback: PlaybackTrace) -> String? {
        let samples = playback.lags
        guard let firstSample = samples.first else {
            return String(localized: "재생 위치 기록 없음 (그동안 앱이 멈춰 있었을 수 있어요)")
        }
        let measured = samples.filter { $0.lag != nil }.count
        var longest = (start: 0.0, length: firstSample.at)
        for (previous, next) in zip(samples, samples.dropFirst()) where next.at - previous.at > longest.length {
            longest = (previous.at, next.at - previous.at)
        }
        let hasHole = longest.length > 2
        guard measured < samples.count || hasHole else { return nil }
        let unmeasured = samples.count - measured
        var text = String(localized: "재생 위치: 잰 것 \(measured)번, 못 잰 것 \(unmeasured)번")
        var reasons: [(gap: PlaybackTrace.LagGap, count: Int)] = []
        for sample in samples {
            guard sample.lag == nil, let gap = sample.gap else { continue }
            if let index = reasons.firstIndex(where: { $0.gap == gap }) {
                reasons[index].count += 1
            } else {
                reasons.append((gap, 1))
            }
        }
        if !reasons.isEmpty {
            text += " (" + reasons.map { "\($0.gap.label) \($0.count)" }.joined(separator: ", ") + ")"
        }
        if hasHole {
            let length = f1(longest.length)
            let start = f1(longest.start)
            text += String(localized: "; 기록 빈 구간 최대 \(length)초 (\(start)초부터, 앱이 멈춰 있었을 수 있어요)")
        }
        return text
    }

    /// Row-by-row records under the summary (diagnostics details and the shared report).
    static func details(trace: StartupTrace, playback: PlaybackTrace?) -> [String] {
        var lines: [String] = []
        lines.append(String(localized: "[초별 프레임] 초: 받음 / 인코딩 (반복, 버림)"))
        for (index, second) in trace.seconds.enumerated() {
            lines.append(String(localized: "\(index)초: \(second.input) / \(second.encoded) (반복 \(second.repeated), 버림 \(second.dropped))"))
        }
        lines.append(String(localized: "[조각] 번호: 나온 때, 길이, 크기 (첫 화면부터)"))
        for segment in trace.segments {
            let kb = segment.bytes / 1024
            lines.append(String(localized: "seg\(segment.sequence): \(f2(segment.at))초, \(f2(segment.duration))초, \(kb)KB"))
        }
        lines.append(String(localized: "[TV 요청] 때, 종류 → 상태 (첫 화면부터)"))
        for request in trace.requests {
            lines.append(String(localized: "\(f2(request.at))초 \(describe(request))"))
        }
        if trace.requestsLeftOut > 0 { lines.append(String(localized: "(가득 차서 \(trace.requestsLeftOut)개 빠짐)")) }
        if let playback { lines += playbackDetails(playback) }
        return lines
    }

    /// TV states and live-lag samples of one load (the startup or the resend record).
    static func playbackDetails(_ playback: PlaybackTrace) -> [String] {
        var lines: [String] = []
        lines.append(String(localized: "[TV 상태] (재생 요청부터)"))
        for change in playback.changes {
            var state = change.phase.rawValue
            if let reason = change.idleReason { state += "/\(reason)" }
            lines.append(String(localized: "\(f2(change.at))초 \(state) (세션 \(change.session))"))
        }
        lines.append(String(localized: "[라이브 끝에서 뒤] (재생 요청부터)"))
        var row: [String] = []
        for sample in playback.lags {
            var value = sample.lag.map(f1) ?? "-"
            if sample.lag == nil, let gap = sample.gap { value += " (\(gap.label))" }
            row.append(String(localized: "\(f1(sample.at))초 \(value)"))
            if row.count == 5 {
                lines.append(row.joined(separator: ", "))
                row = []
            }
        }
        if !row.isEmpty { lines.append(row.joined(separator: ", ")) }
        return lines
    }

    private static func describe(_ request: StartupTrace.Request) -> String {
        var text: String
        switch request.kind {
        case .master: text = String(localized: "마스터 목록")
        case .media:
            if let newest = request.newestListed {
                text = String(localized: "재생목록(최신 seg\(newest))")
            } else {
                text = String(localized: "재생목록")
            }
        case .initSegment: text = "init" + (request.sequence.map { $0 == 0 ? "" : "\($0)" } ?? "")
        case .segment: text = "seg" + (request.sequence.map(String.init) ?? "?")
        case .other: text = String(localized: "기타")
        }
        if let method = request.method { text = method + " " + text }
        text += " → \(request.status)"
        if let waited = request.waited { text += String(localized: " (만든 뒤 \(f2(waited))초)") }
        return text
    }

    private static func range(_ values: [Int], unit: String = "") -> String {
        guard let low = values.min(), let high = values.max() else { return "-" }
        return String(localized: "최소 \(low)\(unit) / 최대 \(high)\(unit)")
    }

    private static func secondsRange(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return "-" }
        return String(localized: "최소 \(f2(low)) / 최대 \(f2(high))초")
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func f1(_ value: Double) -> String { String(format: "%.1f", value) }
    static func f2(_ value: Double) -> String { String(format: "%.2f", value) }
}
