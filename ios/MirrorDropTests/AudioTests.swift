import XCTest

final class AudioOutputTests: XCTestCase {
    func testDefaultIsTV() {
        XCTAssertEqual(AudioOutput.default, .tv)
        XCTAssertTrue(AudioOutput.tv.sendsSoundToTV)
        XCTAssertFalse(AudioOutput.phone.sendsSoundToTV)
        XCTAssertEqual(AudioOutput.allCases.map(\.label), ["TV", "휴대폰"])
    }

    func testUnknownStoredValueFallsBackToDefault() {
        XCTAssertEqual(AudioOutput(storedValue: nil), .tv)
        XCTAssertEqual(AudioOutput(storedValue: ""), .tv)
        XCTAssertEqual(AudioOutput(storedValue: "TV"), .tv)
        XCTAssertEqual(AudioOutput(storedValue: "phone"), .phone)
    }

    func testSaveLoadAndLegacyCleanup() throws {
        let suite = "AudioOutputTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AudioOutput.load(from: defaults), .tv)
        AudioOutput.phone.save(to: defaults)
        XCTAssertEqual(AudioOutput.load(from: defaults), .phone)
        defaults.set(true, forKey: "includeAppAudio")
        AudioOutput.removeLegacySettings(from: defaults)
        XCTAssertNil(defaults.object(forKey: "includeAppAudio"))
        XCTAssertEqual(AudioOutput.load(from: defaults), .phone)
    }
}

final class AudioTimelineTests: XCTestCase {
    private let rate = 48_000.0

    func testStartsAtSessionStartWithContinuousFrames() {
        var timeline = AudioTimeline(start: 100)
        XCTAssertEqual(timeline.endTime, 100)
        timeline.advance(by: 4_800)
        XCTAssertEqual(timeline.endTime, 100.1, accuracy: 1e-9)
        XCTAssertEqual(timeline.time(ofFrame: 48_000), 101, accuracy: 1e-9)
        timeline.advance(by: -5)
        XCTAssertEqual(timeline.framesWritten, 4_800)
    }

    func testSilenceKeepsUpWithVideoWhenNoSound() {
        let timeline = AudioTimeline(start: 10)
        // Nothing before the fill delay has passed.
        XCTAssertEqual(timeline.silenceToFill(videoTime: 10.1, secondsSinceRealAudio: nil), 0)
        // 1 s of video, no sound: fill up to 0.2 s behind the video.
        XCTAssertEqual(timeline.silenceToFill(videoTime: 11, secondsSinceRealAudio: nil), Int(0.8 * rate))
        // Real sound stopped a while ago: same.
        XCTAssertEqual(timeline.silenceToFill(videoTime: 11, secondsSinceRealAudio: 5), Int(0.8 * rate))
    }

    func testNoSilenceWhileRealSoundFlowsUnlessFarBehind() {
        var timeline = AudioTimeline(start: 10)
        timeline.advance(by: Int(0.5 * rate))
        // Sound arrived 0.1 s ago and the track is 0.5 s behind: wait for it.
        XCTAssertEqual(timeline.silenceToFill(videoTime: 11, secondsSinceRealAudio: 0.1), 0)
        // 2 s behind even though sound is flowing: fill to 1 s behind so video is not held back.
        XCTAssertEqual(timeline.silenceToFill(videoTime: 11.5 + 1.0, secondsSinceRealAudio: 0.1), Int(1.0 * rate))
    }

    func testRealAudioOnTimeIsAppended() {
        var timeline = AudioTimeline(start: 0)
        timeline.advance(by: 48_000)
        XCTAssertEqual(timeline.place(time: 1.0, frames: 1_024), .init())
        // Small jitter either way is absorbed.
        XCTAssertEqual(timeline.place(time: 1.03, frames: 1_024), .init())
        XCTAssertEqual(timeline.place(time: 0.97, frames: 1_024), .init())
        // A little late (silence already covered it): still appended, keeps sound continuous.
        XCTAssertEqual(timeline.place(time: 0.8, frames: 1_024), .init())
    }

    func testGapBeforeRealAudioGetsSilence() {
        var timeline = AudioTimeline(start: 0)
        timeline.advance(by: 48_000)
        XCTAssertEqual(timeline.place(time: 1.5, frames: 1_024), .init(silenceBefore: 24_000, skip: 0))
    }

