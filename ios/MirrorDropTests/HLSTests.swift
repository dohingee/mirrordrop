import XCTest

final class SegmentRingTests: XCTestCase {
    func testKeepsOnlyNewestSegments() {
        var ring = SegmentRing(capacity: 3)
        for i in 0..<5 { ring.append(duration: 1, data: Data([UInt8(i)])) }
        XCTAssertEqual(ring.items.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(ring.nextSequence, 5)
        XCTAssertNil(ring.segment(sequence: 1))
        XCTAssertEqual(ring.segment(sequence: 3)?.data, Data([3]))
        XCTAssertEqual(ring.totalBytes, 3)
    }

    func testLatest() {
        var ring = SegmentRing(capacity: 5)
        for _ in 0..<4 { ring.append(duration: 1, data: Data()) }
        XCTAssertEqual(ring.latest(2).map(\.sequence), [2, 3])
        XCTAssertEqual(ring.latest(10).count, 4)
        XCTAssertTrue(ring.latest(0).isEmpty)
    }
}

final class PlaylistTests: XCTestCase {
    private func segments(_ items: [(Int, Double)]) -> [MediaSegment] {
        items.map { MediaSegment(sequence: $0.0, duration: $0.1, data: Data()) }
    }

    func testMediaPlaylist() {
        let text = HLSPlaylist.media(segments([(7, 1.0), (8, 1.033)]))
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.000,
        seg7.m4s
        #EXTINF:1.033,
        seg8.m4s

        """)
        XCTAssertFalse(text.contains("ENDLIST"), "live playlist must not end")
    }

    func testEmptyMediaPlaylist() {
        let text = HLSPlaylist.media([])
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:1"))
    }

    func testTargetDurationCoversEverySegment() {
        XCTAssertEqual(HLSPlaylist.targetDuration(segments([(0, 1.0)])), 1)
        XCTAssertEqual(HLSPlaylist.targetDuration(segments([(0, 1.0), (1, 2.4)])), 3)
    }

    func testMasterPlaylist() {
        let text = HLSPlaylist.master(bandwidth: 2_700_000, codecs: "avc1.64001f", width: 1280, height: 720, frameRate: 30)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(text.contains("#EXT-X-STREAM-INF:BANDWIDTH=2700000,CODECS=\"avc1.64001f\",RESOLUTION=1280x720,FRAME-RATE=30.000\n"))
        XCTAssertTrue(text.hasSuffix("media.m3u8\n"))
    }

    func testMasterWithoutCodecs() {
        let text = HLSPlaylist.master(bandwidth: 1, codecs: nil, width: 2, height: 3, frameRate: 30)
        XCTAssertFalse(text.contains("CODECS"))
    }

    func testSegmentNames() {
        XCTAssertEqual(HLSPlaylist.segmentName(12), "seg12.m4s")
        XCTAssertEqual(HLSPlaylist.sequence(fromSegmentName: "seg12.m4s"), 12)
        XCTAssertNil(HLSPlaylist.sequence(fromSegmentName: "seg.m4s"))
        XCTAssertNil(HLSPlaylist.sequence(fromSegmentName: "seg-1.m4s"))
        XCTAssertNil(HLSPlaylist.sequence(fromSegmentName: "seg1.mp4"))
        XCTAssertNil(HLSPlaylist.sequence(fromSegmentName: "../seg1.m4s"))
    }

    func testCodecsFromInitSegment() {
        var data = Data([0, 0, 0, 0x20]) + Data("stsd".utf8) + Data(repeating: 0, count: 8)
        data += Data("avcC".utf8) + Data([0x01, 0x64, 0x00, 0x1f, 0xff])
        XCTAssertEqual(HLSPlaylist.codecs(fromInitSegment: data), "avc1.64001f")
        data += Data("mp4a".utf8)
        XCTAssertEqual(HLSPlaylist.codecs(fromInitSegment: data), "avc1.64001f,mp4a.40.2")
        XCTAssertNil(HLSPlaylist.codecs(fromInitSegment: Data("nothing".utf8)))
        XCTAssertNil(HLSPlaylist.codecs(fromInitSegment: Data("avcC".utf8) + Data([1, 2])))
    }
}

final class StreamStoreTests: XCTestCase {
    func testSnapshotWindow() {
        let store = StreamStore(format: .init(width: 1280, height: 720, frameRate: 30, bandwidth: 100),
                                playlistWindow: 2, storedSegments: 3)
        for i in 0..<5 { store.addSegment(duration: 1, data: Data([UInt8(i)])) }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.playlistSegments.map(\.sequence), [3, 4])
        XCTAssertEqual(snapshot.storedSegments.map(\.sequence), [2, 3, 4])
        XCTAssertNil(snapshot.initSegment)
        XCTAssertEqual(store.segmentCount, 3)
    }
}
