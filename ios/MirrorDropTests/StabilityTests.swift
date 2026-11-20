import XCTest

final class TargetDurationTests: XCTestCase {
    func testStartsFromConfiguredSegmentLength() {
        XCTAssertEqual(TargetDuration(segmentSeconds: 0.5).value, 1)
        XCTAssertEqual(TargetDuration(segmentSeconds: 1.0).value, 1)
        XCTAssertEqual(TargetDuration(segmentSeconds: 2.0).value, 2)
        for preset in LatencyPreset.allCases {
            XCTAssertEqual(TargetDuration(segmentSeconds: preset.segmentSeconds).value, 1, preset.code)
        }
    }

    /// Keyframe-stretched segments must not raise it (that would add delay).
    func testNormalSegmentsKeepIt() {
        var target = TargetDuration(segmentSeconds: 0.5)
        for duration in [0.5, 0.533, 0.467, 0.8, 1.0, 1.499] {
            XCTAssertFalse(target.record(duration), "\(duration)")
        }
        XCTAssertEqual(target.value, 1)
    }

    /// RFC 8216: never lowered once raised, and always covers the longest segment seen.
    func testOnlyGoesUp() {
        var target = TargetDuration(segmentSeconds: 0.5)
        XCTAssertTrue(target.record(1.5))
        XCTAssertEqual(target.value, 2)
        XCTAssertFalse(target.record(0.5))
        XCTAssertFalse(target.record(2.4))
        XCTAssertEqual(target.value, 2)
        XCTAssertTrue(target.record(3.6))
        XCTAssertEqual(target.value, 4)
        XCTAssertFalse(target.record(0.5))
        XCTAssertEqual(target.value, 4)
        XCTAssertEqual(target.initial, 1)
    }

    func testIgnoresBrokenDurations() {
        var target = TargetDuration(segmentSeconds: 0.5)
        for duration in [Double.nan, .infinity, -1, 0] { XCTAssertFalse(target.record(duration)) }
        XCTAssertEqual(target.value, 1)
    }

    func testWindowCount() {
        // At the starting target every preset keeps its own window (no extra delay).
        for preset in LatencyPreset.allCases {
            let target = TargetDuration(segmentSeconds: preset.segmentSeconds)
            XCTAssertEqual(HLSPlaylist.windowCount(playlistWindow: preset.playlistWindow, target: target,
                                                   stored: preset.storedSegments), preset.playlistWindow, preset.code)
        }
        // Raised: grows in proportion, but never past what is stored.
        var target = TargetDuration(segmentSeconds: 1.0)
        target.record(2.0)
        XCTAssertEqual(HLSPlaylist.windowCount(playlistWindow: 3, target: target, stored: 6), 6)
        XCTAssertEqual(HLSPlaylist.windowCount(playlistWindow: 4, target: target, stored: 7), 7)
        var l3 = TargetDuration(segmentSeconds: 0.5)
        l3.record(1.6)
        XCTAssertEqual(HLSPlaylist.windowCount(playlistWindow: 6, target: l3, stored: 10), 10)
    }
}

final class StreamStoreTargetTests: XCTestCase {
    private func makeStore(_ preset: LatencyPreset = .l3) -> StreamStore {
        StreamStore(format: .init(width: 1280, height: 720, frameRate: 30, bandwidth: 100),
                    playlistWindow: preset.playlistWindow, storedSegments: preset.storedSegments,
                    startOffset: preset.startOffset, segmentSeconds: preset.segmentSeconds)
    }

    private func text(_ store: StreamStore) -> String {
        let snapshot = store.snapshot()
        return HLSPlaylist.media(snapshot.playlistSegments, startOffset: snapshot.startOffset,
                                 targetDuration: snapshot.targetDuration)
    }

    func testTargetStaysOneForNormalSegments() {
        let store = makeStore()
        XCTAssertTrue(text(store).contains("#EXT-X-TARGETDURATION:1\n"), "before any segment")
        for duration in [0.533, 0.467, 0.5, 0.8] { store.addSegment(duration: duration, data: Data()) }
        XCTAssertEqual(store.targetDuration, 1)
        XCTAssertTrue(text(store).contains("#EXT-X-TARGETDURATION:1\n"))
        XCTAssertEqual(store.snapshot().playlistSegments.count, 4)
    }