    func testVeryLateAudioSkipsOverlap() {
        var timeline = AudioTimeline(start: 0)
        timeline.advance(by: 48_000)
        XCTAssertEqual(timeline.place(time: 0.5, frames: 48_000), .init(silenceBefore: 0, skip: 24_000))
        // Entirely in the past: dropped.
        XCTAssertEqual(timeline.place(time: 0.1, frames: 1_024), .init(silenceBefore: 0, skip: 1_024))
    }

    /// Simulates a silent screen for 30 s, then 2 s of sound: the track stays within the bounds.
    func testLongSilenceThenSoundStaysInSync() {
        var timeline = AudioTimeline(start: 0)
        var video = 0.0
        while video < 30 {
            video += 0.1
            timeline.advance(by: timeline.silenceToFill(videoTime: video, secondsSinceRealAudio: nil))
            XCTAssertLessThanOrEqual(video - timeline.endTime, AudioTimeline.fillDelay + 0.1 + 1e-6)
        }
        // Sound starts, each buffer arrives 0.05 s after its timestamp.
        var audioTime = video - 0.05
        for _ in 0..<100 {
            let frames = 960 // 20 ms
            let placement = timeline.place(time: audioTime, frames: frames)
            timeline.advance(by: placement.silenceBefore + frames - placement.skip)
            audioTime += 0.02
            video += 0.02
            XCTAssertEqual(timeline.silenceToFill(videoTime: video, secondsSinceRealAudio: 0.02), 0)
            XCTAssertLessThan(abs(timeline.endTime - (audioTime)), AudioTimeline.maxLate + 0.05)
        }
    }
}

final class AudioClockMapperTests: XCTestCase {
    func testSameClockPassesThrough() {
        var mapper = AudioClockMapper()
        let result = mapper.map(500.2, videoNow: 500.3)
        XCTAssertEqual(result.time, 500.2, accuracy: 1e-9)
        XCTAssertFalse(result.resynced)
    }

    func testDifferentClockIsReanchoredOnce() {
        var mapper = AudioClockMapper()
        let first = mapper.map(3.0, videoNow: 1_000)
        XCTAssertTrue(first.resynced)
        XCTAssertEqual(first.time, 1_000, accuracy: 1e-9)
        let next = mapper.map(3.02, videoNow: 1_000.03)
        XCTAssertFalse(next.resynced)
        XCTAssertEqual(next.time, 1_000.02, accuracy: 1e-9)
    }
}

