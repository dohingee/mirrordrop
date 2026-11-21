import XCTest

final class StartupTraceTests: XCTestCase {
    private let origin = 1000.0

    func testFramesBucketedPerSecondFromFirstFrame() {
        var trace = StartupTrace()
        trace.recordFrame(.encoded(repeated: false), now: origin - 1)   // before the first frame: ignored
        XCTAssertNil(trace.origin)
        trace.recordFrame(.input, now: origin)
        trace.recordFrame(.input, now: origin + 0.5)
        trace.recordFrame(.encoded(repeated: false), now: origin + 0.6)
        trace.recordFrame(.encoded(repeated: true), now: origin + 2.1)
        trace.recordFrame(.dropped, now: origin + 2.2)
        trace.recordFrame(.input, now: origin + 30.5)                   // after the window: ignored
        XCTAssertEqual(trace.origin, origin)
        XCTAssertEqual(trace.seconds.count, 3)
        XCTAssertEqual(trace.seconds[0], StartupTrace.Second(input: 2, encoded: 1, repeated: 0, dropped: 0))
        XCTAssertEqual(trace.seconds[1], StartupTrace.Second())
        XCTAssertEqual(trace.seconds[2], StartupTrace.Second(input: 0, encoded: 1, repeated: 1, dropped: 1))
        XCTAssertEqual(trace.elapsed, 30)
        XCTAssertEqual(trace.completeSeconds.count, 30)
    }

    func testListsAreCapped() {
        var trace = StartupTrace()
        trace.recordFrame(.input, now: origin)
        for index in 0..<100 {
            let now = origin + Double(index) * 0.1
            trace.recordSegment(sequence: index, duration: 0.5, bytes: 1000, now: now)
            for _ in 0..<3 {
                trace.recordRequest(method: "GET", path: "/tok/seg\(index).m4s", status: 200, body: Data(), now: now)
            }
        }
        XCTAssertEqual(trace.segments.count, StartupTrace.maxSegments)
        XCTAssertEqual(trace.requests.count, StartupTrace.maxRequests)
        XCTAssertEqual(trace.requestsLeftOut, 300 - StartupTrace.maxRequests)
    }

    func testRequestsClassifiedWithoutToken() throws {
        let token = "0123456789abcdef"
        var trace = StartupTrace()
        trace.recordFrame(.input, now: origin)
        trace.recordSegment(sequence: 0, duration: 0.5, bytes: 50_000, now: origin + 0.6)
        trace.recordSegment(sequence: 1, duration: 0.5, bytes: 50_000, now: origin + 1.1)
        let segments = [MediaSegment(sequence: 0, duration: 0.5, data: Data()),
                         MediaSegment(sequence: 1, duration: 0.5, data: Data())]
        let playlist = Data(HLSPlaylist.media(segments, targetDuration: 1).utf8)
        trace.recordRequest(method: "GET", path: "/\(token)/live.m3u8", status: 200, body: Data(), now: origin + 3)
        trace.recordRequest(method: "GET", path: "/\(token)/media.m3u8", status: 200, body: playlist, now: origin + 3.1)
        trace.recordRequest(method: "GET", path: "/\(token)/init.mp4", status: 200, body: Data(), now: origin + 3.2)
        trace.recordRequest(method: "GET", path: "/\(token)/seg0.m4s", status: 200, body: Data(), now: origin + 3.3)
        trace.recordRequest(method: "GET", path: "/\(token)/seg9.m4s", status: 404, body: Data(), now: origin + 3.4)
        trace.recordRequest(method: "HEAD", path: "/\(token)/", status: 404, body: Data(), now: origin + 3.5)

        XCTAssertEqual(trace.requests.map(\.kind), [.master, .media, .initSegment, .segment, .segment, .other])
        XCTAssertEqual(trace.requests[1].newestListed, 1)
        XCTAssertEqual(trace.requests[2].sequence, 0)
        XCTAssertEqual(trace.requests[3].sequence, 0)
        XCTAssertEqual(try XCTUnwrap(trace.requests[3].waited), 2.7, accuracy: 0.001)
        XCTAssertNil(trace.requests[4].waited)
        XCTAssertEqual(trace.requests[5].method, "HEAD")
        XCTAssertNil(trace.requests[5].sequence)

        let json = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        XCTAssertFalse(json.contains(token))
    }

    func testNewestListedSequence() {
        XCTAssertNil(StartupTrace.newestListedSequence(inPlaylist: Data("#EXTM3U\n".utf8)))
        let segments = (3...8).map { MediaSegment(sequence: $0, duration: 0.5, data: Data()) }
        XCTAssertEqual(StartupTrace.newestListedSequence(inPlaylist: Data(HLSPlaylist.media(segments).utf8)), 8)
    }

