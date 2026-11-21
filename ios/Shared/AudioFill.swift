import Foundation

// Pure audio logic for the TV stream's audio track (no CoreMedia, so the tests compile it directly).
// The extension (MirrorDropBroadcast/AudioTrack.swift) turns the results into CMSampleBuffers.
// Why: AVAssetWriter interleaves the video and audio tracks, and ReplayKit sends no audio while
// nothing plays, so the audio track has to be kept going with silence or segments would stall.
// The incoming format also varies (44.1/48 kHz, mono/stereo, Int16 big-endian, Float32), so it is
// normalised to one fixed format (docs/PLAN.md "5. 소리").

/// The one format written to the encoder: 48 kHz, stereo, signed 16-bit interleaved PCM -> AAC.
enum AudioTrackFormat {
    static let sampleRate = 48_000
    static let channels = 2
    /// AAC bit rate; also added to the master playlist BANDWIDTH.
    static let bitRate = 128_000
    /// Largest buffer handed to the encoder at once (0.1 s), so silence comes in small pieces.
    static let maxFramesPerBuffer = 4_800
}

/// The audio track's position on the video timeline (seconds, the same clock as the video PTS).
/// The track starts exactly at the encoder session start and only ever grows by whole frames,
/// so its timestamps are continuous; real audio and silence are both placed through this.
struct AudioTimeline: Equatable {
    /// Video-timeline seconds where frame 0 of the track sits (the encoder session start).
    let start: Double
    let sampleRate: Double
    private(set) var framesWritten: Int64 = 0

    /// Real audio this close to the track end is appended as is (absorbs timestamp jitter).
    static let tolerance = 0.04
    /// Real audio may land up to this much behind its own timestamp before overlapping frames are
    /// skipped instead (keeps the sound continuous when it arrives a little late).
    static let maxLate = 0.3
    /// With no real audio, silence keeps the track this far behind the current video time.
    static let fillDelay = 0.2
    /// Even while real audio is flowing, silence is added once the track is this far behind, so
    /// the writer never waits long for audio (which would hold back the video segments).
    static let maxBehind = 1.0
    /// Real audio that arrived within this many seconds counts as "flowing" (no silence then).
    static let realAudioGrace = 0.3

    init(start: Double, sampleRate: Double = Double(AudioTrackFormat.sampleRate)) {
        self.start = start
        self.sampleRate = sampleRate
    }

    /// Video-timeline seconds where the next frame goes.
    var endTime: Double { start + Double(framesWritten) / sampleRate }

    /// Video-timeline seconds of frame `index` (for the buffer's presentation time).
    func time(ofFrame index: Int64) -> Double { start + Double(index) / sampleRate }

    mutating func advance(by frames: Int) {
        framesWritten += Int64(max(0, frames))
    }

    /// Silent frames to add now so the track keeps pace with the video.
    /// - Parameters:
    ///   - videoTime: current video-timeline time.
    ///   - secondsSinceRealAudio: time since the last real audio buffer arrived (nil: none yet).
    func silenceToFill(videoTime: Double, secondsSinceRealAudio: Double?) -> Int {
        let flowing = secondsSinceRealAudio.map { $0 < Self.realAudioGrace } ?? false
        let target = videoTime - (flowing ? Self.maxBehind : Self.fillDelay)
        let gap = target - endTime
        guard gap > 0 else { return 0 }
        return Int((gap * sampleRate).rounded(.down))
    }

    /// Where real audio goes: `silenceBefore` frames of silence first, then the buffer without its
    /// first `skip` frames (`skip == frames` means drop it all; it is entirely in the past).
    struct Placement: Equatable {
        var silenceBefore = 0
        var skip = 0
    }

    func place(time: Double, frames: Int) -> Placement {
        let gap = time - endTime
        if gap > Self.tolerance {
            return Placement(silenceBefore: Int((gap * sampleRate).rounded()), skip: 0)
        }
        if gap < -Self.maxLate {
            return Placement(silenceBefore: 0, skip: min(frames, Int((-gap * sampleRate).rounded())))
        }
        return Placement()
    }
}

/// Maps real audio timestamps onto the video timeline. ReplayKit audio and video timestamps are
/// expected to share the host clock (offset 0); if an audio timestamp is far from the current
/// video time, the clocks differ and the offset is re-anchored to the current video time.
struct AudioClockMapper: Equatable {
    static let maxDrift = 1.0
    private(set) var offset: Double = 0

    /// Returns the video-timeline time of `audioTime` and whether the offset was just re-anchored.
    mutating func map(_ audioTime: Double, videoNow: Double) -> (time: Double, resynced: Bool) {
        var mapped = audioTime + offset
        guard abs(mapped - videoNow) > Self.maxDrift else { return (mapped, false) }
        offset = videoNow - audioTime
        mapped = videoNow
        return (mapped, true)
    }
}

/// Description of an incoming linear PCM buffer (from its AudioStreamBasicDescription).
struct PCMSourceFormat: Equatable {
    var sampleRate: Double
    var channels: Int
    var bitsPerChannel: Int
    var isFloat: Bool
    var isBigEndian: Bool
    var isNonInterleaved: Bool

    /// Formats `PCMDecoder` can read: Int16, Int32 or Float32, 1 or more channels.
    var isSupported: Bool {
        guard sampleRate >= 8_000, sampleRate <= 192_000, channels >= 1 else { return false }
        return isFloat ? bitsPerChannel == 32 : (bitsPerChannel == 16 || bitsPerChannel == 32)
    }

