import XCTest

final class LatencyPresetTests: XCTestCase {
    private func segments(count: Int, duration: Double) -> [MediaSegment] {
        (0..<count).map { MediaSegment(sequence: $0, duration: duration, data: Data()) }
    }

    /// RFC 8216 6.2.2: a live playlist must cover at least three target durations.
    /// Checked with nominal durations and with keyframe-stretched ones (1.033 s, 0.533 s).
    func testWindowCoversThreeTargetDurations() {
        for preset in LatencyPreset.allCases {
            let stretched = preset.segmentSeconds == 1.0 ? 1.033 : 0.533
            for duration in [preset.segmentSeconds, stretched] {
                let window = segments(count: preset.playlistWindow, duration: duration)
                let target = HLSPlaylist.targetDuration(window)
                XCTAssertEqual(target, 1, "\(preset.code) at \(duration) s")
                let total = window.reduce(0) { $0 + $1.duration }
                XCTAssertGreaterThanOrEqual(total, 3 * Double(target), "\(preset.code) at \(duration) s")
            }
        }
    }

    func testStoredSegmentsAndMemory() {
        for preset in LatencyPreset.allCases {
            XCTAssertGreaterThanOrEqual(preset.storedSegments, preset.playlistWindow, preset.code)
            // Keep stored video at about today's 7 s or less (about 0.31 MB per second at 2.5 Mbps).
            XCTAssertLessThanOrEqual(Double(preset.storedSegments) * preset.segmentSeconds, 7.0, preset.code)
            // The first playlist the TV sees must already cover 3 s.
            XCTAssertGreaterThanOrEqual(Double(preset.segmentsBeforeReady) * preset.segmentSeconds, 3.0, preset.code)
            XCTAssertLessThanOrEqual(preset.segmentsBeforeReady, preset.playlistWindow, preset.code)
        }
    }

    func testDefaultIsL1() {
        let preset = LatencyPreset.default
        XCTAssertEqual(preset, .l1)
        XCTAssertEqual(preset.segmentSeconds, 1.0)
        XCTAssertEqual(preset.playlistWindow, 3)
        XCTAssertEqual(preset.storedSegments, 6)
        XCTAssertNil(preset.startOffset)
        XCTAssertEqual(preset.segmentsBeforeReady, 3)
    }

    func testStoredValueRoundTrip() {
        for preset in LatencyPreset.allCases {
            XCTAssertEqual(LatencyPreset(storedValue: preset.rawValue), preset)
            XCTAssertEqual(preset.code, preset.rawValue)
        }
        XCTAssertEqual(LatencyPreset.allCases.map(\.code), ["L0", "L1", "L2", "L3"])
    }

    func testUnknownStoredValueFallsBackToDefault() {
        XCTAssertEqual(LatencyPreset(storedValue: nil), .l1)
        XCTAssertEqual(LatencyPreset(storedValue: "L9"), .l1)
        XCTAssertEqual(LatencyPreset(storedValue: ""), .l1)
        XCTAssertEqual(LatencyPreset(storedValue: "l3"), .l1)
    }

    func testSaveAndLoadThroughUserDefaults() throws {
        let suite = "LatencyPresetTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LatencyPreset.load(from: defaults), .l1)
        LatencyPreset.l3.save(to: defaults)
        XCTAssertEqual(LatencyPreset.load(from: defaults), .l3)
        defaults.set("bogus", forKey: AppGroup.latencyPresetKey)
        XCTAssertEqual(LatencyPreset.load(from: defaults), .l1)
    }
}

final class PlaylistStartTests: XCTestCase {
    private let segments = [MediaSegment(sequence: 3, duration: 1.0, data: Data())]

    func testMediaPlaylistWithoutStartIsUnchanged() {
        XCTAssertEqual(HLSPlaylist.media(segments, startOffset: nil), HLSPlaylist.media(segments))
        XCTAssertEqual(HLSPlaylist.media(segments), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:3
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.000,
        seg3.m4s

        """)
    }

    func testMediaPlaylistWithStart() {
        XCTAssertEqual(HLSPlaylist.media(segments, startOffset: LatencyPreset.l2.startOffset), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-START:TIME-OFFSET=-2.0,PRECISE=NO
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:3
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.000,
        seg3.m4s

        """)
    }

    func testRouterPassesStartOffset() {
        let snapshot = StreamSnapshot(initSegment: nil, playlistSegments: segments, storedSegments: segments,
                                      codecs: nil, bandwidth: 1, width: 2, height: 3, frameRate: 30,
                                      startOffset: -2.0)
        let response = StreamRouter(token: "tok").respond(
            to: HTTPRequest(method: "GET", target: "/tok/media.m3u8", path: "/tok/media.m3u8",
                            version: "HTTP/1.1", headers: [:]),
            snapshot: snapshot)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self)
            .contains("#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=NO\n"))
    }

    func testStoreUsesPresetWindow() {
        let preset = LatencyPreset.l3
        let store = StreamStore(format: .init(width: 1280, height: 720, frameRate: 30, bandwidth: 100),
                                playlistWindow: preset.playlistWindow, storedSegments: preset.storedSegments,
                                startOffset: preset.startOffset)
        for _ in 0..<12 { store.addSegment(duration: 0.5, data: Data()) }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.playlistSegments.map(\.sequence), Array(6..<12))
        XCTAssertEqual(snapshot.storedSegments.count, 10)
        XCTAssertNil(snapshot.startOffset)
    }
}