    /// The old per-window rule went back to 1 once the long segment slid out; now it stays.
    func testTargetDoesNotGoDownAfterLongSegmentLeaves() {
        let store = makeStore()
        store.addSegment(duration: 0.5, data: Data())
        store.addSegment(duration: 2.6, data: Data())
        XCTAssertEqual(store.targetDuration, 3)
        for _ in 0..<20 { store.addSegment(duration: 0.5, data: Data()) }
        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.playlistSegments.contains { $0.duration > 1 }, "long segment is gone")
        XCTAssertEqual(snapshot.targetDuration, 3)
        XCTAssertTrue(text(store).contains("#EXT-X-TARGETDURATION:3\n"))
        // Window grows to everything stored (5 s), no more memory than before.
        XCTAssertEqual(snapshot.playlistSegments.count, LatencyPreset.l3.storedSegments)
        XCTAssertEqual(snapshot.storedSegments.count, LatencyPreset.l3.storedSegments)
    }

    /// Every playlist the store hands out keeps EXTINF (rounded) <= target and the target never drops.
    func testEveryPlaylistFollowsTheRules() {
        let store = makeStore()
        var lastTarget = 0
        let durations = [0.5, 0.533, 0.467, 1.2, 0.5, 1.7, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
        for duration in durations {
            store.addSegment(duration: duration, data: Data())
            let snapshot = store.snapshot()
            let target = try! XCTUnwrap(snapshot.targetDuration)
            XCTAssertGreaterThanOrEqual(target, lastTarget)
            lastTarget = target
            for segment in snapshot.playlistSegments {
                XCTAssertLessThanOrEqual(TargetDuration.rounded(segment.duration), target)
            }
        }
        XCTAssertEqual(lastTarget, 2)
    }
}

final class DiscontinuityTests: XCTestCase {
    private func makeStore() -> StreamStore {
        StreamStore(format: .init(width: 1280, height: 720, frameRate: 30, bandwidth: 100),
                    playlistWindow: 3, storedSegments: 4, startOffset: nil, segmentSeconds: 1.0)
    }

    private func media(_ store: StreamStore) -> String {
        let snapshot = store.snapshot()
        return HLSPlaylist.media(snapshot.playlistSegments, targetDuration: snapshot.targetDuration)
    }

    private func get(_ name: String, _ store: StreamStore) -> HTTPResponse {
        let path = "/tok/" + name
        return StreamRouter(token: "tok").respond(
            to: HTTPRequest(method: "GET", target: path, path: path, version: "HTTP/1.1", headers: [:]),
            snapshot: store.snapshot())
    }

    func testInitNames() {
        XCTAssertEqual(HLSPlaylist.initSegmentName(version: 0), "init.mp4")
        XCTAssertEqual(HLSPlaylist.initSegmentName(version: 2), "init2.mp4")
        XCTAssertEqual(HLSPlaylist.initVersion(fromName: "init.mp4"), 0)
        XCTAssertEqual(HLSPlaylist.initVersion(fromName: "init2.mp4"), 2)
        XCTAssertEqual(HLSPlaylist.initVersion(fromName: "init12.mp4"), 12)
        for name in ["init0.mp4", "init02.mp4", "init-1.mp4", "init.m4s", "initx.mp4", "seg1.m4s", "init"] {
            XCTAssertNil(HLSPlaylist.initVersion(fromName: name), name)
        }
    }

    func testNoEncoderChangeKeepsOutput() {
        let store = makeStore()
        store.setInitSegment(Data([1]))
        store.addSegment(duration: 1.0, data: Data())
        let text = media(store)
        XCTAssertFalse(text.contains("DISCONTINUITY"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"init.mp4\"\n"))
    }

    func testNewEncoderAddsDiscontinuityAndNewMap() {
        let store = makeStore()
        store.setInitSegment(Data([1]))
        store.addSegment(duration: 1.0, data: Data([10]))
        store.addSegment(duration: 1.0, data: Data([11]))
        store.beginNewEncoder()
        XCTAssertEqual(get("init.mp4", store).body, Data([1]), "old init still served while needed")
        XCTAssertEqual(get("init1.mp4", store).status, 404, "new init not written yet")
        store.setInitSegment(Data([2]))
        store.addSegment(duration: 1.0, data: Data([12]))

        XCTAssertEqual(media(store), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.000,
        seg0.m4s
        #EXTINF:1.000,
        seg1.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="init1.mp4"
        #EXTINF:1.000,
        seg2.m4s

        """)
        XCTAssertEqual(get("init.mp4", store).body, Data([1]))
        XCTAssertEqual(get("init1.mp4", store).body, Data([2]))
        XCTAssertEqual(get("seg2.m4s", store).body, Data([12]))

        // Once the old segments slide out, the number carries the discontinuity and the old init goes.
        for _ in 0..<4 { store.addSegment(duration: 1.0, data: Data()) }
        XCTAssertEqual(media(store), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:4
        #EXT-X-DISCONTINUITY-SEQUENCE:1
        #EXT-X-MAP:URI="init1.mp4"
        #EXTINF:1.000,
        seg4.m4s
        #EXTINF:1.000,
        seg5.m4s
        #EXTINF:1.000,
        seg6.m4s

        """)
        XCTAssertEqual(get("init.mp4", store).status, 404)
        XCTAssertEqual(get("init1.mp4", store).body, Data([2]))
    }