    var bytesPerSample: Int { bitsPerChannel / 8 }

    /// For logs and diagnostics, e.g. "44100Hz 2ch s16be".
    var summary: String {
        let kind = isFloat ? "f" : "s"
        let endian = isBigEndian ? "be" : "le"
        let layout = isNonInterleaved ? " planar" : ""
        return "\(Int(sampleRate))Hz \(channels)ch \(kind)\(bitsPerChannel)\(endian)\(layout)"
    }
}

/// Reads PCM bytes into two Float channels (-1...1). Mono is copied to both sides; more than two
/// channels keep the first two.
enum PCMDecoder {
    /// - Parameter buffers: one buffer when interleaved, one per channel when non-interleaved.
    static func decode(_ buffers: [UnsafeRawBufferPointer], format: PCMSourceFormat,
                       frames: Int) -> (left: [Float], right: [Float])? {
        guard format.isSupported, frames > 0 else { return nil }
        let size = format.bytesPerSample
        func channel(_ index: Int) -> [Float]? {
            let source: UnsafeRawBufferPointer
            let stride: Int
            let first: Int
            if format.isNonInterleaved {
                guard index < buffers.count else { return nil }
                source = buffers[index]
                stride = size
                first = 0
            } else {
                guard let buffer = buffers.first else { return nil }
                source = buffer
                stride = size * format.channels
                first = index * size
            }
            guard source.count >= first + (frames - 1) * stride + size else { return nil }
            var out = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                out[frame] = sample(source, at: first + frame * stride, format: format)
            }
            return out
        }
        guard let left = channel(0) else { return nil }
        guard format.channels > 1 else { return (left, left) }
        guard let right = channel(1) else { return nil }
        return (left, right)
    }

    private static func sample(_ source: UnsafeRawBufferPointer, at offset: Int, format: PCMSourceFormat) -> Float {
        switch (format.isFloat, format.bitsPerChannel) {
        case (true, _):
            var bits = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8
                | UInt32(source[offset + 2]) << 16 | UInt32(source[offset + 3]) << 24
            if format.isBigEndian { bits = bits.byteSwapped }
            let value = Float(bitPattern: bits)
            return value.isFinite ? max(-1, min(1, value)) : 0
        case (false, 16):
            var bits = UInt16(source[offset]) | UInt16(source[offset + 1]) << 8
            if format.isBigEndian { bits = bits.byteSwapped }
            return Float(Int16(bitPattern: bits)) / 32_768
        default:
            var bits = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8
                | UInt32(source[offset + 2]) << 16 | UInt32(source[offset + 3]) << 24
            if format.isBigEndian { bits = bits.byteSwapped }
            return Float(Int32(bitPattern: bits)) / 2_147_483_648
        }
    }

    /// Largest absolute sample (0...1), for the diagnostics level meter.
    static func peak(_ left: [Float], _ right: [Float]) -> Float {
        var result: Float = 0
        for value in left { result = max(result, abs(value)) }
        for value in right { result = max(result, abs(value)) }
        return result
    }
}

/// Streaming linear-interpolation resampler for two channels. Keeps the last input frame between
/// calls so consecutive buffers join without clicks. Equal rates pass samples through unchanged.
struct StereoResampler {
    let inputRate: Double
    let outputRate: Double
    /// Position of the next output frame, in input frames relative to the next buffer's frame 0
    /// (-1..<0 means between the previous buffer's last frame and the next buffer's first).
    private var position: Double = 0
    private var previous: (Float, Float)?

    init(inputRate: Double, outputRate: Double = Double(AudioTrackFormat.sampleRate)) {
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    mutating func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let count = min(left.count, right.count)
        guard count > 0 else { return ([], []) }
        let step = inputRate / outputRate
        let before = previous ?? (left[0], right[0])
        func value(_ channel: [Float], _ before: Float, _ index: Int) -> Float {
            index < 0 ? before : channel[index]
        }
        var outLeft: [Float] = []
        var outRight: [Float] = []
        outLeft.reserveCapacity(Int(Double(count) / step) + 2)
        outRight.reserveCapacity(Int(Double(count) / step) + 2)
        var p = position
        while p <= Double(count - 1) {
            let base = Int(p.rounded(.down))
            let fraction = Float(p - Double(base))
            let l0 = value(left, before.0, base), r0 = value(right, before.1, base)
            if fraction == 0 {
                outLeft.append(l0)
                outRight.append(r0)
            } else {
                let l1 = left[base + 1], r1 = right[base + 1]
                outLeft.append(l0 + (l1 - l0) * fraction)
                outRight.append(r0 + (r1 - r0) * fraction)
            }
            p += step
        }
        position = p - Double(count)
        previous = (left[count - 1], right[count - 1])
        return (outLeft, outRight)
    }
}

/// Interleaves two Float channels into signed 16-bit stereo; `muted` writes zeros (same length).
enum PCMEncoder {
    static func interleavedInt16(left: [Float], right: [Float], muted: Bool) -> [Int16] {
        let count = min(left.count, right.count)
        guard !muted else { return [Int16](repeating: 0, count: count * 2) }
        var out = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            out[2 * i] = convert(left[i])
            out[2 * i + 1] = convert(right[i])
        }
        return out
    }

    private static func convert(_ value: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (value * 32_768).rounded())))
    }
}