    func testStatusWithoutStartupKeyDecodes() throws {
        var status = BroadcastStatus()
        status.framesIn = 7
        status.startup.recordFrame(.input, now: origin)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(BroadcastStatus.self, from: data), status)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["startup"] = nil
        let old = try JSONDecoder().decode(BroadcastStatus.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.framesIn, 7)
        XCTAssertEqual(old.startup, StartupTrace())
    }

    func testPlaybackTraceDropsRepeatsAndStopsAfterWindow() {
        var playback = PlaybackTrace(origin: origin)
        playback.recordState(.loading, idleReason: nil, session: 1, now: origin + 0.2)
        playback.recordState(.loading, idleReason: nil, session: 1, now: origin + 0.3)
        playback.recordState(.playing, idleReason: nil, session: 1, now: origin + 31)
        XCTAssertEqual(playback.changes.count, 1)
        XCTAssertTrue(playback.isRecording(at: origin + 29.9))
        XCTAssertFalse(playback.isRecording(at: origin + 30))
        for second in 0..<60 { playback.recordLag(1, now: origin + Double(second)) }
        XCTAssertEqual(playback.lags.count, 30)
    }

    /// The old media can still be reported as playing right after a new load.
    func testRelevantChangesSkipEarlierSessionPlaying() {
        var playback = PlaybackTrace(origin: origin)
        playback.recordState(.playing, idleReason: nil, session: 4, now: origin + 0.1)
        playback.recordState(.loading, idleReason: nil, session: 5, now: origin + 0.4)
        playback.recordState(.playing, idleReason: nil, session: 5, now: origin + 2.0)
        XCTAssertEqual(playback.relevantChanges.map(\.phase), [.loading, .playing])
    }

    func testSummary() {
        var trace = StartupTrace()
        // 30 s of frames: 10 per second in the first 5 s, 30 per second after.
        for second in 0..<31 {
            let perSecond = second < 5 ? 10 : 30
            for frame in 0..<perSecond {
                let now = origin + Double(second) + Double(frame) / Double(perSecond)
                trace.recordFrame(.input, now: now)
                trace.recordFrame(.encoded(repeated: false), now: now)
            }
        }
        // Segments every 0.5 s from 1.0 s, except one 1.5 s gap at 2.5 -> 4.0.
        let times = [1.0, 1.5, 2.0, 2.5, 4.0, 4.5, 5.0, 5.5, 6.0]
        for (index, time) in times.enumerated() {
            trace.recordSegment(sequence: index, duration: 0.5, bytes: 60 * 1024, now: origin + time)
        }
        trace.recordRequest(method: "GET", path: "/t/live.m3u8", status: 200, body: Data(), now: origin + 3.0)
        trace.recordRequest(method: "GET", path: "/t/media.m3u8", status: 200, body: Data(), now: origin + 3.1)
        trace.recordRequest(method: "GET", path: "/t/seg1.m4s", status: 200, body: Data(), now: origin + 3.5)
        trace.recordRequest(method: "GET", path: "/t/media.m3u8", status: 200, body: Data(), now: origin + 4.1)
        trace.recordRequest(method: "GET", path: "/t/seg2.m4s", status: 200, body: Data(), now: origin + 3.6)
        trace.recordRequest(method: "GET", path: "/t/seg5.m4s", status: 404, body: Data(), now: origin + 4.2)
        trace.recordRequest(method: "GET", path: "/t/seg0.m4s", status: 404, body: Data(), now: origin + 6.2)

        var playback = PlaybackTrace(origin: origin + 2.6)
        playback.recordState(.loading, idleReason: nil, session: 2, now: playback.origin + 0.1)
        playback.recordState(.buffering, idleReason: nil, session: 2, now: playback.origin + 0.5)
        playback.recordState(.playing, idleReason: nil, session: 2, now: playback.origin + 1.5)
        playback.recordState(.buffering, idleReason: nil, session: 2, now: playback.origin + 3.0)
        playback.recordState(.playing, idleReason: nil, session: 2, now: playback.origin + 3.5)
        playback.recordState(.buffering, idleReason: nil, session: 2, now: playback.origin + 12.0)
        playback.recordState(.playing, idleReason: nil, session: 2, now: playback.origin + 13.0)
        for second in 1...30 {
            playback.recordLag(second < 2 ? nil : 2.0 + Double(second) / 50, now: playback.origin + Double(second))
        }

        let lines = StartupReport.summary(trace: trace, playback: playback)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("화면 그림(ReplayKit): 초당 최소 10 / 최대 10 (첫 5초), 그 뒤 최소 30 / 최대 30"), text)
        XCTAssertTrue(lines.contains("첫 조각 1.0초. 조각 간격: 최소 0.50 / 최대 1.50초 (첫 5초), 그 뒤 최소 0.50 / 최대 0.50초"), text)
        XCTAssertTrue(lines.contains("TV에 재생 요청: 첫 화면 뒤 2.6초 (그때 조각 4개)"), text)
        XCTAssertTrue(lines.contains("TV 첫 요청 3.0초, 처음 가져간 조각 seg1 (그때 최신 seg3)"), text)
        XCTAssertTrue(lines.contains("TV가 조각을 요청한 시점: 만들어진 뒤 평균 1.8초 (최소 1.6 / 최대 2.0)"), text)
        XCTAssertTrue(lines.contains("재생목록 요청 2번, 간격 평균 1.0초 (최대 1.0초)"), text)
        XCTAssertTrue(lines.contains("없는 조각 요청(404) 2번 (아직 안 만든 것 1, 이미 지운 것 1)"), text)
        XCTAssertTrue(lines.contains("첫 재생까지 1.5초 (재생 요청부터)"), text)
        XCTAssertTrue(lines.contains("첫 재생 뒤 버퍼링 2번, 합계 1.5초 (처음 10초 안 1번)"), text)
        XCTAssertTrue(lines.contains("라이브 끝에서 뒤: 2초 2.0 / 5초 2.1 / 10초 2.2 / 20초 2.4"), text)

        let details = StartupReport.details(trace: trace, playback: playback)
        XCTAssertTrue(details.contains("seg4: 4.00초, 0.50초, 60KB"), details.joined(separator: "\n"))
        XCTAssertTrue(details.contains("3.50초 seg1 → 200 (만든 뒤 2.00초)"), details.joined(separator: "\n"))
        XCTAssertTrue(details.contains("1.50초 PLAYING (세션 2)"), details.joined(separator: "\n"))
    }

    func testSummaryWithoutData() {
        let lines = StartupReport.summary(trace: StartupTrace(), playback: nil)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("확장 기록 없음"))
        XCTAssertTrue(lines[1].hasPrefix("TV 재생 기록 없음"))
    }
}