    /// The segment right after the change, listed first, gets the number but no tag.
    func testDiscontinuityOnFirstListedSegment() {
        let segments = [
            MediaSegment(sequence: 9, duration: 1, data: Data(), discontinuity: true, discontinuitySequence: 2, initVersion: 2),
            MediaSegment(sequence: 10, duration: 1, data: Data(), discontinuity: false, discontinuitySequence: 2, initVersion: 2),
        ]
        let text = HLSPlaylist.media(segments)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:9\n#EXT-X-DISCONTINUITY-SEQUENCE:2\n#EXT-X-MAP:URI=\"init2.mp4\"\n"))
        XCTAssertFalse(text.contains("#EXT-X-DISCONTINUITY\n"))
    }

    func testEncoderChangeBeforeAnySegment() {
        let store = makeStore()
        store.beginNewEncoder()
        store.setInitSegment(Data([2]))
        store.addSegment(duration: 1.0, data: Data())
        let text = media(store)
        XCTAssertFalse(text.contains("DISCONTINUITY"), "nothing came before, so nothing to break")
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"init1.mp4\"\n"))
        XCTAssertEqual(get("init1.mp4", store).body, Data([2]))
    }

    func testRingCountsDiscontinuities() {
        var ring = SegmentRing(capacity: 2)
        ring.append(duration: 1, data: Data())
        ring.append(duration: 1, data: Data(), discontinuity: true, initVersion: 1)
        ring.append(duration: 1, data: Data(), initVersion: 1)
        ring.append(duration: 1, data: Data(), discontinuity: true, initVersion: 2)
        XCTAssertEqual(ring.discontinuityCount, 2)
        XCTAssertEqual(ring.items.map(\.discontinuitySequence), [1, 2])
        XCTAssertEqual(ring.items.map(\.initVersion), [1, 2])
    }
}

final class StreamAddressTests: XCTestCase {
    func testURLNeedsIPAndPort() {
        var address = StreamAddress(token: "abc")
        XCTAssertNil(address.url)
        XCTAssertTrue(address.update(ip: "192.168.0.5"))
        XCTAssertNil(address.url, "listener not ready yet")
        XCTAssertFalse(address.update(port: 0), "0 means unknown")
        XCTAssertTrue(address.update(port: 8765))
        XCTAssertEqual(address.url, "http://192.168.0.5:8765/abc/live.m3u8")
        XCTAssertEqual(address.url, StreamAddress.url(ip: "192.168.0.5", port: 8765, token: "abc"))
    }

    func testChanges() {
        var address = StreamAddress(token: "abc", ip: "192.168.0.5", port: 8765)
        XCTAssertFalse(address.update(ip: "192.168.0.5"))
        XCTAssertFalse(address.update(port: 8765))
        // Wi-Fi switched to another network.
        XCTAssertTrue(address.update(ip: "10.0.0.7"))
        XCTAssertEqual(address.url, "http://10.0.0.7:8765/abc/live.m3u8")
        // Wi-Fi lost: no URL, the port is remembered.
        XCTAssertTrue(address.update(ip: nil))
        XCTAssertNil(address.url)
        XCTAssertEqual(address.port, 8765)
        // Back, and the listener moved to another port.
        XCTAssertTrue(address.update(ip: "10.0.0.7"))
        XCTAssertTrue(address.update(port: 50123))
        XCTAssertEqual(address.url, "http://10.0.0.7:50123/abc/live.m3u8")
    }

    func testStatusRoundTripWithNewFields() throws {
        var status = BroadcastStatus()
        status.updatedAt = Date(timeIntervalSinceReferenceDate: 1000)
        status.url = "http://192.168.0.5:8765/abc/live.m3u8"
        status.urlRevision = 3
        status.networkIssue = "no wifi"
        let decoded = try JSONDecoder().decode(BroadcastStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertEqual(BroadcastStatus().urlRevision, 0)
        XCTAssertNil(BroadcastStatus().networkIssue)
    }
}
