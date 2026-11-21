import XCTest

final class SegmentGridTests: XCTestCase {
    func testPeriodAt30FpsAnd48kHz() {
        // A video frame is 1600 samples, an AAC frame 1024: lcm = 25600 samples = 16 frames = 25 AAC frames.
        XCTAssertEqual(SegmentGrid.periodSamples(), 25_600)
        XCTAssertEqual(SegmentGrid.periodSamples(frameRate: 25), 15_360) // 0.32 s = 8 frames = 15 AAC frames
        XCTAssertNil(SegmentGrid.periodSamples(frameRate: 7), "1/7 s is not whole samples at 48 kHz")
        XCTAssertNil(SegmentGrid.periodSamples(frameRate: 0))
    }

    func testAlignedSecondsPicksTheNearestMultiple() {
        XCTAssertEqual(SegmentGrid.alignedSeconds(near: 0.5), 16.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(SegmentGrid.alignedSeconds(near: 1.0), 32.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(SegmentGrid.alignedSeconds(near: 1.6), 1.6, accuracy: 1e-12) // 48 frames = 75 AAC frames
        XCTAssertEqual(SegmentGrid.alignedSeconds(near: 0.1), 16.0 / 30.0, accuracy: 1e-12, "at least one period")
        XCTAssertEqual(SegmentGrid.alignedSeconds(near: 0.5, frameRate: 7), 0.5, "no grid: unchanged")
    }

    func testAlignment() {
        XCTAssertFalse(SegmentGrid.isAligned(seconds: 0.5), "15 frames but 23.4375 AAC frames")
        XCTAssertFalse(SegmentGrid.isAligned(seconds: 1.0), "46.875 AAC frames")
        XCTAssertTrue(SegmentGrid.isAligned(seconds: 16.0 / 30.0))
        XCTAssertTrue(SegmentGrid.isAligned(seconds: 1.6))
        XCTAssertFalse(SegmentGrid.isAligned(seconds: 0))
        for seconds in [0.5, 1.0, 0.75, 2.0] {
            let aligned = SegmentGrid.alignedSeconds(near: seconds)
            let exactSamples = aligned * Double(AudioTrackFormat.sampleRate)
            let samples = Int(exactSamples.rounded())
            XCTAssertEqual(exactSamples, Double(samples), accuracy: 1e-6, "\(seconds)")
            XCTAssertEqual(samples % 1024, 0, "\(seconds): whole AAC frames")
            XCTAssertEqual(samples % 1600, 0, "\(seconds): whole video frames")
        }
    }

    func testFramesPerSegment() {
        XCTAssertEqual(SegmentGrid.framesPerSegment(seconds: 16.0 / 30.0), 16)
        XCTAssertEqual(SegmentGrid.framesPerSegment(seconds: 32.0 / 30.0), 32)
        XCTAssertEqual(SegmentGrid.framesPerSegment(seconds: 0), 1)
    }
}

final class VideoFrameGridTests: XCTestCase {
    private func run(_ grid: inout VideoFrameGrid, _ exact: Double) -> VideoFrameGrid.Placement? {
        guard let placement = grid.place(exactIndex: exact) else { return nil }
        placement.fillers.forEach { grid.didAppend($0) }
        grid.didAppend(placement.index)
        return placement
    }

    func testRegularFramesLandOnTheirSlots() {
        var grid = VideoFrameGrid(framesPerSegment: 16)
        // ReplayKit jitter of a few milliseconds around 30 fps.
        let exact = [0.0, 1.1, 1.95, 3.2, 3.9, 5.05]
        XCTAssertEqual(exact.compactMap { run(&grid, $0)?.index }, [0, 1, 2, 3, 4, 5])
    }

    func testTakenSlotMovesAtMostOneFrameAhead() {
        var grid = VideoFrameGrid(framesPerSegment: 16)
        // Frames every 0.9 grid frames (the pipeline's 0.9 / 30 s cap): 0, .9, 1.8, 2.7, ...
        var indices: [Int64] = []
        var dropped = 0
        for n in 0..<30 {
            let exact = Double(n) * 0.9
            if let placement = run(&grid, exact) {
                XCTAssertLessThanOrEqual(Double(placement.index) - exact, VideoFrameGrid.maxLead)
                indices.append(placement.index)
            } else {
                dropped += 1
            }
        }
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count, "never two frames on one slot")
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertLessThan(dropped, 5)
    }

    func testOutOfOrderOrFarBehindIsDropped() {
        var grid = VideoFrameGrid(framesPerSegment: 16)
        _ = run(&grid, 0)
        _ = run(&grid, 5)
        XCTAssertNil(grid.place(exactIndex: 3.0))
        XCTAssertNil(grid.place(exactIndex: .nan))
        XCTAssertNil(VideoFrameGrid(framesPerSegment: 16).place(exactIndex: -2))
    }

    /// Static screen: the pipeline repeats the last frame only every ~0.3 s (9 grid frames), so
    /// boundaries (every 16) would be skipped; the previous frame is repeated exactly on them.
    func testSkippedBoundariesAreFilled() {
        var grid = VideoFrameGrid(framesPerSegment: 16)
        _ = run(&grid, 0)
        XCTAssertEqual(run(&grid, 9)?.fillers, [])
        XCTAssertEqual(run(&grid, 18), VideoFrameGrid.Placement(index: 18, fillers: [16]))
        XCTAssertEqual(run(&grid, 27)?.fillers, [])
        XCTAssertEqual(run(&grid, 36), VideoFrameGrid.Placement(index: 36, fillers: [32]))
        // A frame exactly on a boundary needs no filler.
        XCTAssertEqual(run(&grid, 48), VideoFrameGrid.Placement(index: 48, fillers: []))
        // A long gap fills each boundary, at most maxFillers.
        XCTAssertEqual(run(&grid, 100)?.fillers, [64, 80, 96])
        XCTAssertEqual(grid.place(exactIndex: 500)?.fillers.count, VideoFrameGrid.maxFillers)
    }

    /// With frames on the grid, every boundary is a frame, so each segment is exactly 16 frames
    /// (16/30 s) and 25 AAC frames, and both tracks start and end together.
    func testSegmentsComeOutExactlyAligned() {
        var grid = VideoFrameGrid(framesPerSegment: 16)
        var frames: [Int64] = []
        var exact = 0.0
        var step = 0
        while exact < 200 {
            if let placement = run(&grid, exact) { frames += placement.fillers + [placement.index] }
            // Uneven input: mostly ~1 frame apart, sometimes a 9-frame pause.
            step += 1
            exact += step % 17 == 0 ? 9.0 : (step % 2 == 0 ? 1.07 : 0.95)
        }
        let boundaries = frames.filter { $0 % 16 == 0 }
        XCTAssertEqual(boundaries, Array(stride(from: Int64(0), through: boundaries.last ?? 0, by: 16)))
    }
}

final class ExtinfTests: XCTestCase {
    /// 16/30 s segments: rounding each one to 0.533 would lose 1 ms every 3 segments.
    func testGridSegmentsDoNotDrift() {
        var ring = SegmentRing(capacity: 2000)
        let duration = 16.0 / 30.0
        for _ in 0..<1800 { ring.append(duration: duration, data: Data()) } // 16 minutes
        let listed = ring.items.map(HLSPlaylist.extinfSeconds)
        let sum = listed.reduce(0, +)
        XCTAssertEqual(sum, 1800 * duration, accuracy: 0.001)
        XCTAssertEqual(Set(listed.map { String(format: "%.3f", $0) }), ["0.533", "0.534"])
        // Every prefix stays within 1 ms of the real time, so a player summing EXTINF never drifts.
        var running = 0.0
        for (index, value) in listed.enumerated() {
            running += value
            XCTAssertEqual(running, Double(index + 1) * duration, accuracy: 0.001)
        }
    }

    func testPlaylistUsesTheRoundedTimeline() {
        var ring = SegmentRing(capacity: 3)
        for _ in 0..<3 { ring.append(duration: 16.0 / 30.0, data: Data()) }
        let text = HLSPlaylist.media(ring.items)
        // Ends 0.533, 1.067, 1.600 -> 0.533, 0.534, 0.533.
        XCTAssertTrue(text.contains("#EXTINF:0.533,\nseg0.m4s\n#EXTINF:0.534,\nseg1.m4s\n#EXTINF:0.533,\nseg2.m4s\n"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:1\n"))
    }

    func testSegmentsWithoutStartKeepTheirDuration() {
        let segment = MediaSegment(sequence: 0, duration: 1.033, data: Data())
        XCTAssertEqual(HLSPlaylist.extinfSeconds(segment), 1.033)
    }
}