final class PCMTests: XCTestCase {
    private func bytes(_ values: [Int16], bigEndian: Bool) -> [UInt8] {
        values.flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: bigEndian ? value.bigEndian : value.littleEndian)
            return [UInt8(bits & 0xff), UInt8(bits >> 8)]
        }
    }

    private func decode(_ raw: [[UInt8]], _ format: PCMSourceFormat, frames: Int) -> (left: [Float], right: [Float])? {
        let datas = raw.map { Data($0) }
        func run(_ index: Int, _ pointers: [UnsafeRawBufferPointer]) -> (left: [Float], right: [Float])? {
            if index == datas.count { return PCMDecoder.decode(pointers, format: format, frames: frames) }
            return datas[index].withUnsafeBytes { run(index + 1, pointers + [$0]) }
        }
        return run(0, [])
    }

    func testInt16BigEndianStereo() throws {
        // ReplayKit app audio is often signed 16-bit big-endian interleaved.
        let format = PCMSourceFormat(sampleRate: 44_100, channels: 2, bitsPerChannel: 16,
                                     isFloat: false, isBigEndian: true, isNonInterleaved: false)
        let result = try XCTUnwrap(decode([bytes([16_384, -16_384, -32_768, 0], bigEndian: true)], format, frames: 2))
        XCTAssertEqual(result.left, [0.5, -1])
        XCTAssertEqual(result.right, [-0.5, 0])
        XCTAssertEqual(format.summary, "44100Hz 2ch s16be")
    }

    func testInt16LittleEndianMonoIsCopiedToBothSides() throws {
        let format = PCMSourceFormat(sampleRate: 48_000, channels: 1, bitsPerChannel: 16,
                                     isFloat: false, isBigEndian: false, isNonInterleaved: false)
        let result = try XCTUnwrap(decode([bytes([8_192, -8_192], bigEndian: false)], format, frames: 2))
        XCTAssertEqual(result.left, [0.25, -0.25])
        XCTAssertEqual(result.right, result.left)
    }

    func testFloatNonInterleaved() throws {
        let format = PCMSourceFormat(sampleRate: 48_000, channels: 2, bitsPerChannel: 32,
                                     isFloat: true, isBigEndian: false, isNonInterleaved: true)
        func raw(_ values: [Float]) -> [UInt8] {
            values.flatMap { value -> [UInt8] in
                let bits = value.bitPattern.littleEndian
                return [0, 8, 16, 24].map { UInt8((bits >> UInt32($0)) & 0xff) }
            }
        }
        let result = try XCTUnwrap(decode([raw([0.5, 2]), raw([-0.25, .nan])], format, frames: 2))
        XCTAssertEqual(result.left, [0.5, 1]) // clipped
        XCTAssertEqual(result.right, [-0.25, 0]) // NaN becomes silence
        XCTAssertEqual(PCMDecoder.peak(result.left, result.right), 1)
    }

    func testRejectsUnsupportedOrShortData() {
        let format24 = PCMSourceFormat(sampleRate: 48_000, channels: 2, bitsPerChannel: 24,
                                       isFloat: false, isBigEndian: false, isNonInterleaved: false)
        XCTAssertFalse(format24.isSupported)
        XCTAssertNil(decode([[0, 0, 0, 0, 0, 0]], format24, frames: 1))
        let format16 = PCMSourceFormat(sampleRate: 48_000, channels: 2, bitsPerChannel: 16,
                                       isFloat: false, isBigEndian: false, isNonInterleaved: false)
        XCTAssertNil(decode([[0, 0]], format16, frames: 1)) // needs 4 bytes
    }

    func testResamplerPassesEqualRateThrough() {
        var resampler = StereoResampler(inputRate: 48_000)
        let out = resampler.process(left: [0.1, 0.2, 0.3], right: [1, 2, 3])
        XCTAssertEqual(out.left, [0.1, 0.2, 0.3])
        XCTAssertEqual(out.right, [1, 2, 3])
    }

    func testResamplerKeepsRateAcrossBuffers() {
        // 44.1 kHz -> 48 kHz over 1 s in 1024-frame buffers gives 48000 frames (+- 1).
        var resampler = StereoResampler(inputRate: 44_100)
        var total = 0
        var remaining = 44_100
        var lastValue: Float = -1
        var index = 0
        while remaining > 0 {
            let count = min(1_024, remaining)
            let ramp = (0..<count).map { Float(index + $0) }
            let out = resampler.process(left: ramp, right: ramp)
            total += out.left.count
            // A rising input stays rising across buffer joins (no jumps backwards).
            for value in out.left {
                XCTAssertGreaterThanOrEqual(value, lastValue)
                lastValue = value
            }
            index += count
            remaining -= count
        }
        XCTAssertEqual(Double(total), 48_000, accuracy: 1)
    }

    func testEncoderInterleavesAndMutes() {
        XCTAssertEqual(PCMEncoder.interleavedInt16(left: [0.5, -1], right: [1, 0], muted: false),
                       [16_384, -32_768, 32_767, 0])
        XCTAssertEqual(PCMEncoder.interleavedInt16(left: [0.5, -1], right: [1, 0], muted: true), [0, 0, 0, 0])
    }
}

final class BroadcastStatusDecodingTests: XCTestCase {
    func testOldStatusWithoutAudioFieldsStillDecodes() throws {
        // Written by an older build: has "audioEnabled", lacks the new audio fields and urlRevision.
        let json = #"{"state":"streaming","framesIn":5,"audioEnabled":true,"audioSamplesIn":3,"log":["a"]}"#
        let status = try JSONDecoder().decode(BroadcastStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.state, .streaming)
        XCTAssertEqual(status.framesIn, 5)
        XCTAssertEqual(status.audioSamplesIn, 3)
        XCTAssertEqual(status.log, ["a"])
        XCTAssertEqual(status.urlRevision, 0)
        XCTAssertNil(status.audioOutput)
        XCTAssertEqual(status.audioSilentFrames, 0)
    }

    func testRoundTrip() throws {
        var status = BroadcastStatus()
        status.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        status.audioOutput = AudioOutput.phone.code
        status.audioSilentFrames = 480
        status.audioPeakMax = 0.5
        status.url = "http://192.168.0.2:8765/x/live.m3u8"
        status.clients = ["192.168.0.3": 2]
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(BroadcastStatus.self, from: data), status)
    }
}
